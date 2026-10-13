import Foundation
import Testing
import VaporTesting
import SecondLookCore
@testable import SecondLookServer

@Suite struct MembershipAllowlistBoundaryTests {
    private let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private let excluded = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
    private let space = UUID(uuidString: "20000000-0000-0000-0000-000000000004")!

    private func configuration(testEvidence: Bool = false) throws -> ServerConfiguration {
        var environment = [
            "SECONDLOOK_PROVIDER_URL": "http://127.0.0.1:56321",
            "SECONDLOOK_PUBLISHABLE_KEY": "synthetic-public-configuration",
            "SECONDLOOK_SERVICE_KEY": "synthetic-server-only-secret",
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
            "SECONDLOOK_LOCAL_DEVELOPMENT": "1"
        ]
        if testEvidence { environment["SECONDLOOK_TEST_EVIDENCE"] = "1" }
        return try ServerConfiguration(environment: environment)
    }

    private func request(_ request: inout TestingHTTPRequest) {
        request.headers.bearerAuthorization = .init(token: "verified-synthetic")
    }

    private func envelope(revision: Int = 0) -> SharedCommandEnvelope {
        SharedCommandEnvelope(spaceID: space, commandID: UUID(), expectedSpaceRevision: revision,
            command: .startOneOff(title: "Synthetic checklist",
                items: [RoutineItem(title: "Synthetic step")], settings: .init()))
    }

    @Test func everySpaceResponseRejectsStoredExcludedMember() async throws {
        let store = MembershipBoundaryStore(owner: owner, peer: peer, excluded: excluded,
                                            space: space, mode: .excluded)
        try await withApp { app in
            try configure(app, configuration: try configuration(),
                verifier: BoundaryVerifier(owner: owner), store: store)
            for path in ["/v1/space", "/v1/spaces/\(space)"] {
                try await app.testing().test(.GET, path, beforeRequest: request) { response in
                    #expect(response.status == .forbidden)
                    #expect(response.body.string == "{\"code\":\"forbidden\"}")
                }
            }
            try await app.testing().test(.POST, "/v1/spaces", beforeRequest: { request in
                self.request(&request)
                request.body = ByteBuffer(string: "{}")
            }) { response in
                #expect(response.status == .forbidden)
                #expect(response.body.string == "{\"code\":\"forbidden\"}")
            }
            try await app.testing().test(.POST, "/v1/pairing/join", beforeRequest: { request in
                self.request(&request)
                request.body = ByteBuffer(string: "{\"inviteToken\":\"\(String(repeating: "a", count: 72))\"}")
            }) { response in
                #expect(response.status == .forbidden)
                #expect(response.body.string == "{\"code\":\"forbidden\"}")
            }
        }
    }

    @Test func commandRejectsExcludedMemberBeforeProcessorAndAtEveryReceiptBoundary() async throws {
        for mode in [MembershipBoundaryStore.Mode.badRead, .earlyReceipt, .racingReceipt, .badCommit] {
            let store = MembershipBoundaryStore(owner: owner, peer: peer, excluded: excluded,
                                                space: space, mode: mode)
            try await withApp { app in
                try configure(app, configuration: try configuration(),
                    verifier: BoundaryVerifier(owner: owner), store: store)
                let data = try SharedWireCodec.encode(envelope())
                try await app.testing().test(.POST, "/v1/spaces/\(space)/commands", beforeRequest: { request in
                    self.request(&request)
                    request.body = ByteBuffer(string: String(decoding: data, as: UTF8.self))
                }) { response in
                    #expect(response.status == .forbidden, "Rejected boundary: \(mode)")
                    #expect(response.body.string == "{\"code\":\"forbidden\"}")
                }
            }
            let commits = await store.commitCount()
            #expect(commits == (mode == .badCommit ? 1 : 0), "Commit count for \(mode)")
        }
    }

    @Test func validSingleAndPairedSpacesRemainAvailable() async throws {
        for mode in [MembershipBoundaryStore.Mode.single, .paired] {
            let store = MembershipBoundaryStore(owner: owner, peer: peer, excluded: excluded,
                                                space: space, mode: mode)
            try await withApp { app in
                try configure(app, configuration: try configuration(),
                    verifier: BoundaryVerifier(owner: owner), store: store)
                try await app.testing().test(.GET, "/v1/space", beforeRequest: request) { response in
                    #expect(response.status == .ok)
                }
                try await app.testing().test(.POST, "/v1/spaces", beforeRequest: { request in
                    self.request(&request)
                    request.body = ByteBuffer(string: "{}")
                }) { response in
                    #expect(response.status == .ok)
                }
                try await app.testing().test(.POST, "/v1/pairing/join", beforeRequest: { request in
                    self.request(&request)
                    request.body = ByteBuffer(string: "{\"inviteToken\":\"\(String(repeating: "a", count: 72))\"}")
                }) { response in
                    #expect(response.status == .ok)
                }
                let data = try SharedWireCodec.encode(envelope())
                try await app.testing().test(.POST, "/v1/spaces/\(space)/commands", beforeRequest: { request in
                    self.request(&request)
                    request.body = ByteBuffer(string: String(decoding: data, as: UTF8.self))
                }) { response in
                    #expect(response.status == .ok)
                }
            }
            #expect(await store.commitCount() == 1)
        }
    }

    #if DEBUG
    @Test func debugSyntheticEvidenceRejectsExcludedMembershipOnReadAndCommit() async throws {
        let initial = SharedSnapshot(spaceID: space, revision: 0,
                                     members: [owner, peer], state: .init())
        let creation = try SharedCommandProcessor.apply(
            SharedCommandEnvelope(spaceID: space, commandID: UUID(), expectedSpaceRevision: 0,
                command: .startOneOff(title: "Synthetic evidence checklist",
                    items: [RoutineItem(title: "Synthetic photo", priority: .high)], settings: .init())),
            to: initial, actorID: owner, now: Date())
        let run = try #require(creation.snapshot.state.runs.first)
        let item = try #require(run.items.first)
        let body = "{\"spaceID\":\"\(space)\",\"runID\":\"\(run.id)\",\"itemID\":\"\(item.id)\",\"expectedSpaceRevision\":\(creation.snapshot.revision),\"expectedRunRevision\":\(run.revision)}"
        for mode in [MembershipBoundaryStore.Mode.badRead, .badCommit, .paired] {
            let store = MembershipBoundaryStore(owner: owner, peer: peer, excluded: excluded,
                space: space, mode: mode, evidenceSource: creation.snapshot)
            try await withApp { app in
                try configure(app, configuration: try configuration(testEvidence: true),
                    verifier: BoundaryVerifier(owner: owner), store: store)
                try await app.testing().test(.POST, "/_testing/synthetic-evidence", beforeRequest: { request in
                    self.request(&request)
                    request.body = ByteBuffer(string: body)
                }) { response in
                    #expect(response.status == (mode == .paired ? .ok : .forbidden))
                    if mode != .paired {
                        #expect(response.body.string == "{\"code\":\"forbidden\"}")
                    }
                }
            }
            #expect(await store.commitCount() == (mode == .badRead ? 0 : 1))
        }
    }
    #endif
}

private struct BoundaryVerifier: AccountVerifier {
    let owner: UUID
    func account(for bearer: String) async throws -> UUID {
        guard bearer == "verified-synthetic" else { throw SharedStateFailure.unauthenticated }
        return owner
    }
}

private actor MembershipBoundaryStore: SpaceStore {
    enum Mode: Sendable { case excluded, badRead, earlyReceipt, racingReceipt, badCommit, single, paired }
    let owner: UUID
    let peer: UUID
    let excluded: UUID
    let space: UUID
    let mode: Mode
    let evidenceSource: SharedSnapshot?
    private var receipts = 0
    private var commits = 0

    init(owner: UUID, peer: UUID, excluded: UUID, space: UUID, mode: Mode,
         evidenceSource: SharedSnapshot? = nil) {
        self.owner = owner
        self.peer = peer
        self.excluded = excluded
        self.space = space
        self.mode = mode
        self.evidenceSource = evidenceSource
    }

    func commitCount() -> Int { commits }

    private var snapshot: SharedSnapshot {
        let members: [UUID] = mode == .single ? [owner] : [owner, peer]
        return SharedSnapshot(spaceID: space, revision: mode == .racingReceipt ? 1 : 0,
                              members: members, state: .init())
    }
    private var excludedSnapshot: SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: 0, members: [owner, excluded], state: .init())
    }

    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot {
        if let evidenceSource {
            var result = evidenceSource
            if mode == .badRead { result.members = [owner, excluded] }
            return result
        }
        return mode == .excluded || mode == .badRead ? excludedSnapshot : snapshot
    }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date,
                expectedRevision: Int?) async throws -> SharedSnapshot {
        mode == .excluded ? excludedSnapshot : snapshot
    }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot {
        mode == .excluded ? excludedSnapshot : snapshot
    }
    func receipt(actor: UUID, envelope: SharedCommandEnvelope,
                 digest: String) async throws -> SharedCommandResult? {
        receipts += 1
        if mode == .earlyReceipt || (mode == .racingReceipt && receipts == 2) {
            return SharedCommandResult(snapshot: excludedSnapshot)
        }
        return nil
    }
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String,
                result: SharedCommandResult) async throws -> SharedCommandResult {
        commits += 1
        return mode == .badCommit ? SharedCommandResult(snapshot: excludedSnapshot) : result
    }
}
