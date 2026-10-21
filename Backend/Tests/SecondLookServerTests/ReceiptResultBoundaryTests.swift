import Foundation
import Testing
import VaporTesting
import SecondLookCore
@testable import SecondLookServer

@Suite struct ReceiptResultBoundaryTests {
    private let owner = UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "F0000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "F0000000-0000-0000-0000-000000000003")!

    private func configuration() throws -> ServerConfiguration {
        try ServerConfiguration(environment: [
            "SECONDLOOK_PROVIDER_URL": "http://127.0.0.1:56321",
            "SECONDLOOK_PUBLISHABLE_KEY": "synthetic-public-configuration",
            "SECONDLOOK_SERVICE_KEY": "synthetic-server-only-secret",
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
            "SECONDLOOK_LOCAL_DEVELOPMENT": "1",
        ])
    }

    private func envelope(creation: Bool) -> SharedCommandEnvelope {
        let command: SharedCommand = creation
            ? .startOneOff(title: "Invented run", items: [RoutineItem(title: "Step")], settings: .init())
            : .saveRoutine(definition: Routine(title: "Invented", items: [RoutineItem(title: "Step")]),
                           expectedDefinitionVersion: nil)
        return SharedCommandEnvelope(spaceID: space, commandID: UUID(),
                                     expectedSpaceRevision: 0, command: command)
    }

    private func result(revision: Int, createdID: UUID?) -> SharedCommandResult {
        SharedCommandResult(snapshot: SharedSnapshot(spaceID: space, revision: revision,
            members: [owner, peer], state: .init()), createdID: createdID)
    }

    private func request(_ store: ReceiptResultStore,
                         envelope: SharedCommandEnvelope,
                         expected: SharedStateFailure? = nil) async throws {
        try await withApp { app in
            try configure(app, configuration: try configuration(),
                          verifier: ReceiptResultVerifier(account: owner), store: store)
            try await app.testing().test(.POST, "/v1/spaces/\(space)/commands",
                beforeRequest: { request in
                    request.headers.bearerAuthorization = .init(token: "verified-synthetic")
                    request.body = ByteBuffer(data: try SharedWireCodec.encode(envelope))
                }, afterResponse: { response in
                    if expected != nil {
                        #expect(response.status == .serviceUnavailable)
                        #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
                        #expect(response.headers[.cacheControl] == ["no-store"])
                    } else {
                        #expect(response.status == .ok)
                        let decoded = try SharedWireCodec.decode(SharedCommandResult.self,
                            from: Data(response.body.readableBytesView))
                        #expect(decoded == store.supplied)
                    }
                })
        }
    }

    @Test func earlyReceiptsRejectNonadvancingAndWrongCreationMetadata() async throws {
        let cases: [(Bool, SharedCommandResult)] = [
            (false, result(revision: 0, createdID: nil)),
            (true, result(revision: 1, createdID: nil)),
            (false, result(revision: 1, createdID: UUID())),
        ]
        for (creation, supplied) in cases {
            let store = ReceiptResultStore(stage: .early, supplied: supplied, owner: owner)
            try await request(store, envelope: envelope(creation: creation), expected: .invalidResponse)
            #expect(await store.receiptCalls() == 1)
            #expect(await store.readCalls() == 0)
            #expect(await store.commitCalls() == 0)
        }
    }

    @Test func staleReadRaceReceiptsRejectNonadvancingAndWrongCreationMetadata() async throws {
        let cases: [(Bool, SharedCommandResult)] = [
            (false, result(revision: 0, createdID: nil)),
            (true, result(revision: 1, createdID: nil)),
            (false, result(revision: 1, createdID: UUID())),
        ]
        for (creation, supplied) in cases {
            let store = ReceiptResultStore(stage: .staleReadRace, supplied: supplied, owner: owner)
            try await request(store, envelope: envelope(creation: creation), expected: .invalidResponse)
            #expect(await store.receiptCalls() == 2)
            #expect(await store.readCalls() == 1)
            #expect(await store.commitCalls() == 0)
        }
    }

    @Test func acceptedReceiptsRetainCreationAndNonCreationShapes() async throws {
        for stage in [ReceiptResultStore.Stage.early, .staleReadRace] {
            for creation in [false, true] {
                let supplied = result(revision: 2, createdID: creation ? UUID() : nil)
                let store = ReceiptResultStore(stage: stage, supplied: supplied, owner: owner)
                try await request(store, envelope: envelope(creation: creation))
                #expect(await store.commitCalls() == 0)
            }
        }
    }

    @Test func fallbackReceiptCannotRepairBadCreationMetadata() async throws {
        let supplied = result(revision: 1, createdID: nil)
        let store = ReceiptResultStore(stage: .postCommitFallback,
                                       supplied: supplied, owner: owner)
        try await request(store, envelope: envelope(creation: true), expected: .invalidResponse)
        #expect(await store.receiptCalls() == 2)
        #expect(await store.readCalls() == 1)
        #expect(await store.commitCalls() == 1)
    }
}

private struct ReceiptResultVerifier: AccountVerifier {
    let account: UUID
    func account(for bearer: String) async throws -> UUID {
        guard bearer == "verified-synthetic" else { throw SharedStateFailure.unauthenticated }
        return account
    }
}

private actor ReceiptResultStore: SpaceStore {
    enum Stage { case early, staleReadRace, postCommitFallback }
    let stage: Stage
    let supplied: SharedCommandResult
    let owner: UUID
    private var receipts = 0
    private var reads = 0
    private var commits = 0

    init(stage: Stage, supplied: SharedCommandResult, owner: UUID) {
        self.stage = stage; self.supplied = supplied; self.owner = owner
    }
    func receiptCalls() -> Int { receipts }
    func readCalls() -> Int { reads }
    func commitCalls() -> Int { commits }

    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot {
        reads += 1
        return SharedSnapshot(spaceID: supplied.snapshot.spaceID,
            revision: stage == .staleReadRace ? 1 : 0,
            members: supplied.snapshot.members, state: .init())
    }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date,
                expectedRevision: Int?) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot {
        throw SharedStateFailure.forbidden
    }
    func receipt(actor: UUID, envelope: SharedCommandEnvelope,
                 digest: String) async throws -> SharedCommandResult? {
        receipts += 1
        return stage == .early || receipts > 1 ? supplied : nil
    }
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String,
                result: SharedCommandResult) async throws -> SharedCommandResult {
        commits += 1
        return SharedCommandResult(snapshot: result.snapshot, createdID: UUID())
    }
}
