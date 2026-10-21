import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SecondLookCore
import SecondLookTransport

final class AuthExpiryValidationTests: XCTestCase {
    func testSuccessfulSignInAndRefreshRejectMissingInvalidOrUnboundedDuration() async throws {
        for scenario in ["missing", "null", "zero", "negative", "oversized"] {
            for refreshing in [false, true] {
                do {
                    _ = try await request(scenario, refreshing: refreshing)
                    XCTFail("Invalid expiry duration reached session installation: \(scenario), refresh=\(refreshing)")
                } catch {
                    XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, scenario)
                }
            }
        }
    }

    func testSuccessfulSignInAndRefreshUseReceiptBasedDeadlineAndPreserveOpaqueFields() async throws {
        for (scenario, duration) in [("minimum", 1), ("hour", 3600), ("maximum", 86_400)] {
            for refreshing in [false, true] {
                let before = Date().timeIntervalSince1970
                let result = try await request(scenario, refreshing: refreshing)
                let after = Date().timeIntervalSince1970
                XCTAssertEqual(result.expires_in, duration)
                let deadline = try XCTUnwrap(result.expires_at)
                XCTAssertGreaterThanOrEqual(Double(deadline), before + Double(duration) - 1)
                XCTAssertLessThanOrEqual(Double(deadline), after + Double(duration) + 1)
                XCTAssertNotEqual(deadline, 4_000_000_000, "Provider absolute expiry must not control local refresh")
                XCTAssertEqual(result.access_token, "opaque.Access-Token_1~")
                XCTAssertEqual(result.refresh_token, "opaque.Refresh-Token_2~")
                XCTAssertEqual(result.user.id, UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
            }
        }
    }

    private func request(_ scenario: String, refreshing: Bool) async throws -> SharedAuthSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExpiryReplyProtocol.self]
        let client = SharedAuthClient(authURL: URL(string: "https://\(scenario).authexpiry.test")!,
                                      publishableKey: "public-test-key", session: URLSession(configuration: configuration))
        if refreshing { return try await client.refresh(refreshToken: "opaque-prior-refresh-token") }
        return try await client.signIn(email: "person@example.test", password: "invented-password")
    }
}

private final class ExpiryReplyProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".authexpiry.test") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/auth/v1/token")
            XCTAssertEqual(request.httpMethod, "POST")
            let scenario = try XCTUnwrap(url.host?.components(separatedBy: ".").first)
            var response: [String: Any] = [
                "access_token": "opaque.Access-Token_1~",
                "refresh_token": "opaque.Refresh-Token_2~",
                "expires_at": 4_000_000_000,
                "user": ["id": "11111111-1111-4111-8111-111111111111", "email": "person@example.test"]
            ]
            switch scenario {
            case "missing": break
            case "null": response["expires_in"] = NSNull()
            case "zero": response["expires_in"] = 0
            case "negative": response["expires_in"] = -1
            case "oversized": response["expires_in"] = 86_401
            case "minimum": response["expires_in"] = 1
            case "hour": response["expires_in"] = 3600
            case "maximum": response["expires_in"] = 86_400
            default: XCTFail("Unknown synthetic expiry scenario")
            }
            let data = try JSONSerialization.data(withJSONObject: response)
            let http = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
