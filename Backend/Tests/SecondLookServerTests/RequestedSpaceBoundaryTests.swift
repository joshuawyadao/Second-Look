import Foundation
import Testing
import VaporTesting
import SecondLookCore
@testable import SecondLookServer

@Suite struct RequestedSpaceBoundaryTests {
    private let owner = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
    private let requestedSpace = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    private let otherSpace = UUID(uuidString: "30000000-0000-0000-0000-000000000004")!

    private func configuration(debugEvidence: Bool = false) throws -> ServerConfiguration {
        var environment = [
            "SECONDLOOK_PROVIDER_URL": "http://127.0.0.1:56321",
            "SECONDLOOK_PUBLISHABLE_KEY": "synthetic-public-configuration",
            "SECONDLOOK_SERVICE_KEY": "synthetic-server-only-secret",
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
            "SECONDLOOK_LOCAL_DEVELOPMENT": "1"
        ]
        if debugEvidence { environment["SECONDLOOK_TEST_EVIDENCE"] = "1" }
        return try ServerConfiguration(environment: environment)
    }

    private func authenticated(_ request: inout TestingHTTPRequest) {
        request.headers.bearerAuthorization = .init(token: "verified-synthetic")
    }

    private func command() -> SharedCommandEnvelope {
        SharedCommandEnvelope(spaceID: requestedSpace, commandID: UUID(), expectedSpaceRevision: 0,
            command: .startOneOff(title: "Synthetic checklist",
                items: [RoutineItem(title: "Synthetic step")], settings: .init()))
    }

    @Test func explicitReadRejectsAnotherValidSpaceButCurrentSpaceCanDiscoverIt() async throws {
        let store = RequestedSpaceStore(owner: owner, peer: peer, requested: requestedSpace,
                                        other: otherSpace, mode: .wrongRead)
        try await withApp { app in
            try configure(app, configuration: try configuration(),
                verifier: RequestedSpaceVerifier(owner: owner), store: store)
            try await app.testing().test(.GET, "/v1/spaces/\(requestedSpace)",
                beforeRequest: authenticated) { response in
                #expect(response.status == .serviceUnavailable)
                #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
            }
            try await app.testing().test(.GET, "/v1/space", beforeRequest: authenticated) { response in
                #expect(response.status == .ok)
                let snapshot = try SharedWireCodec.decode(SharedSnapshot.self,
                    from: Data(response.body.readableBytesView))
                #expect(snapshot.spaceID == otherSpace)
            }
            // Create and join also receive a newly discovered space, with no requested ID.
            try await app.testing().test(.POST, "/v1/spaces", beforeRequest: { request in
                authenticated(&request)
                request.body = ByteBuffer(string: "{}")
            }) { response in
                #expect(response.status == .ok)
            }
            try await app.testing().test(.POST, "/v1/pairing/join", beforeRequest: { request in
                authenticated(&request)
                request.body = ByteBuffer(string: "{\"inviteToken\":\"\(String(repeating: "a", count: 72))\"}")
            }) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test func commandRejectsWrongSpaceFromReadBothReceiptsAndCommit() async throws {
        for mode in [RequestedSpaceStore.Mode.wrongRead, .earlyReceipt, .racingReceipt, .wrongCommit] {
            let store = RequestedSpaceStore(owner: owner, peer: peer, requested: requestedSpace,
                                            other: otherSpace, mode: mode)
            let body = String(decoding: try SharedWireCodec.encode(command()), as: UTF8.self)
            try await withApp { app in
                try configure(app, configuration: try configuration(),
                    verifier: RequestedSpaceVerifier(owner: owner), store: store)
                try await app.testing().test(.POST, "/v1/spaces/\(requestedSpace)/commands",
                    beforeRequest: { request in
                        authenticated(&request)
                        request.body = ByteBuffer(string: body)
                    }) { response in
                    #expect(response.status == .serviceUnavailable, "Boundary: \(mode)")
                    #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
                }
            }
            #expect(await store.commitCount() == (mode == .wrongCommit ? 1 : 0))
        }
    }

    @Test func matchingExplicitSpaceStillReadsAndCommits() async throws {
        let store = RequestedSpaceStore(owner: owner, peer: peer, requested: requestedSpace,
                                        other: otherSpace, mode: .valid)
        let body = String(decoding: try SharedWireCodec.encode(command()), as: UTF8.self)
        try await withApp { app in
            try configure(app, configuration: try configuration(),
                verifier: RequestedSpaceVerifier(owner: owner), store: store)
            try await app.testing().test(.GET, "/v1/spaces/\(requestedSpace)",
                beforeRequest: authenticated) { response in
                #expect(response.status == .ok)
            }
            try await app.testing().test(.POST, "/v1/spaces/\(requestedSpace)/commands",
                beforeRequest: { request in
                    authenticated(&request)
                    request.body = ByteBuffer(string: body)
                }) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(await store.commitCount() == 1)
    }

    #if DEBUG
    @Test func debugSyntheticEvidenceRejectsWrongSpaceAtReadAndPublication() async throws {
        let initial = SharedSnapshot(spaceID: requestedSpace, revision: 0,
                                     members: [owner, peer], state: .init())
        let created = try SharedCommandProcessor.apply(
            SharedCommandEnvelope(spaceID: requestedSpace, commandID: UUID(), expectedSpaceRevision: 0,
                command: .startOneOff(title: "Synthetic evidence checklist",
                    items: [RoutineItem(title: "Synthetic photo", priority: .high)], settings: .init())),
            to: initial, actorID: owner, now: Date())
        let run = try #require(created.snapshot.state.runs.first)
        let item = try #require(run.items.first)
        let body = "{\"spaceID\":\"\(requestedSpace)\",\"runID\":\"\(run.id)\",\"itemID\":\"\(item.id)\",\"expectedSpaceRevision\":\(created.snapshot.revision),\"expectedRunRevision\":\(run.revision)}"
        for mode in [RequestedSpaceStore.Mode.wrongRead, .wrongCommit, .valid] {
            let store = RequestedSpaceStore(owner: owner, peer: peer, requested: requestedSpace,
                other: otherSpace, mode: mode, evidenceSource: created.snapshot)
            try await withApp { app in
                try configure(app, configuration: try configuration(debugEvidence: true),
                    verifier: RequestedSpaceVerifier(owner: owner), store: store)
                try await app.testing().test(.POST, "/_testing/synthetic-evidence",
                    beforeRequest: { request in
                        authenticated(&request)
                        request.body = ByteBuffer(string: body)
                    }) { response in
                    #expect(response.status == (mode == .valid ? .ok : .serviceUnavailable))
                }
            }
            #expect(await store.commitCount() == (mode == .wrongRead ? 0 : 1))
        }
    }
    #endif
}

private struct RequestedSpaceVerifier: AccountVerifier {
    let owner: UUID
    func account(for bearer: String) async throws -> UUID {
        guard bearer == "verified-synthetic" else { throw SharedStateFailure.unauthenticated }
        return owner
    }
}

private actor RequestedSpaceStore: SpaceStore {
    enum Mode: Sendable { case wrongRead, earlyReceipt, racingReceipt, wrongCommit, valid }
    let owner: UUID
    let peer: UUID
    let requested: UUID
    let other: UUID
    let mode: Mode
    let evidenceSource: SharedSnapshot?
    private var receipts = 0
    private var commits = 0

    init(owner: UUID, peer: UUID, requested: UUID, other: UUID, mode: Mode,
         evidenceSource: SharedSnapshot? = nil) {
        self.owner = owner
        self.peer = peer
        self.requested = requested
        self.other = other
        self.mode = mode
        self.evidenceSource = evidenceSource
    }

    func commitCount() -> Int { commits }

    private var validSnapshot: SharedSnapshot {
        if let evidenceSource { return evidenceSource }
        return SharedSnapshot(spaceID: requested, revision: mode == .racingReceipt ? 1 : 0,
                              members: [owner, peer], state: .init())
    }
    private var wrongSnapshot: SharedSnapshot {
        var snapshot = validSnapshot
        snapshot.spaceID = other
        return snapshot
    }

    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot {
        mode == .wrongRead ? wrongSnapshot : validSnapshot
    }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date,
                expectedRevision: Int?) async throws -> SharedSnapshot { wrongSnapshot }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot { wrongSnapshot }
    func receipt(actor: UUID, envelope: SharedCommandEnvelope,
                 digest: String) async throws -> SharedCommandResult? {
        receipts += 1
        if mode == .earlyReceipt || (mode == .racingReceipt && receipts == 2) {
            return SharedCommandResult(snapshot: wrongSnapshot)
        }
        return nil
    }
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String,
                result: SharedCommandResult) async throws -> SharedCommandResult {
        commits += 1
        return mode == .wrongCommit ? SharedCommandResult(snapshot: wrongSnapshot) : result
    }
}
