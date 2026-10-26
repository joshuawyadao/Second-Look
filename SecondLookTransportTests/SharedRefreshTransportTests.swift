import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SecondLookCore
import SecondLookTransport

final class SharedRefreshTransportTests: XCTestCase {
    func testFullReplyRetainsItsOpaqueContentValidatorInOneRequest() async throws {
        let result = try await client("full").refreshCurrentSpace()
        XCTAssertEqual(result, .snapshot(RefreshProtocol.snapshot, validator: RefreshProtocol.validator))
        let requests = RefreshProtocol.observed.requests(for: "full.refresh.test")
        XCTAssertEqual(requests.count, 1, "One full discovery response must suffice")
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testLegacyServerWithoutValidatorStillSuppliesAFullSnapshot() async throws {
        let result = try await client("legacy").refreshCurrentSpace(known: RefreshProtocol.validator)
        XCTAssertEqual(result, .snapshot(RefreshProtocol.snapshot, validator: nil))
    }

    func testUnchangedRequiresExactRequestedVersionTokenAndResponseHeader() async throws {
        let result = try await client("unchanged").refreshCurrentSpace(known: RefreshProtocol.validator)
        XCTAssertEqual(result, .unchanged(RefreshProtocol.validator))
        let requests = RefreshProtocol.observed.requests(for: "unchanged.refresh.test")
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), RefreshProtocol.entityTag)
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "knownSpaceID" })?.value,
                       RefreshProtocol.snapshot.spaceID.uuidString)
        XCTAssertEqual(query?.first(where: { $0.name == "knownRevision" })?.value, "7")
    }

    func testUnsolicitedUnchangedCannotSeedDiscovery() async throws {
        await expect(.invalidResponse) { try await self.client("unsolicited").refreshCurrentSpace() }
        await expect(.invalidResponse) { try await self.client("legacy-unchanged").currentSpace() }
    }

    func testUnchangedRejectsMismatchedTokenRevisionAndHeader() async throws {
        for host in ["wrong-token", "wrong-revision", "wrong-space", "missing-etag", "wrong-etag"] {
            await expect(.invalidResponse) {
                try await self.client(host).refreshCurrentSpace(known: RefreshProtocol.validator)
            }
        }
    }

    func testMalformedFullBodyNeverFallsBackToUnchanged() async throws {
        for host in ["malformed-full", "ambiguous", "null-unchanged"] {
            await expect(.invalidResponse) {
                try await self.client(host).refreshCurrentSpace(known: RefreshProtocol.validator)
            }
        }
    }

    func testInvalidKnownValidatorFailsBeforeHTTP() async throws {
        let invalid = SharedSnapshotValidator(spaceID: RefreshProtocol.snapshot.spaceID, revision: -1,
                                               token: "not-a-valid-content-token")
        await expect(.invalidResponse) { try await self.client("invalid").refreshCurrentSpace(known: invalid) }
        XCTAssertTrue(RefreshProtocol.observed.requests(for: "invalid.refresh.test").isEmpty)
    }

    func testConditionalMethodStillRejectsAllRedirectStatuses() async throws {
        for host in ["redirect", "not-modified"] {
            await expect(.serviceUnavailable) {
                try await self.client(host).refreshCurrentSpace(known: RefreshProtocol.validator)
            }
        }
    }

    func testOnlyCodedCommand429IsATypeSafeAdmissionRejection() async throws {
        await expect(.rateLimited) { try await self.client("rate-limited").refreshCurrentSpace() }
        await expect(.serviceUnavailable) { try await self.client("uncoded-rate-limit").refreshCurrentSpace() }
        let configuration = configuration()
        let auth = SharedAuthClient(authURL: URL(string: "https://rate-limited.refresh.test")!,
                                    publishableKey: "public-test-key", session: URLSession(configuration: configuration))
        await expect(.serviceUnavailable) { try await auth.getUser(accessToken: "invented-token") }
    }

    private func client(_ name: String) -> SharedHTTPClient {
        SharedHTTPClient(serverURL: URL(string: "https://\(name).refresh.test")!, accessToken: "invented-token",
                         session: URLSession(configuration: configuration()))
    }
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshProtocol.self]
        return configuration
    }
    private func expect<T>(_ failure: SharedStateFailure, operation: () async throws -> T,
                           file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(failure)", file: file, line: line) }
        catch { XCTAssertEqual(error as? SharedStateFailure, failure, file: file, line: line) }
    }
}

private final class RefreshRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func add(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; values.append(request) }
    func requests(for host: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return values.filter { $0.url?.host == host }
    }
}

private final class RefreshProtocol: URLProtocol, @unchecked Sendable {
    static let observed = RefreshRequests()
    static let snapshot = SharedSnapshot(spaceID: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
        revision: 7, members: [UUID(uuidString: "10000000-0000-0000-0000-000000000001")!], state: SecondLookState())
    static let validator = SharedSnapshotValidator(spaceID: snapshot.spaceID, revision: snapshot.revision,
                                                   token: String(repeating: "a", count: 64))
    static let entityTag = "\"\(validator.token)\""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.observed.add(request)
        let host = request.url?.host ?? ""
        var status = 200
        var headers = ["Content-Type": "application/json", "ETag": Self.entityTag]
        do {
            var body = try SharedWireCodec.encode(SharedUnchangedReply(unchanged: Self.validator))
            switch host {
            case "full.refresh.test", "legacy.refresh.test":
                body = try SharedWireCodec.encode(Self.snapshot)
                if host.hasPrefix("legacy") { headers.removeValue(forKey: "ETag") }
            case "wrong-token.refresh.test":
                body = try SharedWireCodec.encode(SharedUnchangedReply(unchanged: SharedSnapshotValidator(
                    spaceID: Self.snapshot.spaceID, revision: 7, token: String(repeating: "b", count: 64))))
            case "wrong-revision.refresh.test":
                body = try SharedWireCodec.encode(SharedUnchangedReply(unchanged: SharedSnapshotValidator(
                    spaceID: Self.snapshot.spaceID, revision: 8, token: Self.validator.token)))
            case "wrong-space.refresh.test":
                body = try SharedWireCodec.encode(SharedUnchangedReply(unchanged: SharedSnapshotValidator(
                    spaceID: UUID(), revision: 7, token: Self.validator.token)))
            case "missing-etag.refresh.test": headers.removeValue(forKey: "ETag")
            case "wrong-etag.refresh.test": headers["ETag"] = "\"wrong\""
            case "malformed-full.refresh.test": body = Data(#"{"state":"malformed"}"#.utf8)
            case "ambiguous.refresh.test":
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                object["state"] = "malformed"
                body = try JSONSerialization.data(withJSONObject: object)
            case "null-unchanged.refresh.test": body = Data(#"{"unchanged":null}"#.utf8)
            case "redirect.refresh.test": status = 307
            case "not-modified.refresh.test": status = 304
            case "rate-limited.refresh.test": status = 429; body = Data(#"{"code":"rateLimited"}"#.utf8)
            case "uncoded-rate-limit.refresh.test": status = 429; body = Data(#"{"message":"busy"}"#.utf8)
            default: break
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}
