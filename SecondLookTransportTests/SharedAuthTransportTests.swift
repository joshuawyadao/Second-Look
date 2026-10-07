import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SecondLookCore
import SecondLookTransport

final class SharedAuthTransportTests: XCTestCase {
    func testHostedInvalidCredentialsShapeBecomesTypedAuthFailure() async throws {
        let auth = client(host: "invalid-credentials.test")
        do {
            _ = try await auth.signIn(email: "person@example.test", password: "invented-wrong-password")
            XCTFail("Expected sign-in rejection")
        } catch {
            XCTAssertEqual(error as? SharedAuthFailure, .invalidCredentials)
        }
    }

    func testAuthErrorCodeWithoutNumericCodeBecomesTypedAuthFailure() async throws {
        let auth = client(host: "error-code-only.test")
        do {
            _ = try await auth.signIn(email: "person@example.test", password: "invented-wrong-password")
            XCTFail("Expected sign-in rejection")
        } catch {
            XCTAssertEqual(error as? SharedAuthFailure, .invalidCredentials)
        }
    }

    func testUnknownAndMalformedAuthBadRequestsRemainInvalidResponse() async throws {
        for host in ["unknown-auth-error.test", "malformed-auth-error.test"] {
            do {
                _ = try await client(host: host).signIn(
                    email: "person@example.test", password: "invented-wrong-password")
                XCTFail("Expected sign-in rejection for \(host)")
            } catch {
                XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, host)
            }
        }
    }

    func testKnownRefreshTokenRejectionsRequireSignIn() async throws {
        for host in ["refresh-token-not-found.test", "refresh-token-already-used.test"] {
            do {
                _ = try await client(host: host).refresh(refreshToken: "invented-expired-refresh-token")
                XCTFail("Expected refresh rejection for \(host)")
            } catch {
                XCTAssertEqual(error as? SharedStateFailure, .unauthenticated, host)
            }
        }
    }

    func testServiceBadRequestKeepsItsOwnCodeDespiteAuthErrorCode() async throws {
        let service = SharedHTTPClient(serverURL: url(host: "service-invalid-invite.test"),
                                       accessToken: "invented-access-token", session: session())
        do {
            _ = try await service.joinSpace(inviteToken: "invented-invite")
            XCTFail("Expected invalid invitation")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidInvite)
        }
    }

    func testServiceDoesNotInterpretSupabaseErrorCodeWithoutServiceCode() async throws {
        let service = SharedHTTPClient(serverURL: url(host: "service-auth-code-only.test"),
                                       accessToken: "invented-access-token", session: session())
        do {
            _ = try await service.joinSpace(inviteToken: "invented-invite")
            XCTFail("Expected service bad request")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
    }

    func testAuthUnauthorizedKeepsExistingUnauthenticatedFailure() async throws {
        do {
            _ = try await client(host: "auth-unauthorized.test").getUser(
                accessToken: "invented-access-token")
            XCTFail("Expected unauthorized user request")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .unauthenticated)
        }
    }

    func testSuccessfulSignInDecodesSessionAndSendsPublicKeyAndPasswordGrant() async throws {
        let result = try await client(host: "successful-sign-in.test").signIn(
            email: "person@example.test", password: "invented-password")
        XCTAssertEqual(result.access_token, "invented-access-token")
        XCTAssertEqual(result.refresh_token, "invented-refresh-token")
        XCTAssertEqual(result.expires_in, 3600)
        XCTAssertEqual(result.user.id, UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        XCTAssertEqual(result.user.email, "person@example.test")
    }

    private func client(host: String) -> SharedAuthClient {
        SharedAuthClient(authURL: url(host: host), publishableKey: "public-test-key", session: session())
    }

    private func url(host: String) -> URL {
        URL(string: "https://\(host)")!
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticTransportProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Immutable host fixtures keep concurrently running URLSession tests independent.
private final class SyntheticTransportProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let host = url.host ?? ""
        let result: (status: Int, body: String)
        switch host {
        case "invalid-credentials.test":
            result = (400, #"{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#)
        case "error-code-only.test":
            result = (400, #"{"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#)
        case "unknown-auth-error.test":
            result = (400, #"{"code":400,"error_code":"new_provider_error","msg":"Something changed"}"#)
        case "malformed-auth-error.test":
            result = (400, "not-json")
        case "refresh-token-not-found.test":
            result = (400, #"{"code":400,"error_code":"refresh_token_not_found","msg":"Invalid Refresh Token: Refresh Token Not Found"}"#)
        case "refresh-token-already-used.test":
            result = (400, #"{"code":400,"error_code":"refresh_token_already_used","msg":"Invalid Refresh Token: Already Used"}"#)
        case "service-invalid-invite.test":
            result = (400, #"{"code":"invalidInvite","error_code":"invalid_credentials"}"#)
        case "service-auth-code-only.test":
            result = (400, #"{"error_code":"invalid_credentials"}"#)
        case "auth-unauthorized.test":
            result = (401, #"{"code":401,"error_code":"invalid_token"}"#)
        case "successful-sign-in.test":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let valid = url.path == "/auth/v1/token" &&
                query == [URLQueryItem(name: "grant_type", value: "password")] &&
                request.httpMethod == "POST" &&
                request.value(forHTTPHeaderField: "apikey") == "public-test-key" &&
                request.value(forHTTPHeaderField: "Authorization") == nil
            result = valid
                ? (200, #"{"access_token":"invented-access-token","refresh_token":"invented-refresh-token","expires_in":3600,"user":{"id":"11111111-1111-4111-8111-111111111111","email":"person@example.test"}}"#)
                : (418, #"{"code":"unexpectedRequest"}"#)
        default:
            result = (418, #"{"code":"unexpectedHost"}"#)
        }
        let response = HTTPURLResponse(url: url, statusCode: result.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
