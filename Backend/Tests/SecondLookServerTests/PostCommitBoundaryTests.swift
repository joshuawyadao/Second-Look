import Foundation
import Testing
import VaporTesting
import SecondLookCore
@testable import SecondLookServer

@Suite struct PostCommitBoundaryTests {
    private let owner = UUID(uuidString: "E0000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "E0000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "E0000000-0000-0000-0000-000000000003")!

    private func configuration() throws -> ServerConfiguration {
        try ServerConfiguration(environment: [
            "SECONDLOOK_PROVIDER_URL": "http://127.0.0.1:56321",
            "SECONDLOOK_PUBLISHABLE_KEY": "synthetic-public-configuration",
            "SECONDLOOK_SERVICE_KEY": "synthetic-server-only-secret",
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
            "SECONDLOOK_LOCAL_DEVELOPMENT": "1",
        ])
    }

    private func setup(_ mode: PostCommitStore.Mode,
                       command: SharedCommand? = nil) -> (PostCommitStore, SharedCommandEnvelope) {
        let initial = SharedSnapshot(spaceID: space, revision: 0,
                                     members: [owner, peer], state: .init())
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 0, command: command ?? .startOneOff(title: "Invented run",
                items: [RoutineItem(title: "Invented step")], settings: .init()))
        return (PostCommitStore(initial: initial, owner: owner, mode: mode), envelope)
    }

    private func execute(_ mode: PostCommitStore.Mode,
                         command: SharedCommand? = nil) async throws ->
                         (Result<SharedCommandResult, SharedStateFailure>, PostCommitStore) {
        let (store, envelope) = setup(mode, command: command)
        let service = PrivateSpaceService(verifier: PostCommitVerifier(account: owner),
                                          store: store, configuration: try configuration())
        do { return (.success(try await service.execute(envelope, actor: owner)), store) }
        catch { return (.failure(error as? SharedStateFailure ?? .serviceUnavailable), store) }
    }

    @Test func malformedCommitRepliesNeedAuthoritativeProof() async throws {
        for mode in [PostCommitStore.Mode.noop, .alteredAtNextRevision, .wrongCreatedID,
                     .unexplainedNewer] {
            let (outcome, store) = try await execute(mode)
            #expect(throws: SharedStateFailure.invalidResponse) { try outcome.get() }
            #expect(await store.receiptReads() == 2)
            #expect(await store.commitCount() == 1)
        }
    }

    @Test func invalidReceiptCannotProveAMismatchedCommit() async throws {
        for mode in [PostCommitStore.Mode.invalidReceiptScope, .invalidReceiptRevision] {
            let (outcome, store) = try await execute(mode)
            #expect(throws: SharedStateFailure.invalidResponse) { try outcome.get() }
            #expect(await store.receiptReads() == 2)
        }
    }

    @Test func nonCreationCommitCannotAcknowledgeAnUnchangedRunAtNextSpaceRevision() async throws {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Started",
            items: [RoutineItem(title: "Step"), RoutineItem(title: "Other")],
            performerID: owner, reviewerID: peer, now: Date(timeIntervalSince1970: 1_600_000_000))
        let initial = SharedSnapshot(spaceID: space, revision: 0,
                                     members: [owner, peer], state: state)
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 0, command: .setStandardChecked(runID: runID,
                itemID: state.runs[0].items[0].id, checked: true,
                expectedRunRevision: state.runs[0].revision))
        let store = PostCommitStore(initial: initial, owner: owner, mode: .unchangedAtNextRevision)
        let service = PrivateSpaceService(verifier: PostCommitVerifier(account: owner),
                                          store: store, configuration: try configuration())
        do {
            _ = try await service.execute(envelope, actor: owner)
            Issue.record("An unchanged checked state was acknowledged at the next space revision")
        } catch {
            #expect(error as? SharedStateFailure == .invalidResponse)
        }
        #expect(await store.receiptReads() == 2)
        #expect(await store.commitCount() == 1)
    }

    @Test func exactCommitUsesFastPathWithoutSecondReceiptLookup() async throws {
        let (outcome, store) = try await execute(.exact)
        let result = try outcome.get()
        #expect(result.snapshot.revision == 1)
        #expect(result.createdID != nil)
        #expect(await store.receiptReads() == 1)
        #expect(await store.commitCount() == 1)
        let roundTrip = try SharedWireCodec.decode(SharedCommandResult.self,
                                                   from: SharedWireCodec.encode(result))
        #expect(try SharedWireCodec.encode(roundTrip) == SharedWireCodec.encode(result))
        #expect(roundTrip.createdID == result.createdID)
    }

    @Test func duplicateWinnerAtNextRevisionReturnsStoredIdentity() async throws {
        let (outcome, store) = try await execute(.winnerAtNextRevision)
        let result = try outcome.get()
        let winner = try #require(await store.provenReceipt())
        #expect(result == winner)
        #expect(result.createdID == winner.createdID)
        #expect(await store.receiptReads() == 2)
        #expect(await store.commitCount() == 1)
    }

    @Test func newerCurrentViewReturnsStoredOriginalCreationReceipt() async throws {
        let (outcome, store) = try await execute(.newerWithReceipt)
        let result = try outcome.get()
        let winner = try #require(await store.provenReceipt())
        #expect(result == winner)
        #expect(result.snapshot.revision == 2)
        #expect(result.createdID != nil)
        #expect(await store.receiptReads() == 2)
    }

    @Test func duplicateNonCreationWithDifferentComputedTimeUsesReceipt() async throws {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Started",
            items: [RoutineItem(title: "Step"), RoutineItem(title: "Other")],
            performerID: owner, reviewerID: peer, now: Date(timeIntervalSince1970: 1_600_000_000))
        let initial = SharedSnapshot(spaceID: space, revision: 0,
                                     members: [owner, peer], state: state)
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 0, command: .setStandardChecked(runID: runID,
                itemID: state.runs[0].items[0].id, checked: true,
                expectedRunRevision: state.runs[0].revision))
        let store = PostCommitStore(initial: initial, owner: owner, mode: .winnerAtNextRevision)
        let service = PrivateSpaceService(verifier: PostCommitVerifier(account: owner),
                                          store: store, configuration: try configuration())
        let result = try await service.execute(envelope, actor: owner)
        #expect(result == (await store.provenReceipt()))
        #expect(result.createdID == nil)
        #expect(result.snapshot.state.runs[0].items[0].checkedAt != nil)
        #expect(await store.receiptReads() == 2)
    }

    @Test func absentProofMapsToBoundedNoStoreHTTPResponse() async throws {
        let (store, envelope) = setup(.wrongCreatedID)
        try await withApp { app in
            try configure(app, configuration: try configuration(),
                          verifier: PostCommitVerifier(account: owner), store: store)
            try await app.testing().test(.POST, "/v1/spaces/\(space)/commands", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "verified-synthetic")
                request.body = ByteBuffer(data: try SharedWireCodec.encode(envelope))
            }, afterResponse: { response in
                #expect(response.status == .serviceUnavailable)
                #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
                #expect(response.headers[.cacheControl] == ["no-store"])
            })
        }
        #expect(await store.commitCount() == 1)
    }

    #if DEBUG
    @Test func syntheticEvidenceAlsoRequiresExactCommitOrBoundReceipt() async throws {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Invented review",
            items: [RoutineItem(title: "Door", priority: .high)],
            performerID: owner, reviewerID: peer,
            now: Date(timeIntervalSince1970: 1_700_000_000))
        let initial = SharedSnapshot(spaceID: space, revision: 0,
                                     members: [owner, peer], state: state)
        let run = try #require(initial.state.runs.first { $0.id == runID })
        let item = try #require(run.items.first)
        let body = "{\"spaceID\":\"\(space)\",\"runID\":\"\(runID)\",\"itemID\":\"\(item.id)\",\"expectedSpaceRevision\":0,\"expectedRunRevision\":\(run.revision)}"
        var environment = [
            "SECONDLOOK_PROVIDER_URL": "http://127.0.0.1:56321",
            "SECONDLOOK_PUBLISHABLE_KEY": "synthetic-public-configuration",
            "SECONDLOOK_SERVICE_KEY": "synthetic-server-only-secret",
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
            "SECONDLOOK_LOCAL_DEVELOPMENT": "1",
        ]
        environment["SECONDLOOK_TEST_EVIDENCE"] = "1"
        for (mode, succeeds) in [(PostCommitStore.Mode.unchangedAtNextRevision, false), (.exact, true)] {
            let store = PostCommitStore(initial: initial, owner: owner, mode: mode)
            try await withApp { app in
                try configure(app, configuration: try ServerConfiguration(environment: environment),
                              verifier: PostCommitVerifier(account: owner), store: store)
                try await app.testing().test(.POST, "/_testing/synthetic-evidence",
                    beforeRequest: { request in
                        request.headers.bearerAuthorization = .init(token: "verified-synthetic")
                        request.body = ByteBuffer(string: body)
                    }, afterResponse: { response in
                        if succeeds {
                            #expect(response.status == .ok)
                            let snapshot = try SharedWireCodec.decode(SharedSnapshot.self,
                                from: Data(response.body.readableBytesView))
                            #expect(snapshot.state.runs[0].items[0].submission?.status == .waitingForReview)
                        } else {
                            #expect(response.status == .serviceUnavailable)
                            #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
                            #expect(response.headers[.cacheControl] == ["no-store"])
                        }
                    })
            }
            #expect(await store.commitCount() == 1)
            #expect(await store.receiptReads() == (succeeds ? 0 : 1))
        }
    }
    #endif
}

private struct PostCommitVerifier: AccountVerifier {
    let account: UUID
    func account(for bearer: String) async throws -> UUID {
        guard bearer == "verified-synthetic" else { throw SharedStateFailure.unauthenticated }
        return account
    }
}

private actor PostCommitStore: SpaceStore {
    enum Mode { case exact, noop, unchangedAtNextRevision, alteredAtNextRevision, wrongCreatedID,
                     unexplainedNewer, winnerAtNextRevision, newerWithReceipt,
                     invalidReceiptScope, invalidReceiptRevision }
    let initial: SharedSnapshot
    let owner: UUID
    let mode: Mode
    private var lookups = 0
    private var commits = 0
    private var proof: SharedCommandResult?

    init(initial: SharedSnapshot, owner: UUID, mode: Mode) {
        self.initial = initial; self.owner = owner; self.mode = mode
    }
    func receiptReads() -> Int { lookups }
    func commitCount() -> Int { commits }
    func provenReceipt() -> SharedCommandResult? { proof }

    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot { initial }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date,
                expectedRevision: Int?) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot {
        throw SharedStateFailure.forbidden
    }
    func receipt(actor: UUID, envelope: SharedCommandEnvelope,
                 digest: String) async throws -> SharedCommandResult? {
        lookups += 1
        return lookups == 1 ? nil : proof
    }
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String,
                result: SharedCommandResult) async throws -> SharedCommandResult {
        commits += 1
        let alternate = try SharedCommandProcessor.apply(envelope, to: initial,
            actorID: owner, now: Date(timeIntervalSince1970: 1_600_000_000))
        switch mode {
        case .exact: return result
        case .noop: return SharedCommandResult(snapshot: initial)
        case .unchangedAtNextRevision:
            return SharedCommandResult(snapshot: SharedSnapshot(spaceID: initial.spaceID,
                revision: initial.revision + 1, members: initial.members, state: initial.state))
        case .alteredAtNextRevision:
            let other = SharedCommandEnvelope(spaceID: initial.spaceID, commandID: UUID(),
                expectedSpaceRevision: 0, command: .saveRoutine(definition: Routine(title: "Other",
                    items: [RoutineItem(title: "Other step")]), expectedDefinitionVersion: nil))
            return try SharedCommandProcessor.apply(other, to: initial, actorID: owner,
                                                    now: Date(timeIntervalSince1970: 1_600_000_001))
        case .wrongCreatedID: return SharedCommandResult(snapshot: result.snapshot, createdID: UUID())
        case .unexplainedNewer:
            return try newer(after: result, actor: actor)
        case .winnerAtNextRevision:
            proof = alternate
            return alternate
        case .newerWithReceipt:
            let newer = try newer(after: alternate, actor: actor)
            proof = SharedCommandResult(snapshot: newer.snapshot, createdID: alternate.createdID)
            return newer
        case .invalidReceiptScope:
            proof = SharedCommandResult(snapshot: SharedSnapshot(spaceID: UUID(),
                revision: result.snapshot.revision, members: result.snapshot.members,
                state: result.snapshot.state), createdID: result.createdID)
            return SharedCommandResult(snapshot: result.snapshot, createdID: UUID())
        case .invalidReceiptRevision:
            proof = SharedCommandResult(snapshot: initial, createdID: result.createdID)
            return SharedCommandResult(snapshot: result.snapshot, createdID: UUID())
        }
    }

    private func newer(after result: SharedCommandResult,
                       actor: UUID) throws -> SharedCommandResult {
        let next = SharedCommandEnvelope(spaceID: initial.spaceID, commandID: UUID(),
            expectedSpaceRevision: result.snapshot.revision,
            command: .saveRoutine(definition: Routine(title: "Later",
                items: [RoutineItem(title: "Step")]), expectedDefinitionVersion: nil))
        return try SharedCommandProcessor.apply(next, to: result.snapshot, actorID: actor,
                                                now: Date(timeIntervalSince1970: 1_600_000_002))
    }
}
