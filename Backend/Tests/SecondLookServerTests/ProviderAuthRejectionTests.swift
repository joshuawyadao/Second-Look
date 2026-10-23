import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import VaporTesting
import SecondLookCore
@testable import SecondLookServer

@Suite(.serialized) struct ProviderAuthRejectionTests {
    private let owner = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

    private func provider() throws -> (SupabaseProvider, URLSession) {
        let configuration = try ServerConfiguration(environment: [
            "SECONDLOOK_PROVIDER_URL": "https://auth-rejection.test",
            "SECONDLOOK_PUBLISHABLE_KEY": "sb_publishable_synthetic",
            "SECONDLOOK_SERVICE_KEY": "sb_secret_synthetic",
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),10000000-0000-0000-0000-000000000002",
        ])
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderAuthRejectionProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        return (SupabaseProvider(configuration: configuration, session: session), session)
    }

    @Test func explicitBearerAndAccountDenialsAreUnauthenticated() async throws {
        let (provider, session) = try provider()
        defer { session.invalidateAndCancel() }
        for code in ["bad_jwt", "unexpected_audience", "session_expired",
                     "session_not_found", "user_not_found", "user_banned"] {
            do {
                _ = try await provider.account(for: "synthetic-coded-\(code)")
                Issue.record("Explicit Auth denial \(code) was accepted")
            } catch {
                #expect(error as? SharedStateFailure == .unauthenticated,
                        "Explicit Auth denial \(code) must retain the 401 contract")
            }
        }
    }

    @Test func gatewayAndMalformedDenialsRemainServiceUnavailable() async throws {
        let (provider, session) = try provider()
        defer { session.invalidateAndCancel() }
        for variant in ["invalid-key", "uncoded", "message-spoof", "unknown",
                        "malformed", "oversized", "contradictory-status", "no-authorization"] {
            do {
                _ = try await provider.account(for: "synthetic-\(variant)")
                Issue.record("Unproven Auth denial \(variant) was accepted")
            } catch {
                #expect(error as? SharedStateFailure == .serviceUnavailable,
                        "Unproven Auth denial \(variant) must preserve the phone session")
            }
        }
    }

    @Test func serviceBoundaryKeepsUnknownKeyFailureDistinctFromBadBearer() async throws {
        let (provider, session) = try provider()
        defer { session.invalidateAndCancel() }
        try await withApp { app in
            try configure(app, configuration: provider.configuration, verifier: provider, store: provider)
            for (token, status, code) in [
                ("synthetic-invalid-key", 503, "serviceUnavailable"),
                ("synthetic-coded-bad_jwt", 401, "unauthenticated"),
            ] {
                try await app.testing().test(.GET, "/v1/space", beforeRequest: { request in
                    request.headers.bearerAuthorization = .init(token: token)
                }, afterResponse: { response in
                    #expect(response.status.code == status)
                    #expect(response.body.string == "{\"code\":\"\(code)\"}")
                    #expect(response.headers[.cacheControl] == ["no-store"])
                })
            }
        }
    }
}

private final class ProviderAuthRejectionProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "auth-rejection.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.path == "/auth/v1/user",
              request.value(forHTTPHeaderField: "apikey") == "sb_publishable_synthetic",
              let bearer = request.value(forHTTPHeaderField: "Authorization"),
              bearer.hasPrefix("Bearer synthetic-") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let token = String(bearer.dropFirst("Bearer synthetic-".count))
        let status: Int
        let body: String
        if token.hasPrefix("coded-") {
            status = 403
            body = "{\"code\":403,\"error_code\":\"\(token.dropFirst("coded-".count))\",\"msg\":\"denied\"}"
        } else {
            switch token {
            case "invalid-key":
                status = 401
                body = "{\"message\":\"Invalid API key\"}"
            case "uncoded":
                status = 403
                body = "{\"code\":403,\"msg\":\"invalid JWT\"}"
            case "message-spoof":
                status = 401
                body = "{\"msg\":\"bad_jwt\"}"
            case "unknown":
                status = 403
                body = "{\"code\":403,\"error_code\":\"unexpected_failure\",\"msg\":\"denied\"}"
            case "malformed":
                status = 403
                body = "{\"error_code\":"
            case "oversized":
                status = 403
                body = "{\"code\":403,\"error_code\":\"bad_jwt\",\"padding\":\"\(String(repeating: "x", count: 16_385))\"}"
            case "contradictory-status":
                status = 401
                body = "{\"code\":500,\"error_code\":\"bad_jwt\"}"
            case "no-authorization":
                status = 401
                body = "{\"code\":401,\"error_code\":\"no_authorization\"}"
            default:
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
