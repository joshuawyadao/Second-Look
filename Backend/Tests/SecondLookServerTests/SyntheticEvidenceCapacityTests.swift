import Foundation
import Testing
import VaporTesting
import SecondLookCore
@testable import SecondLookServer

#if DEBUG
@Suite struct SyntheticEvidenceCapacityTests {
    private let owner = UUID(uuidString: "90000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "90000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "90000000-0000-0000-0000-000000000003")!

    private func configuration() throws -> ServerConfiguration {
        try ServerConfiguration(environment: [
            "SECONDLOOK_PROVIDER_URL": "http://127.0.0.1:56321",
            "SECONDLOOK_PUBLISHABLE_KEY": "synthetic-public-configuration",
            "SECONDLOOK_SERVICE_KEY": "synthetic-server-only-secret",
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
            "SECONDLOOK_LOCAL_DEVELOPMENT": "1",
            "SECONDLOOK_TEST_EVIDENCE": "1",
        ])
    }

    private func snapshot(revision: Int) throws -> SharedSnapshot {
        var state = SecondLookState()
        _ = try state.startOneOff(title: "Invented high-priority list",
                                   items: [RoutineItem(title: "Door", priority: .high)],
                                   performerID: owner, reviewerID: peer,
                                   now: Date(timeIntervalSince1970: 1_700_000_000))
        return SharedSnapshot(spaceID: space, revision: revision,
                              members: [owner, peer], state: state)
    }

    private func submit(_ source: SharedSnapshot,
                        check: @escaping (TestingHTTPResponse) throws -> Void) async throws -> Int {
        let store = SyntheticCapacityStore(snapshot: source)
        let run = try #require(source.state.runs.first)
        let item = try #require(run.items.first)
        let body = "{\"spaceID\":\"\(space)\",\"runID\":\"\(run.id)\",\"itemID\":\"\(item.id)\",\"expectedSpaceRevision\":\(source.revision),\"expectedRunRevision\":\(run.revision)}"
        try await withApp { app in
            try configure(app, configuration: try configuration(),
                          verifier: SyntheticCapacityVerifier(owner: owner), store: store)
            try await app.testing().test(.POST, "/_testing/synthetic-evidence",
                beforeRequest: { request in
                    request.headers.bearerAuthorization = .init(token: "verified-synthetic")
                    request.body = ByteBuffer(string: body)
                }, afterResponse: check)
        }
        return await store.commitCount()
    }

    @Test func exhaustedSpaceRevisionReturnsBoundedFailureWithoutCommit() async throws {
        let source = try snapshot(revision: Int.max)
        try source.validate(for: owner)
        let commits = try await submit(source) { response in
            #expect(response.status == .serviceUnavailable)
            #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
            #expect(response.headers[.cacheControl] == ["no-store"])
        }
        #expect(commits == 0)
    }

    @Test func lastAvailableRevisionCommitsExactlyOnce() async throws {
        let source = try snapshot(revision: Int.max - 1)
        let commits = try await submit(source) { response in
            #expect(response.status == .ok)
            let committed = try SharedWireCodec.decode(SharedSnapshot.self,
                from: Data(response.body.readableBytesView))
            #expect(committed.revision == Int.max)
            #expect(committed.state.runs.first?.items.first?.submission?.status == .waitingForReview)
        }
        #expect(commits == 1)
    }
}
#endif

private struct SyntheticCapacityVerifier: AccountVerifier {
    let owner: UUID
    func account(for bearer: String) async throws -> UUID {
        guard bearer == "verified-synthetic" else { throw SharedStateFailure.unauthenticated }
        return owner
    }
}

private actor SyntheticCapacityStore: SpaceStore {
    let snapshot: SharedSnapshot
    private var commits = 0
    init(snapshot: SharedSnapshot) { self.snapshot = snapshot }
    func commitCount() -> Int { commits }
    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot { snapshot }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date,
                expectedRevision: Int?) async throws -> SharedSnapshot {
        throw SharedStateFailure.forbidden
    }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot {
        throw SharedStateFailure.forbidden
    }
    func receipt(actor: UUID, envelope: SharedCommandEnvelope,
                 digest: String) async throws -> SharedCommandResult? {
        throw SharedStateFailure.forbidden
    }
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String,
                result: SharedCommandResult) async throws -> SharedCommandResult {
        commits += 1
        return result
    }
}
