import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SecondLookCore
import SecondLookTransport

@MainActor
final class SharedCapacityTransportTests: XCTestCase {
    private let owner = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    private let space = UUID(uuidString: "40000000-0000-0000-0000-000000000002")!

    private func client(host: String = "capacity-command.test") -> SharedHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapacityCommandProtocol.self]
        return SharedHTTPClient(serverURL: URL(string: "https://\(host)")!,
            accessToken: "invented-access-token", session: URLSession(configuration: configuration))
    }

    func testCapacityConflictRetainsScopeAndHasNoUnconfirmedRetry() async throws {
        let initial = SharedSnapshot(spaceID: space, revision: 0, members: [owner], state: .init())
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: .init(backend: "capacity-test", accountID: owner, spaceID: space),
            client: CapacityClient(initial: initial, transport: client()))
        _ = try await coordinator.refresh()
        let id = UUID()
        do {
            _ = try await coordinator.execute(.startOneOff(title: "Invented list",
                items: [RoutineItem(title: "Keys")], settings: .init()), commandID: id)
            XCTFail("A capacity conflict must be a definite rejection")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .capacityExceeded)
        }
        XCTAssertEqual(coordinator.snapshot, initial)
        XCTAssertEqual(coordinator.scope?.accountID, owner)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: id))
    }

    func testUnknownConflictDoesNotBecomeCapacityOrAccountLoss() async throws {
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 0, command: .startOneOff(title: "Invented list",
                items: [RoutineItem(title: "Keys")], settings: .init()))
        do {
            _ = try await client(host: "unknown-capacity-command.test").execute(envelope)
            XCTFail("An unknown conflict must fail closed")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable)
        }
    }
}

private struct CapacityClient: SharedStateClient {
    let initial: SharedSnapshot
    let transport: SharedHTTPClient
    func fetch(spaceID: UUID) async throws -> SharedSnapshot { initial }
    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        try await transport.execute(envelope)
    }
}

private final class CapacityCommandProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        ["capacity-command.test", "unknown-capacity-command.test"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let code = url.host == "capacity-command.test" ? "capacityExceeded" : "unknownConflict"
        let response = HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"code\":\"\(code)\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
