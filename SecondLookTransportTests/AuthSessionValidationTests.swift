import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SecondLookCore
import SecondLookTransport

final class AuthSessionValidationTests: XCTestCase {
    func testSuccessfulSignInAndRefreshRejectUnusableCredentials() async throws {
        for name in ["empty-access", "empty-refresh", "space-access", "space-refresh",
                     "control-access", "control-refresh", "large-access", "large-refresh"] {
            for refreshing in [false, true] {
                do {
                    _ = try await request(name, refreshing: refreshing)
                    XCTFail("Unusable Auth credentials must not reach session installation: \(name), refresh=\(refreshing)")
                } catch {
                    XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, name)
                }
            }
        }
    }

    func testSuccessfulSignInAndRefreshPreserveValidOpaqueCredentials() async throws {
        for refreshing in [false, true] {
            let session = try await request("valid", refreshing: refreshing)
            XCTAssertEqual(session.access_token, "opaque.Access-Token_1~")
            XCTAssertEqual(session.refresh_token, "opaque.Refresh-Token_2~")
            XCTAssertEqual(session.expires_in, 3600)
            XCTAssertEqual(session.user.id, UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        }
    }

    func testAccessTokenExactServerLimitRejectsAndBelowLimitSurvives() async throws {
        for refreshing in [false, true] {
            do {
                _ = try await request("access-limit", refreshing: refreshing)
                XCTFail("The command service rejects an access token at exactly8192 bytes")
            } catch {
                XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
            }
            let session = try await request("below-access-limit", refreshing: refreshing)
            XCTAssertEqual(session.access_token, String(repeating: "a", count: 8_191))
            XCTAssertEqual(session.refresh_token, String(repeating: "r", count: 8_192))
        }
    }

    private func request(_ name: String, refreshing: Bool) async throws -> SharedAuthSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthReplyProtocol.self]
        let client = SharedAuthClient(authURL: URL(string: "https://\(name).authsession.test")!,
            publishableKey: "public-test-key", session: URLSession(configuration: configuration))
        if refreshing { return try await client.refresh(refreshToken: "invented-prior-refresh-token") }
        return try await client.signIn(email: "person@example.test", password: "invented-password")
    }
}

private final class AuthReplyProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".authsession.test") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/auth/v1/token")
            XCTAssertEqual(request.httpMethod, "POST")
            let name = try XCTUnwrap(url.host?.components(separatedBy: ".").first)
            var access = "opaque.Access-Token_1~"
            var refresh = "opaque.Refresh-Token_2~"
            switch name {
            case "empty-access": access = ""
            case "empty-refresh": refresh = ""
            case "space-access": access = " token "
            case "space-refresh": refresh = "\n"
            case "control-access": access = "token\u{0001}"
            case "control-refresh": refresh = "token\u{0000}"
            case "large-access": access = String(repeating: "a", count: 8_193)
            case "large-refresh": refresh = String(repeating: "r", count: 8_193)
            case "access-limit": access = String(repeating: "a", count: 8_192)
            case "below-access-limit":
                access = String(repeating: "a", count: 8_191)
                refresh = String(repeating: "r", count: 8_192)
            default: break
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "access_token": access, "refresh_token": refresh, "expires_in": 3600,
                "user": ["id": "11111111-1111-4111-8111-111111111111", "email": "person@example.test"]
            ])
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
