import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SecondLookCore

/// One endpoint contract is used before saving native settings and before sending HTTP.
public enum SharedEndpointValidation {
    public static func validate(_ url: URL, allowLocalHTTP: Bool = false) throws {
        let local = allowLocalHTTP && url.scheme == "http" &&
            ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        guard let host = url.host, !host.isEmpty, url.scheme == "https" || local,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw SharedStateFailure.invalidResponse }
    }
}

/// Rejects unsafe header values and known private Supabase API-key forms before saving or Auth HTTP.
/// Opaque public test keys remain valid; this does not authenticate a key with Supabase.
public enum SharedPublicKeyValidation {
    public static func validate(_ key: String) throws {
        guard !key.isEmpty,
              key.utf8.count <= 8_192,
              key.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0) &&
                      !CharacterSet.whitespacesAndNewlines.contains($0)
              }),
              !key.hasPrefix("sb_secret_"),
              !isLegacyServiceRoleJWT(key) else {
            throw SharedStateFailure.invalidResponse
        }
    }

    private static func isLegacyServiceRoleJWT(_ key: String) -> Bool {
        let segments = key.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments[1].utf8.count <= 8_192 else { return false }
        let payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let claims = try? JSONDecoder().decode(RoleClaim.self, from: data) else {
            return false
        }
        return claims.role == "service_role"
    }

    private struct RoleClaim: Decodable { let role: String? }
}

public struct PairingInvitation: Codable, Equatable, Sendable {
    public let snapshot: SharedSnapshot
    public let inviteToken: String
    public let expiresAt: Date

    /// The service emits two canonical UUID strings. Keep the token opaque and
    /// unchanged, but never offer a malformed or expired reply for sharing.
    func validateForPublication(now: Date = Date()) throws {
        guard inviteToken.utf8.count == 72, inviteToken.utf8.allSatisfy({ $0 < 128 }),
              expiresAt.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite,
              expiresAt > now else { throw SharedStateFailure.invalidResponse }
        for part in [String(inviteToken.prefix(36)), String(inviteToken.suffix(36))] {
            guard let uuid = UUID(uuidString: part),
                  part.lowercased() == uuid.uuidString.lowercased() else {
                throw SharedStateFailure.invalidResponse
            }
        }
    }
}

/// HTTP transport for the authenticated private-space service. The token supplier belongs to
/// one account session; callers must create a new client when that session changes.
public struct SharedHTTPClient: SharedStateClient {
    private let endpoint: PrivateHTTPEndpoint
    private let bearerToken: @Sendable () async throws -> String

    public init(serverURL: URL, bearerToken: @escaping @Sendable () async throws -> String,
                allowLocalHTTP: Bool = false, session: URLSession = .shared) {
        endpoint = PrivateHTTPEndpoint(baseURL: serverURL, allowLocalHTTP: allowLocalHTTP,
                                       session: session, apiKey: nil, failureFormat: .commandService)
        self.bearerToken = bearerToken
    }

    public init(serverURL: URL, accessToken: String, allowLocalHTTP: Bool = false,
                session: URLSession = .shared) {
        self.init(serverURL: serverURL, bearerToken: { accessToken },
                  allowLocalHTTP: allowLocalHTTP, session: session)
    }

    public func currentSpace() async throws -> SharedSnapshot {
        try await endpoint.send(path: ["v1", "space"], method: "GET", token: bearerToken())
    }

    public func createSpace(expectedSpaceRevision: Int? = nil) async throws -> PairingInvitation {
        if let expectedSpaceRevision, expectedSpaceRevision < 0 { throw SharedStateFailure.invalidResponse }
        let invitation: PairingInvitation = try await endpoint.send(
            path: ["v1", "spaces"], method: "POST", token: bearerToken(),
            body: CreateSpaceRequest(expectedSpaceRevision: expectedSpaceRevision))
        try invitation.validateForPublication()
        return invitation
    }

    public func joinSpace(inviteToken: String) async throws -> SharedSnapshot {
        try await endpoint.send(path: ["v1", "pairing", "join"], method: "POST",
                                token: bearerToken(), body: JoinRequest(inviteToken: inviteToken))
    }

    public func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        try await endpoint.send(path: ["v1", "spaces", spaceID.uuidString], method: "GET",
                                token: bearerToken())
    }

    public func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        try await endpoint.send(path: ["v1", "spaces", envelope.spaceID.uuidString, "commands"],
                                method: "POST", token: bearerToken(), body: envelope)
    }
}

private struct EmptyRequest: Encodable, Sendable {}
private struct JoinRequest: Encodable, Sendable { let inviteToken: String }

/// Bounded Auth rejection; raw provider messages and credentials never enter product errors.
public enum SharedAuthFailure: Error, Equatable, Sendable {
    case invalidCredentials
}

/// Supabase Auth REST endpoints; the publishable key is public configuration, never a service key.
public struct SharedAuthClient: Sendable {
    private let endpoint: PrivateHTTPEndpoint

    public init(authURL: URL, publishableKey: String, allowLocalHTTP: Bool = false,
                session: URLSession = .shared) {
        endpoint = PrivateHTTPEndpoint(baseURL: authURL, allowLocalHTTP: allowLocalHTTP,
                                       session: session, apiKey: publishableKey, failureFormat: .supabaseAuth)
    }

    public func signIn(email: String, password: String) async throws -> SharedAuthSession {
        let session: SharedAuthSession = try await endpoint.send(
            path: ["auth", "v1", "token"], method: "POST", token: nil,
            query: [URLQueryItem(name: "grant_type", value: "password")],
            body: Credentials(email: email, password: password))
        return try session.validatedAtReceipt(Date())
    }

    public func refresh(refreshToken: String) async throws -> SharedAuthSession {
        let session: SharedAuthSession = try await endpoint.send(
            path: ["auth", "v1", "token"], method: "POST", token: nil,
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: RefreshRequest(refresh_token: refreshToken))
        return try session.validatedAtReceipt(Date())
    }

    public func getUser(accessToken: String) async throws -> SharedAuthUser {
        try await endpoint.send(path: ["auth", "v1", "user"], method: "GET", token: accessToken)
    }
}

public struct SharedAuthUser: Codable, Equatable, Sendable {
    public let id: UUID
    public let email: String?
}

public struct SharedAuthSession: Codable, Equatable, Sendable {
    public let access_token: String
    public let refresh_token: String
    public let expires_at: Int?
    public let expires_in: Int?
    public let user: SharedAuthUser

    /// Validate successful responses before a vault can install or persist them.
    /// Credentials remain opaque; do not trim or rewrite their bytes.
    func validateCredentials() throws {
        // Match the command service's exclusive bearer-token bound.
        guard access_token.utf8.count < 8_192 else { throw SharedStateFailure.invalidResponse }
        for token in [access_token, refresh_token] {
            guard !token.isEmpty, token.utf8.count <= 8_192,
                  token.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0) &&
                          !CharacterSet.whitespacesAndNewlines.contains($0)
                  }) else { throw SharedStateFailure.invalidResponse }
        }
    }

    /// Admit only bounded durations and give the vault a locally measured deadline.
    /// The provider's absolute expires_at is informational and cannot defer refresh.
    func validatedAtReceipt(_ receivedAt: Date) throws -> SharedAuthSession {
        try validateCredentials()
        guard let expires_in, (1...86_400).contains(expires_in) else {
            throw SharedStateFailure.invalidResponse
        }
        let localExpiry = receivedAt.addingTimeInterval(TimeInterval(expires_in)).timeIntervalSince1970
        guard localExpiry.isFinite, localExpiry > 0, localExpiry < Double(Int.max) else {
            throw SharedStateFailure.invalidResponse
        }
        return SharedAuthSession(access_token: access_token, refresh_token: refresh_token,
                                 expires_at: Int(localExpiry), expires_in: expires_in, user: user)
    }
}

private struct Credentials: Encodable, Sendable { let email: String; let password: String }
private struct CreateSpaceRequest: Encodable, Sendable { let expectedSpaceRevision: Int? }
private struct RefreshRequest: Encodable, Sendable { let refresh_token: String }
private enum HTTPFailureFormat { case commandService, supabaseAuth }

/// Kept in the same target as the app's transport so package tests exercise exact request code.
private struct PrivateHTTPEndpoint: @unchecked Sendable {
    let baseURL: URL
    let allowLocalHTTP: Bool
    let session: URLSession
    let apiKey: String?
    let failureFormat: HTTPFailureFormat

    func send<Response: Decodable>(path: [String], method: String, token: String?,
                                   query: [URLQueryItem] = []) async throws -> Response {
        try await send(path: path, method: method, token: token, query: query,
                       body: Optional<EmptyRequest>.none)
    }

    func send<Request: Encodable, Response: Decodable>(path: [String], method: String,
                                                       token: String?, query: [URLQueryItem] = [],
                                                       body: Request?) async throws -> Response {
        try SharedEndpointValidation.validate(baseURL, allowLocalHTTP: allowLocalHTTP)
        guard !path.contains(where: { $0 == ".." || $0.contains("/") }) else {
            throw SharedStateFailure.invalidResponse
        }
        if let apiKey { try SharedPublicKeyValidation.validate(apiKey) }
        var url = baseURL
        for part in path { url.appendPathComponent(part) }
        if !query.isEmpty {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw SharedStateFailure.invalidResponse
            }
            parts.queryItems = query
            guard let built = parts.url else { throw SharedStateFailure.invalidResponse }
            url = built
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "apikey") }
        if let token {
            guard !token.isEmpty, !token.contains("\n"), !token.contains("\r") else {
                throw SharedStateFailure.unauthenticated
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try SharedWireCodec.encode(body)
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw SharedStateFailure.serviceUnavailable }
        guard let http = response as? HTTPURLResponse else { throw SharedStateFailure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw failure(status: http.statusCode, data: data)
        }
        do { return try SharedWireCodec.decode(Response.self, from: data) }
        catch { throw SharedStateFailure.invalidResponse }
    }

    private func failure(status: Int, data: Data) -> any Error {
        if failureFormat == .supabaseAuth, status == 400 {
            let authCode = (try? SharedWireCodec.decode(AuthError.self, from: data))?.error_code
            switch authCode {
            case "invalid_credentials": return SharedAuthFailure.invalidCredentials
            case "refresh_token_not_found", "refresh_token_already_used":
                return SharedStateFailure.unauthenticated
            default: return SharedStateFailure.invalidResponse
            }
        }
        return Self.serviceFailure(status: status, data: data, format: failureFormat)
    }

    private static func serviceFailure(status: Int, data: Data,
                                       format: HTTPFailureFormat) -> SharedStateFailure {
        let code = (try? SharedWireCodec.decode(ServiceError.self, from: data))?.code
        switch status {
        case 401:
            return format == .supabaseAuth || code == "unauthenticated" ? .unauthenticated : .serviceUnavailable
        case 403:
            return format == .supabaseAuth || code == "forbidden" ? .forbidden : .serviceUnavailable
        case 404:
            return format == .commandService && code == "notPaired" ? .notPaired : .serviceUnavailable
        case 409:
            guard format == .commandService else { return .serviceUnavailable }
            switch code {
            case "pairingUnavailable": return .pairingUnavailable
            case "staleState": return .staleState
            default: return .serviceUnavailable
            }
        case 400:
            switch code {
            case "invalidInvite": return .invalidInvite
            case "invalidDefinition": return .domain(.invalidDefinition)
            case "unauthorized": return .domain(.unauthorized)
            case "reviewerRequired": return .domain(.reviewerRequired)
            case "wrongItemType": return .domain(.wrongItemType)
            case "closed": return .domain(.closed)
            case "staleVersion": return .domain(.staleVersion)
            case "invalidTransition": return .domain(.invalidTransition)
            case "noteRequired": return .domain(.noteRequired)
            case "notFound": return .domain(.notFound)
            default: return .invalidResponse
            }
        default: return .serviceUnavailable
        }
    }
}

private struct ServiceError: Decodable { let code: String }
private struct AuthError: Decodable { let error_code: String }
