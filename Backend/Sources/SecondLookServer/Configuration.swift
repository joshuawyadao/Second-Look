import Foundation
import SecondLookCore

struct ServerConfiguration: Sendable {
    let providerURL: URL
    let publishableKey: String
    let serviceKey: String
    let allowedAccounts: Set<UUID>
    let port: Int
    let localDevelopment: Bool
    let testEvidence: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let local = environment["SECONDLOOK_LOCAL_DEVELOPMENT"] == "1"
        guard let rawURL = environment["SECONDLOOK_PROVIDER_URL"], let url = URL(string: rawURL),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (local && url.scheme == "http" && Self.isLoopback(url)),
              let publicKey = environment["SECONDLOOK_PUBLISHABLE_KEY"], Self.isSafeHeaderValue(publicKey),
              let secret = environment["SECONDLOOK_SERVICE_KEY"], Self.isSafeHeaderValue(secret),
              publicKey != secret,
              let accounts = environment["SECONDLOOK_ALLOWED_ACCOUNTS"] else {
            throw ConfigurationFailure.invalid
        }
        let fields = accounts.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let first = UUID(uuidString: String(fields[0])),
              let second = UUID(uuidString: String(fields[1])),
              first != second else { throw ConfigurationFailure.invalid }
        let port = Int(environment["SECONDLOOK_PORT"] ?? "8080") ?? 0
        guard (1024...65535).contains(port) else { throw ConfigurationFailure.invalid }
        let requestedEvidence = environment["SECONDLOOK_TEST_EVIDENCE"] == "1"
        #if DEBUG
        guard !requestedEvidence || (local && Self.isLoopback(url)) else { throw ConfigurationFailure.invalid }
        #else
        guard !requestedEvidence else { throw ConfigurationFailure.invalid }
        #endif
        self.providerURL = url
        self.publishableKey = publicKey
        self.serviceKey = secret
        self.allowedAccounts = [first, second]
        self.port = port
        self.localDevelopment = local
        self.testEvidence = requestedEvidence
    }

    static func isLoopback(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
    }

    /// Both keys become HTTP field values. Reject controls at startup, including CR from
    /// CRLF-sourced environment files, before Foundation or NIO tries to construct a request.
    private static func isSafeHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }
}

enum ConfigurationFailure: Error { case invalid }
