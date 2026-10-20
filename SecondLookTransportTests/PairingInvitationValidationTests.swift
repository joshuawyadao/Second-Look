import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SecondLookCore
@testable import SecondLookTransport

final class PairingInvitationValidationTests: XCTestCase {
    func testCreateRejectsMalformedTokensAndExpiredHTTP200Replies() async throws {
        for name in ["empty", "truncated", "compact", "invalid", "wrong-layout", "unicode", "expired"] {
            do {
                _ = try await client(name).createSpace()
                XCTFail("Malformed invitation must not reach publication: \(name)")
            } catch {
                XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, name)
            }
        }
    }

    func testCreatePreservesLiveCanonicalInvitationAndSnapshot() async throws {
        for name in ["valid", "lowercase"] {
            let result = try await client(name).createSpace(expectedSpaceRevision: 3)
            let expected = try PairingReplyProtocol.reply(name)
            XCTAssertEqual(result.inviteToken, expected.inviteToken)
            XCTAssertEqual(result.snapshot, expected.snapshot)
            XCTAssertGreaterThan(result.expiresAt, Date())
        }
    }

    func testDeadlineMustStillBeFutureWhenPublicationResumes() throws {
        let reply = try PairingReplyProtocol.reply("valid")
        let invitation = PairingInvitation(snapshot: reply.snapshot, inviteToken: reply.inviteToken,
            expiresAt: reply.expiresAt)
        XCTAssertNoThrow(try invitation.validateForPublication(now: reply.expiresAt.addingTimeInterval(-1)))
        for now in [reply.expiresAt, reply.expiresAt.addingTimeInterval(1)] {
            XCTAssertThrowsError(try invitation.validateForPublication(now: now)) {
                XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
            }
        }
        for deadline in [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan)] {
            let invalid = PairingInvitation(snapshot: reply.snapshot, inviteToken: reply.inviteToken,
                expiresAt: deadline)
            XCTAssertThrowsError(try invalid.validateForPublication()) {
                XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
            }
        }
    }

    private func client(_ name: String) -> SharedHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingReplyProtocol.self]
        return SharedHTTPClient(serverURL: URL(string: "https://\(name).pairing.test")!,
            accessToken: "invented-token", session: URLSession(configuration: configuration))
    }
}

private final class PairingReplyProtocol: URLProtocol {
    struct Reply: Encodable {
        let snapshot: SharedSnapshot
        let inviteToken: String
        let expiresAt: Date
    }

    static func reply(_ name: String) throws -> Reply {
        let canonical = "11111111-1111-4111-8111-111111111111AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let token: String
        switch name {
        case "empty": token = ""
        case "truncated": token = String(canonical.dropLast())
        case "compact": token = canonical.replacingOccurrences(of: "-", with: "")
        case "invalid": token = String(repeating: "x", count: 72)
        case "wrong-layout": token = canonical.replacingOccurrences(of: "-", with: "_")
        case "unicode": token = "é" + canonical.dropFirst()
        case "lowercase": token = canonical.lowercased()
        default: token = canonical
        }
        return Reply(snapshot: SharedSnapshot(spaceID: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            revision: 4, members: [UUID(uuidString: "00000000-0000-4000-8000-000000000001")!],
            state: SecondLookState()), inviteToken: token,
            expiresAt: Date().addingTimeInterval(name == "expired" ? -60 : 900))
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".pairing.test") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/v1/spaces")
            XCTAssertEqual(request.httpMethod, "POST")
            let name = try XCTUnwrap(url.host?.components(separatedBy: ".").first)
            let data = try SharedWireCodec.encode(Self.reply(name))
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
