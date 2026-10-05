import Foundation
import Security
import SecondLookCore

/// Public endpoints and publishable key only. Credentials and tokens never enter preferences.
struct ConnectedConfiguration: Codable, Equatable {
    var authURL: URL
    var publishableKey: String
    var serverURL: URL

    var backendID: String { authURL.absoluteString + "|" + serverURL.absoluteString }
    var keychainService: String {
        let namespace: String
        #if SECONDLOOK_DEMO
        let args = ProcessInfo.processInfo.arguments
        namespace = args.contains("-ui-testing") && args.contains("-shared-testing")
            ? ".isolated-ui-tests" : ""
        #else
        namespace = ""
        #endif
        return "com.secondlook.shared.\(Bundle.main.bundleIdentifier ?? "unknown")\(namespace).\(backendID)"
    }

    func validate(allowLocalHTTP: Bool) throws {
        for url in [authURL, serverURL] {
            let local = allowLocalHTTP && url.scheme == "http" &&
                ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
            guard url.scheme == "https" || local,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else {
                throw SharedStateFailure.invalidResponse
            }
        }
        guard !publishableKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SharedStateFailure.invalidResponse
        }
    }
}

private struct StoredCredentials: Codable {
    let accountID: UUID
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

enum ConnectedIdentityFailure: Error { case secureStorageUnavailable }

enum ConnectedKeychain {
    private final class SessionRegistry: @unchecked Sendable {
        let lock = NSLock()
        var current: [String: UUID] = [:]
    }
    private static let registry = SessionRegistry()

    static func bind(configuration: ConnectedConfiguration, sessionID: UUID) {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        registry.current[configuration.keychainService] = sessionID
    }

    static func end(configuration: ConnectedConfiguration, sessionID: UUID) {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        if registry.current[configuration.keychainService] == sessionID {
            registry.current.removeValue(forKey: configuration.keychainService)
        }
    }

    static func clearBinding(configuration: ConnectedConfiguration) {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        registry.current.removeValue(forKey: configuration.keychainService)
    }

    static func save(_ session: SharedAuthSession, configuration: ConnectedConfiguration,
                     sessionID: UUID) throws {
        let expiration = session.expires_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? Date().addingTimeInterval(TimeInterval(session.expires_in ?? 3600))
        let value = StoredCredentials(accountID: session.user.id, accessToken: session.access_token,
                                      refreshToken: session.refresh_token, expiresAt: expiration)
        let data = try JSONEncoder().encode(value)
        registry.lock.lock()
        defer { registry.lock.unlock() }
        guard registry.current[configuration.keychainService] == sessionID else {
            throw SharedStateFailure.sessionChanged
        }
        let query = key(configuration)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            #if SECONDLOOK_DEMO
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-ui-testing") && args.contains("-shared-testing") {
                NSLog("Second Look local test Keychain status: %d", status)
            }
            #endif
            throw ConnectedIdentityFailure.secureStorageUnavailable
        }
    }

    static func restore(configuration: ConnectedConfiguration) throws -> AuthSessionVault? {
        var query = key(configuration)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(StoredCredentials.self, from: data) else {
            throw ConnectedIdentityFailure.secureStorageUnavailable
        }
        return AuthSessionVault(accountID: value.accountID, accessToken: value.accessToken,
                                refreshToken: value.refreshToken, expiresAt: value.expiresAt,
                                configuration: configuration)
    }

    static func delete(configuration: ConnectedConfiguration) {
        SecItemDelete(key(configuration) as CFDictionary)
    }

    private static func key(_ configuration: ConnectedConfiguration) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: configuration.keychainService,
         kSecAttrAccount as String: "active-session"]
    }
}

/// This actor is created per authenticated identity and captured by its own HTTP client.
/// It cannot start sending a previous account's request with a newly selected account's token.
actor AuthSessionVault {
    nonisolated let accountID: UUID
    nonisolated let sessionID = UUID()
    private var access: String
    private var refreshValue: String
    private var expiresAt: Date
    private let config: ConnectedConfiguration
    private let auth: SharedAuthClient
    private var invalidated = false
    private var refreshTask: Task<SharedAuthSession, Error>?

    init(accountID: UUID, accessToken: String, refreshToken: String, expiresAt: Date,
         configuration: ConnectedConfiguration) {
        self.accountID = accountID
        access = accessToken
        refreshValue = refreshToken
        self.expiresAt = expiresAt
        config = configuration
        auth = SharedAuthClient(authURL: configuration.authURL,
                                publishableKey: configuration.publishableKey,
                                allowLocalHTTP: Self.localHTTPAllowed)
    }

    static func fresh(_ session: SharedAuthSession, configuration: ConnectedConfiguration) -> AuthSessionVault {
        AuthSessionVault(accountID: session.user.id, accessToken: session.access_token,
                         refreshToken: session.refresh_token,
                         expiresAt: session.expires_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                             ?? Date().addingTimeInterval(TimeInterval(session.expires_in ?? 3600)),
                         configuration: configuration)
    }

    func token() async throws -> String {
        guard !invalidated else { throw SharedStateFailure.sessionChanged }
        if expiresAt <= Date().addingTimeInterval(60) {
            if refreshTask == nil {
                let tokenToRefresh = refreshValue
                let auth = auth
                refreshTask = Task { try await auth.refresh(refreshToken: tokenToRefresh) }
            }
            guard let refreshTask else { throw SharedStateFailure.serviceUnavailable }
            let updated: SharedAuthSession
            do { updated = try await refreshTask.value }
            catch {
                self.refreshTask = nil
                throw error
            }
            guard !invalidated, updated.user.id == accountID else {
                throw SharedStateFailure.sessionChanged
            }
            try ConnectedKeychain.save(updated, configuration: config, sessionID: sessionID)
            access = updated.access_token
            refreshValue = updated.refresh_token
            expiresAt = updated.expires_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                ?? Date().addingTimeInterval(TimeInterval(updated.expires_in ?? 3600))
            self.refreshTask = nil
        }
        return access
    }

    func verify() async throws {
        let user = try await auth.getUser(accessToken: token())
        guard !invalidated, user.id == accountID else { throw SharedStateFailure.unauthenticated }
    }

    func invalidate() { invalidated = true; refreshTask?.cancel(); refreshTask = nil; access = ""; refreshValue = "" }

    nonisolated static var localHTTPAllowed: Bool {
        #if SECONDLOOK_DEMO
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-ui-testing") && arguments.contains("-shared-testing")
        #else
        return false
        #endif
    }
}
