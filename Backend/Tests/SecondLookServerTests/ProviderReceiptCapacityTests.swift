import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import SecondLookCore
@testable import SecondLookServer

@Suite struct ProviderReceiptCapacityTests {
    private let owner = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "40000000-0000-0000-0000-000000000003")!

    @Test(arguments: [
        ("capacity", SharedStateFailure.capacityExceeded),
        ("stale", SharedStateFailure.staleState),
        ("unknown", SharedStateFailure.serviceUnavailable),
    ])
    func commitMapsOnlyKnownDatabaseRejections(mode: String, expected: SharedStateFailure) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReceiptCapacityProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let server = try ServerConfiguration(environment: [
            "SECONDLOOK_PROVIDER_URL": "https://\(mode).receipt-capacity.test",
            "SECONDLOOK_PUBLISHABLE_KEY": "sb_publishable_synthetic",
            "SECONDLOOK_SERVICE_KEY": "sb_secret_synthetic",
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
        ])
        let provider = SupabaseProvider(configuration: server, session: session)
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 0,
            command: .saveRoutine(definition: Routine(title: "Synthetic", items: []),
                                  expectedDefinitionVersion: nil))
        let result = SharedCommandResult(snapshot: SharedSnapshot(spaceID: space,
            revision: 1, members: [owner, peer], state: SecondLookState()))
        do {
            _ = try await provider.commit(actor: owner, envelope: envelope,
                                          digest: String(repeating: "a", count: 64), result: result)
            Issue.record("A rejected database commit must not report success")
        } catch {
            #expect(error as? SharedStateFailure == expected)
        }
    }
}

private final class ReceiptCapacityProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".receipt-capacity.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              url.path == "/rest/v1/rpc/sl_commit",
              let response = HTTPURLResponse(url: url, statusCode: 400,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let message: String
        switch url.host {
        case "capacity.receipt-capacity.test": message = "capacityExceeded"
        case "stale.receipt-capacity.test": message = "staleState"
        default: message = "unrecognizedProviderFailure"
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"message\":\"\(message)\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
