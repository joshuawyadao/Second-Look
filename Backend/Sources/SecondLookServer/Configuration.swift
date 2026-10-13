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
              let publicKey = environment["SECONDLOOK_PUBLISHABLE_KEY"],
              Self.isSafeHeaderValue(publicKey), !publicKey.hasPrefix("sb_secret_"),
              Self.recognizableLegacyRole(publicKey) != "service_role",
              let secret = environment["SECONDLOOK_SERVICE_KEY"],
              Self.isSafeHeaderValue(secret), !secret.hasPrefix("sb_publishable_"),
              Self.recognizableLegacyRole(secret) != "anon",
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

    /// Both keys become HTTP field values. Reject whitespace and controls at startup, including
    /// CR from CRLF-sourced environment files, without trimming or exposing either key.
    private static func isSafeHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) &&
                !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    /// A recognizable legacy role can identify a wrong slot, but these unverified claims never
    /// authenticate a key or supply an actor. Supabase validates the credential on use.
    private static func recognizableLegacyRole(_ key: String) -> String? {
        let segments = key.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments[1].utf8.count <= 8_192 else { return nil }
        let payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let claims = try? JSONDecoder().decode(LegacyRoleClaim.self, from: data) else {
            return nil
        }
        return claims.role
    }

    private struct LegacyRoleClaim: Decodable { let role: String? }
}

enum ConfigurationFailure: Error { case invalid }
