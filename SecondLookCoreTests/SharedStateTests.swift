import XCTest
@testable import SecondLookCore

final class SharedStateTests: XCTestCase {
    private let performer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let reviewer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let outsider = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let spaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(_ state: SecondLookState = .init(), revision: Int = 0) -> SharedSnapshot {
        SharedSnapshot(spaceID: spaceID, revision: revision, members: [performer, reviewer], state: state)
    }

    private func envelope(_ command: SharedCommand, revision: Int = 0) -> SharedCommandEnvelope {
        SharedCommandEnvelope(spaceID: spaceID, commandID: UUID(), expectedSpaceRevision: revision, command: command)
    }

    private func pendingEvidence() throws -> (SharedSnapshot, UUID, UUID) {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Leave home",
                                          items: [RoutineItem(title: "Lock door", priority: .high)],
                                          performerID: performer, reviewerID: reviewer, now: now)
        let itemID = try XCTUnwrap(state.runs.first?.items.first?.id)
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: performer,
                               fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: runID, itemID: itemID, actorID: performer, now: now)
        try state.acceptSend(runID: runID, itemID: itemID, actorID: performer,
                             expectedVersion: version, now: now)
        return (snapshot(state), runID, itemID)
    }

    func testOutsiderAndPerformerSelfReviewAreRejectedWithoutMutation() throws {
        let (original, runID, itemID) = try pendingEvidence()
        let runRevision = try XCTUnwrap(original.state.runs.first?.revision)
        let approval = envelope(.approve(runID: runID, itemID: itemID,
                                         expectedVersion: 1, expectedRunRevision: runRevision))
        XCTAssertThrowsError(try SharedCommandProcessor.apply(approval, to: original,
                                                               actorID: outsider, now: now)) {
            XCTAssertEqual($0 as? SharedStateFailure, .forbidden)
        }
        XCTAssertThrowsError(try SharedCommandProcessor.apply(approval, to: original,
                                                               actorID: performer, now: now)) {
            #if DEBUG
            XCTAssertEqual($0 as? SharedStateFailure, .domain(.unauthorized))
            #else
            XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
            #endif
        }
        XCTAssertEqual(original.state.runs[0].items[0].submission?.status, .waitingForReview)
        XCTAssertTrue(original.state.archives.isEmpty)
    }

    func testExactVersionsAndClosurePreventStaleActions() throws {
        let (original, runID, itemID) = try pendingEvidence()
        let runRevision = original.state.runs[0].revision
        let badVersion = envelope(.approve(runID: runID, itemID: itemID,
                                           expectedVersion: 0, expectedRunRevision: runRevision))
        #if DEBUG
        XCTAssertThrowsError(try SharedCommandProcessor.apply(badVersion, to: original,
                                                               actorID: reviewer, now: now)) {
            XCTAssertEqual($0 as? SharedStateFailure, .domain(.staleVersion))
        }
        let badRunRevision = envelope(.approve(runID: runID, itemID: itemID,
                                               expectedVersion: 1, expectedRunRevision: runRevision - 1))
        XCTAssertThrowsError(try SharedCommandProcessor.apply(badRunRevision, to: original,
                                                               actorID: reviewer, now: now)) {
            XCTAssertEqual($0 as? SharedStateFailure, .staleState)
        }
        let completed = try SharedCommandProcessor.apply(
            envelope(.approve(runID: runID, itemID: itemID,
                              expectedVersion: 1, expectedRunRevision: runRevision)),
            to: original, actorID: reviewer, now: now)
        XCTAssertEqual(completed.snapshot.state.runs[0].outcome, .completed)
        XCTAssertEqual(completed.snapshot.state.archives.count, 1)
        XCTAssertNil(completed.snapshot.state.runs[0].items[0].submission)
        XCTAssertThrowsError(try SharedCommandProcessor.apply(
            envelope(.withdraw(runID: runID, itemID: itemID,
                               expectedVersion: 1,
                               expectedRunRevision: completed.snapshot.state.runs[0].revision),
                     revision: completed.snapshot.revision),
            to: completed.snapshot, actorID: performer, now: now)) {
            XCTAssertEqual($0 as? SharedStateFailure, .domain(.closed))
        }
        XCTAssertThrowsError(try SharedCommandProcessor.apply(
            envelope(.cancel(runID: runID, expectedRunRevision: runRevision)),
            to: completed.snapshot, actorID: performer, now: now)) {
            XCTAssertEqual($0 as? SharedStateFailure, .staleState)
        }
        #else
        let exactVersion = envelope(.approve(runID: runID, itemID: itemID,
                                              expectedVersion: 1, expectedRunRevision: runRevision))
        for command in [badVersion, exactVersion] {
            XCTAssertThrowsError(try SharedCommandProcessor.apply(command, to: original,
                                                                    actorID: reviewer, now: now)) {
                XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
            }
        }
        XCTAssertEqual(original.state.runs[0].items[0].submission?.status, .waitingForReview)
        #endif
    }

    func testRoutineVersionNormalizationAndRunSnapshotIsolation() throws {
        let routineID = UUID()
        let original = Routine(id: routineID, title: "Before leaving",
                               items: [RoutineItem(title: "Keys")], definitionVersion: 9_999)
        let saved = try SharedCommandProcessor.apply(
            envelope(.saveRoutine(definition: original, expectedDefinitionVersion: nil)),
            to: snapshot(), actorID: performer, now: now).snapshot
        XCTAssertEqual(saved.state.routines[0].definitionVersion, 1)
        XCTAssertThrowsError(try SharedCommandProcessor.apply(
            envelope(.saveRoutine(definition: original, expectedDefinitionVersion: 0),
                     revision: saved.revision), to: saved, actorID: reviewer, now: now)) {
            XCTAssertEqual($0 as? SharedStateFailure, .staleState)
        }
        let start = try SharedCommandProcessor.apply(
            envelope(.startRun(routineID: routineID, expectedDefinitionVersion: 1),
                     revision: saved.revision), to: saved, actorID: performer, now: now)
        let runID = try XCTUnwrap(start.createdID)
        XCTAssertEqual(start.snapshot.state.runs[0].reviewerID, reviewer)
        let edited = Routine(id: routineID, title: "Updated routine",
                             items: [RoutineItem(title: "Wallet")], definitionVersion: 7_777)
        let updated = try SharedCommandProcessor.apply(
            envelope(.saveRoutine(definition: edited, expectedDefinitionVersion: 1),
                     revision: start.snapshot.revision), to: start.snapshot, actorID: reviewer,
            now: now).snapshot
        XCTAssertEqual(updated.state.routines[0].definitionVersion, 2)
        XCTAssertEqual(updated.state.runs.first { $0.id == runID }?.title, "Before leaving")
        XCTAssertEqual(updated.state.runs[0].items[0].title, "Keys")
        XCTAssertThrowsError(try SharedCommandProcessor.apply(
            envelope(.deleteRoutine(routineID: routineID, expectedDefinitionVersion: 1),
                     revision: updated.revision), to: updated, actorID: performer, now: now)) {
            XCTAssertEqual($0 as? SharedStateFailure, .staleState)
        }
    }

    func testSnapshotRejectsThirdMemberUnsentEvidenceAndInvalidRoles() throws {
        let (waiting, _, _) = try pendingEvidence()
        #if DEBUG
        try waiting.validate(for: reviewer)
        #else
        XCTAssertThrowsError(try waiting.validate(for: reviewer)) {
            XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
        }
        #endif
        XCTAssertThrowsError(try waiting.validate(for: outsider))
        var three = waiting
        three.members.append(outsider)
        XCTAssertThrowsError(try three.validate(for: performer))
        var unauthorizedRoles = waiting
        unauthorizedRoles.members = [performer, outsider]
        XCTAssertThrowsError(try unauthorizedRoles.validate(for: performer))
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Photo", items: [RoutineItem(title: "Evidence", priority: .high)],
                                          performerID: performer, reviewerID: reviewer, now: now)
        let itemID = state.runs[0].items[0].id
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: performer,
                               fixtureID: "synthetic", source: .simulatedLibrary, now: now)
        XCTAssertThrowsError(try snapshot(state).validate(for: performer))
        _ = try state.beginSend(runID: runID, itemID: itemID, actorID: performer, now: now)
        XCTAssertThrowsError(try snapshot(state).validate(for: performer))
    }

    func testWireCodecRoundTripsCommandsAndMilliseconds() throws {
        let command = envelope(.requestAnother(runID: UUID(), itemID: UUID(), expectedVersion: 2,
                                               note: "Try again", expectedRunRevision: 5), revision: 7)
        let encoded = try SharedWireCodec.encode(command)
        XCTAssertEqual(try SharedWireCodec.decode(SharedCommandEnvelope.self, from: encoded), command)
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let result = try SharedWireCodec.decode(Date.self, from: SharedWireCodec.encode(date))
        XCTAssertEqual(result.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try SharedWireCodec.encode(command), encoded)
    }

    func testServerSnapshotAndCommandScopeMustMatch() throws {
        let original = snapshot()
        let routine = Routine(title: "Keys", items: [RoutineItem(title: "Count keys")])
        let foreignEnvelope = SharedCommandEnvelope(spaceID: UUID(), commandID: UUID(),
                                                     expectedSpaceRevision: 0,
                                                     command: .saveRoutine(definition: routine,
                                                                           expectedDefinitionVersion: nil))
        XCTAssertThrowsError(try SharedCommandProcessor.apply(foreignEnvelope, to: original,
                                                               actorID: performer, now: now)) {
            XCTAssertEqual($0 as? SharedStateFailure, .scopeMismatch)
        }
        XCTAssertTrue(original.state.routines.isEmpty)
    }
}

private actor SharedTestStore {
    private var current: SharedSnapshot
    private let now: Date

    init(snapshot: SharedSnapshot, now: Date) {
        current = snapshot
        self.now = now
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        guard current.spaceID == spaceID else { throw SharedStateFailure.scopeMismatch }
        return current
    }

    func execute(_ envelope: SharedCommandEnvelope, actorID: UUID) async throws -> SharedCommandResult {
        let result = try SharedCommandProcessor.apply(envelope, to: current, actorID: actorID, now: now)
        current = result.snapshot
        return result
    }
}

private struct InMemorySharedClient: SharedStateClient {
    let store: SharedTestStore
    let actorID: UUID

    init(snapshot: SharedSnapshot, actorID: UUID, now: Date) {
        store = SharedTestStore(snapshot: snapshot, now: now)
        self.actorID = actorID
    }

    init(store: SharedTestStore, actorID: UUID) {
        self.store = store
        self.actorID = actorID
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        try await store.fetch(spaceID: spaceID)
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        try await store.execute(envelope, actorID: actorID)
    }
}

private actor DeferredSharedClient: SharedStateClient {
    private var continuation: CheckedContinuation<SharedSnapshot, Error>?
    private var started: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ result: Result<SharedSnapshot, Error>) {
        let waiting = continuation
        continuation = nil
        waiting?.resume(with: result)
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        throw SharedStateFailure.serviceUnavailable
    }
}

private actor OutOfOrderSharedClient: SharedStateClient {
    private var first: CheckedContinuation<SharedSnapshot, Error>?
    private var started: CheckedContinuation<Void, Never>?
    private var calls = 0
    private let newer: SharedSnapshot

    init(newer: SharedSnapshot) { self.newer = newer }

    func waitForFirst() async {
        if first != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func releaseFirst(with older: SharedSnapshot) {
        let pending = first
        first = nil
        pending?.resume(returning: older)
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        calls += 1
        if calls == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                first = continuation
                started?.resume()
                started = nil
            }
        }
        return newer
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        throw SharedStateFailure.serviceUnavailable
    }
}

private actor DenyingSharedClient: SharedStateClient {
    private let initial: SharedSnapshot
    private var fetched = false

    init(initial: SharedSnapshot) { self.initial = initial }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        if fetched { throw SharedStateFailure.forbidden }
        fetched = true
        return initial
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        throw SharedStateFailure.unauthenticated
    }
}

private struct ConflictingSharedClient: SharedStateClient {
    let initial: SharedSnapshot
    let conflict: SharedSnapshot

    func fetch(spaceID: UUID) async throws -> SharedSnapshot { initial }
    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        SharedCommandResult(snapshot: conflict)
    }
}

private actor ConflictingFetchClient: SharedStateClient {
    private let initial: SharedSnapshot
    private let conflict: SharedSnapshot
    private var fetched = false

    init(initial: SharedSnapshot, conflict: SharedSnapshot) {
        self.initial = initial
        self.conflict = conflict
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        if fetched { return conflict }
        fetched = true
        return initial
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        throw SharedStateFailure.serviceUnavailable
    }
}

private actor LostReplySharedClient: SharedStateClient {
    private var current: SharedSnapshot
    private var receipts: [UUID: (envelope: SharedCommandEnvelope, result: SharedCommandResult)] = [:]
    private var sent: [SharedCommandEnvelope] = []
    private let actorID: UUID
    private let now: Date
    private var dropFirstReply: Bool
    private var rejectFirstAsStale: Bool

    init(snapshot: SharedSnapshot, actorID: UUID, now: Date,
         dropFirstReply: Bool = false, rejectFirstAsStale: Bool = false) {
        current = snapshot
        self.actorID = actorID
        self.now = now
        self.dropFirstReply = dropFirstReply
        self.rejectFirstAsStale = rejectFirstAsStale
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot { current }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        sent.append(envelope)
        if rejectFirstAsStale {
            rejectFirstAsStale = false
            throw SharedStateFailure.staleState
        }
        if let receipt = receipts[envelope.commandID] {
            guard envelope == receipt.envelope else { throw SharedStateFailure.invalidResponse }
            return SharedCommandResult(snapshot: current, createdID: receipt.result.createdID)
        }
        let result = try SharedCommandProcessor.apply(envelope, to: current,
                                                      actorID: actorID, now: now)
        current = result.snapshot
        receipts[envelope.commandID] = (envelope, result)
        if dropFirstReply {
            dropFirstReply = false
            throw SharedStateFailure.serviceUnavailable
        }
        return result
    }

    func sentEnvelopes() -> [SharedCommandEnvelope] { sent }
    func currentSnapshot() -> SharedSnapshot { current }
}

private actor DeferredCommandSharedClient: SharedStateClient {
    let initial: SharedSnapshot
    private var pending: CheckedContinuation<SharedCommandResult, Error>?
    private var started: CheckedContinuation<Void, Never>?
    private var sent: SharedCommandEnvelope?

    init(initial: SharedSnapshot) { self.initial = initial }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot { initial }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            sent = envelope
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func sentEnvelope() -> SharedCommandEnvelope? { sent }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ result: Result<SharedCommandResult, Error>) {
        let waiting = pending
        pending = nil
        waiting?.resume(with: result)
    }
}

private actor LaggingReceiptSharedClient: SharedStateClient {
    private let initial: SharedSnapshot
    private let newer: SharedSnapshot
    private let receipt: SharedCommandResult
    private var fetched = false
    private var pending: CheckedContinuation<SharedCommandResult, Error>?
    private var started: CheckedContinuation<Void, Never>?

    init(initial: SharedSnapshot, newer: SharedSnapshot, receipt: SharedCommandResult) {
        self.initial = initial
        self.newer = newer
        self.receipt = receipt
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        if !fetched {
            fetched = true
            return initial
        }
        return newer
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func releaseReceipt() {
        let waiting = pending
        pending = nil
        waiting?.resume(returning: receipt)
    }
}

private actor ConcurrentUnavailableSharedClient: SharedStateClient {
    private let initial: SharedSnapshot
    private var sent: [SharedCommandEnvelope] = []
    private var pending: [CheckedContinuation<SharedCommandResult, Error>] = []
    private var twoStarted: CheckedContinuation<Void, Never>?

    init(initial: SharedSnapshot) { self.initial = initial }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot { initial }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            sent.append(envelope)
            pending.append(continuation)
            if pending.count == 2 {
                twoStarted?.resume()
                twoStarted = nil
            }
        }
    }

    func waitForBoth() async {
        if pending.count == 2 { return }
        await withCheckedContinuation { twoStarted = $0 }
    }

    func sentEnvelopes() -> [SharedCommandEnvelope] { sent }

    func failBoth() {
        let waiting = pending
        pending = []
        for continuation in waiting {
            continuation.resume(throwing: SharedStateFailure.serviceUnavailable)
        }
    }
}

@MainActor
final class SharedStateCoordinatorTests: XCTestCase {
    private let accountA = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let accountB = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func scope(_ account: UUID) -> SharedAccountScope {
        SharedAccountScope(backend: "in-memory-test", accountID: account, spaceID: space)
    }

    private func baseline() -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: 0, members: [accountA, accountB], state: .init())
    }

    private func oneOffCommand() -> SharedCommand {
        .startOneOff(title: "Invented exit", items: [RoutineItem(title: "Keys")], settings: .init())
    }

    func testSuspendedLostReplyResumesOnlyOriginalEnvelopeInSameScope() async throws {
        let client = LostReplySharedClient(snapshot: baseline(), actorID: accountA, now: now,
                                           dropFirstReply: true)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(accountA), client: client)
        _ = try await coordinator.refresh()
        let command = oneOffCommand()
        let actionID = UUID()
        do { _ = try await coordinator.execute(command, commandID: actionID) }
        catch { XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable) }
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: actionID))

        coordinator.suspendSession()
        XCTAssertNil(coordinator.snapshot)
        XCTAssertNil(coordinator.scope)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: actionID))
        do {
            _ = try await coordinator.refresh()
            XCTFail("A suspended session must have no usable client")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .unauthenticated) }

        coordinator.beginSession(scope: scope(accountA), client: client)
        XCTAssertNil(coordinator.snapshot, "Membership must be fetched again before retry")
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: actionID))
        _ = try await coordinator.refresh()
        let createdID = try await coordinator.execute(command, commandID: actionID)
        let sent = await client.sentEnvelopes()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], sent[1], "Original ID, command body and revision must survive suspension")
        XCTAssertEqual(coordinator.snapshot?.state.runs.first?.id, createdID)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: actionID))
    }

    func testInFlightCompletionAfterSuspensionCannotConsumeResumedRetry() async throws {
        let firstClient = DeferredCommandSharedClient(initial: baseline())
        let resumedClient = LostReplySharedClient(snapshot: baseline(), actorID: accountA, now: now,
                                                  dropFirstReply: true)
        let coordinator = SharedStateCoordinator()
        let command = oneOffCommand()
        let actionID = UUID()
        coordinator.beginSession(scope: scope(accountA), client: firstClient)
        _ = try await coordinator.refresh()
        let oldRequest = Task { try await coordinator.execute(command, commandID: actionID) }
        await firstClient.waitUntilStarted()
        let sentByFirstClient = await firstClient.sentEnvelope()
        let original = try XCTUnwrap(sentByFirstClient)

        coordinator.suspendSession()
        XCTAssertNil(coordinator.snapshot)
        XCTAssertNil(coordinator.scope)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: actionID))
        coordinator.beginSession(scope: scope(accountA), client: resumedClient)
        _ = try await coordinator.refresh()
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: actionID))
        do { _ = try await coordinator.execute(command, commandID: actionID) }
        catch { XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable) }
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: actionID))

        await firstClient.finish(.failure(SharedStateFailure.forbidden))
        do {
            _ = try await oldRequest.value
            XCTFail("An old denial cannot clear the resumed session")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .sessionChanged) }
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: actionID))
        XCTAssertNotNil(coordinator.snapshot)
        let createdID = try await coordinator.execute(command, commandID: actionID)
        let resent = await resumedClient.sentEnvelopes()
        XCTAssertEqual(resent.count, 2)
        XCTAssertEqual(resent[0], original)
        XCTAssertEqual(resent[1], original)
        XCTAssertEqual(coordinator.snapshot?.state.runs.first?.id, createdID)
    }

    func testLateSuccessfulReplyCannotPublishAcrossSuspendedGeneration() async throws {
        let oldClient = DeferredCommandSharedClient(initial: baseline())
        let resumedClient = LostReplySharedClient(snapshot: baseline(), actorID: accountA, now: now)
        let coordinator = SharedStateCoordinator()
        let command = oneOffCommand()
        let actionID = UUID()
        coordinator.beginSession(scope: scope(accountA), client: oldClient)
        _ = try await coordinator.refresh()
        let oldRequest = Task { try await coordinator.execute(command, commandID: actionID) }
        await oldClient.waitUntilStarted()
        let sentByOldClient = await oldClient.sentEnvelope()
        let original = try XCTUnwrap(sentByOldClient)
        let staleResult = try SharedCommandProcessor.apply(original, to: baseline(),
                                                           actorID: accountA, now: now)

        coordinator.suspendSession()
        coordinator.beginSession(scope: scope(accountA), client: resumedClient)
        _ = try await coordinator.refresh()
        await oldClient.finish(.success(staleResult))
        do {
            _ = try await oldRequest.value
            XCTFail("A pre-suspension success cannot publish into the resumed generation")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .sessionChanged) }
        XCTAssertEqual(coordinator.snapshot, baseline())
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: actionID))

        _ = try await coordinator.execute(command, commandID: actionID)
        let resent = await resumedClient.sentEnvelopes()
        XCTAssertEqual(resent, [original])
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: actionID))
    }

    func testSuspendedEnvelopeClearsForDifferentBackendAccountOrSpace() async throws {
        let changes: [SharedAccountScope] = [
            scope(accountB),
            SharedAccountScope(backend: "other-backend", accountID: accountA, spaceID: space),
            SharedAccountScope(backend: "in-memory-test", accountID: accountA, spaceID: UUID()),
        ]
        for changedScope in changes {
            let client = LostReplySharedClient(snapshot: baseline(), actorID: accountA, now: now,
                                               dropFirstReply: true)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope(accountA), client: client)
            _ = try await coordinator.refresh()
            let actionID = UUID()
            do { _ = try await coordinator.execute(oneOffCommand(), commandID: actionID) }
            catch { XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable) }
            coordinator.suspendSession()
            coordinator.beginSession(scope: changedScope, client: client)
            XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: actionID),
                           "A changed backend, account, or space must discard the old envelope")
            coordinator.beginSession(scope: scope(accountA), client: client)
            XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: actionID),
                           "Switching back cannot resurrect another scope's envelope")
        }
    }

    func testEndSessionClearsSuspendedEnvelopeEvenForSameScope() async throws {
        let client = LostReplySharedClient(snapshot: baseline(), actorID: accountA, now: now,
                                           dropFirstReply: true)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(accountA), client: client)
        _ = try await coordinator.refresh()
        let actionID = UUID()
        do { _ = try await coordinator.execute(oneOffCommand(), commandID: actionID) }
        catch { XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable) }
        coordinator.suspendSession()
        coordinator.endSession()
        coordinator.beginSession(scope: scope(accountA), client: client)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: actionID))
    }

    func testLostCreationReplyRetainsEnvelopeAcrossRefreshAndReturnsOriginalCreatedID() async throws {
        let client = LostReplySharedClient(snapshot: baseline(), actorID: accountA, now: now,
                                           dropFirstReply: true)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(accountA), client: client)
        _ = try await coordinator.refresh()
        let command = oneOffCommand()
        let actionID = UUID()
        do {
            _ = try await coordinator.execute(command, commandID: actionID)
            XCTFail("The first reply should be lost after the server commits")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable)
        }
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: actionID))
        let refreshed = try await coordinator.refresh()
        XCTAssertTrue(refreshed)
        let retryCreatedID = try await coordinator.execute(command, commandID: actionID)
        let createdID = try XCTUnwrap(retryCreatedID)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: actionID))
        let sent = await client.sentEnvelopes()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], sent[1], "A retry must keep the original ID, body and revision")
        XCTAssertEqual(coordinator.snapshot?.state.runs.count, 1)
        XCTAssertEqual(coordinator.snapshot?.state.runs.first?.id, createdID)
        let serverSnapshot = await client.currentSnapshot()
        XCTAssertEqual(serverSnapshot.state.runs.count, 1)
    }

    func testDefiniteStaleRejectionPermitsNewEnvelopeAfterRefresh() async throws {
        let client = LostReplySharedClient(snapshot: baseline(), actorID: accountA, now: now,
                                           rejectFirstAsStale: true)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(accountA), client: client)
        _ = try await coordinator.refresh()
        let command = oneOffCommand()
        let rejectedID = UUID()
        do {
            _ = try await coordinator.execute(command, commandID: rejectedID)
            XCTFail("The server should definitively reject the first attempt")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .staleState)
        }
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: rejectedID))
        _ = try await coordinator.refresh()
        _ = try await coordinator.execute(command)
        let sent = await client.sentEnvelopes()
        XCTAssertEqual(sent.count, 2)
        XCTAssertNotEqual(sent[0].commandID, sent[1].commandID)
    }

    func testAccountSwitchDropsOldRetryAndLateResponseCannotClearNewPendingIntent() async throws {
        let oldClient = DeferredCommandSharedClient(initial: baseline())
        let newClient = LostReplySharedClient(snapshot: baseline(), actorID: accountB, now: now,
                                              dropFirstReply: true)
        let coordinator = SharedStateCoordinator()
        let command = oneOffCommand()
        let oldID = UUID()
        let newID = UUID()
        coordinator.beginSession(scope: scope(accountA), client: oldClient)
        _ = try await coordinator.refresh()
        let oldRequest = Task { try await coordinator.execute(command, commandID: oldID) }
        await oldClient.waitUntilStarted()
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: oldID))

        coordinator.beginSession(scope: scope(accountB), client: newClient)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: oldID))
        _ = try await coordinator.refresh()
        do { _ = try await coordinator.execute(command, commandID: newID) }
        catch { XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable) }
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: newID))
        await oldClient.finish(.success(SharedCommandResult(snapshot: baseline())))
        do {
            _ = try await oldRequest.value
            XCTFail("A prior account's response cannot publish")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .sessionChanged)
        }
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: newID))
        _ = try await coordinator.refresh()
        _ = try await coordinator.execute(command, commandID: newID)
        let sent = await newClient.sentEnvelopes()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], sent[1])
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: newID))
    }

    func testConfirmedReceiptAfterNewerFetchReturnsCreatedIDWithoutReplacingSnapshot() async throws {
        let command = oneOffCommand()
        let applied = try SharedCommandProcessor.apply(
            SharedCommandEnvelope(spaceID: space, commandID: UUID(),
                                  expectedSpaceRevision: 0, command: command),
            to: baseline(), actorID: accountA, now: now)
        let createdRun = try XCTUnwrap(applied.snapshot.state.runs.first)
        let newer = try SharedCommandProcessor.apply(
            SharedCommandEnvelope(spaceID: space, commandID: UUID(),
                expectedSpaceRevision: applied.snapshot.revision,
                command: .updateRunSettings(runID: createdRun.id,
                    settings: RunSettings(reminders: ReminderPreferences(remindPerformer: true)),
                    expectedRunRevision: createdRun.revision)),
            to: applied.snapshot, actorID: accountA, now: now).snapshot
        let client = LaggingReceiptSharedClient(initial: baseline(), newer: newer, receipt: applied)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(accountA), client: client)
        _ = try await coordinator.refresh()
        let actionID = UUID()
        let request = Task { try await coordinator.execute(command, commandID: actionID) }
        await client.waitUntilStarted()
        _ = try await coordinator.refresh()
        XCTAssertEqual(coordinator.snapshot, newer)
        await client.releaseReceipt()
        let createdID = try await request.value
        XCTAssertEqual(createdID, applied.createdID)
        XCTAssertEqual(coordinator.snapshot, newer)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: actionID))
    }

    func testExplicitSameIDReusesEnvelopeAndDifferentIDStartsNewIntent() async throws {
        let client = LostReplySharedClient(snapshot: baseline(), actorID: accountA, now: now,
                                           dropFirstReply: true)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(accountA), client: client)
        _ = try await coordinator.refresh()
        let command = oneOffCommand()
        let originalID = UUID()
        do { _ = try await coordinator.execute(command, commandID: originalID) }
        catch { XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable) }
        _ = try await coordinator.refresh()
        let createdID = try await coordinator.execute(command, commandID: originalID)
        XCTAssertNotNil(createdID)
        let newIntentID = UUID()
        let secondCreatedID = try await coordinator.execute(command, commandID: newIntentID)
        XCTAssertNotEqual(secondCreatedID, createdID)
        let sent = await client.sentEnvelopes()
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent[0], sent[1])
        XCTAssertEqual(sent[0].commandID, originalID)
        XCTAssertEqual(sent[2].commandID, newIntentID)
        XCTAssertEqual(sent[2].expectedSpaceRevision, 1)
    }

    func testEqualDefaultActionAfterLostReplyStartsAnotherRun() async throws {
        let client = LostReplySharedClient(snapshot: baseline(), actorID: accountA, now: now,
                                           dropFirstReply: true)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(accountA), client: client)
        _ = try await coordinator.refresh()
        let command = oneOffCommand()
        let lostID = UUID()
        do {
            _ = try await coordinator.execute(command, commandID: lostID)
            XCTFail("The first reply should be lost after the server commits")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable)
        }
        _ = try await coordinator.refresh()
        let secondResult = try await coordinator.execute(command)
        let secondCreatedID = try XCTUnwrap(secondResult)
        let sent = await client.sentEnvelopes()
        XCTAssertEqual(sent.count, 2)
        XCTAssertNotEqual(sent[0].commandID, sent[1].commandID,
                          "A separate action with equal values needs its own receipt")
        XCTAssertEqual(sent[0].commandID, lostID)
        XCTAssertEqual(sent[1].expectedSpaceRevision, 1)
        XCTAssertEqual(coordinator.snapshot?.state.runs.count, 2)
        XCTAssertTrue(coordinator.snapshot?.state.runs.contains(where: { $0.id == secondCreatedID }) == true)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: lostID),
                      "A newer intent must not consume the unresolved older receipt")
        let originalResult = try await coordinator.execute(command, commandID: lostID)
        let originalCreatedID = try XCTUnwrap(originalResult)
        XCTAssertNotEqual(originalCreatedID, secondCreatedID)
        XCTAssertEqual(coordinator.snapshot?.state.runs.count, 2)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: lostID))
        let replaySent = await client.sentEnvelopes()
        XCTAssertEqual(replaySent.count, 3)
        XCTAssertEqual(replaySent[0], replaySent[2],
                       "The original retry must keep its exact request after a newer intent")
    }

    func testChangedBodyWithPendingIDIsRejectedWithoutSendingOrDroppingOriginal() async throws {
        let client = LostReplySharedClient(snapshot: baseline(), actorID: accountA, now: now,
                                           dropFirstReply: true)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(accountA), client: client)
        _ = try await coordinator.refresh()
        let command = oneOffCommand()
        let actionID = UUID()
        do { _ = try await coordinator.execute(command, commandID: actionID) }
        catch { XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable) }
        _ = try await coordinator.refresh()
        let changed = SharedCommand.startOneOff(title: "Different action",
                                                 items: [RoutineItem(title: "Keys")], settings: .init())
        do {
            _ = try await coordinator.execute(changed, commandID: actionID)
            XCTFail("A pending request ID cannot be assigned to a changed body")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        let sent = await client.sentEnvelopes()
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: actionID))
        let result = try await coordinator.execute(command, commandID: actionID)
        XCTAssertNotNil(result)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: actionID))
    }

    func testOverlappingExplicitRetriesShareOneEnvelopeBeforeEitherReply() async throws {
        let client = ConcurrentUnavailableSharedClient(initial: baseline())
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(accountA), client: client)
        _ = try await coordinator.refresh()
        let command = oneOffCommand()
        let actionID = UUID()
        let first = Task { try await coordinator.execute(command, commandID: actionID) }
        let second = Task { try await coordinator.execute(command, commandID: actionID) }
        await client.waitForBoth()
        let sent = await client.sentEnvelopes()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], sent[1])
        await client.failBoth()
        do { _ = try await first.value } catch {
            XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable)
        }
        do { _ = try await second.value } catch {
            XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable)
        }
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: actionID))
    }

    func testOverlappingDefaultActionsWithEqualBodiesKeepDistinctIDs() async throws {
        let client = ConcurrentUnavailableSharedClient(initial: baseline())
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(accountA), client: client)
        _ = try await coordinator.refresh()
        let command = oneOffCommand()
        let first = Task { try await coordinator.execute(command) }
        let second = Task { try await coordinator.execute(command) }
        await client.waitForBoth()
        let sent = await client.sentEnvelopes()
        XCTAssertEqual(sent.count, 2)
        XCTAssertNotEqual(sent[0].commandID, sent[1].commandID)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: sent[0].commandID))
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: sent[1].commandID))
        await client.failBoth()
        for request in [first, second] {
            do {
                _ = try await request.value
                XCTFail("Both replies should be ambiguous")
            } catch {
                XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable)
            }
        }
    }

    func testTwoCoordinatorsConvergeAfterAlternatingWrites() async throws {
        let source = baseline()
        let sharedStore = SharedTestStore(snapshot: source, now: now)
        let backendA = InMemorySharedClient(store: sharedStore, actorID: accountA)
        let backendB = InMemorySharedClient(store: sharedStore, actorID: accountB)
        let a = SharedStateCoordinator()
        a.beginSession(scope: scope(accountA), client: backendA)
        let firstRefresh = try await a.refresh()
        XCTAssertTrue(firstRefresh)
        let routine = Routine(title: "Shared", items: [RoutineItem(title: "Keys")])
        _ = try await a.execute(.saveRoutine(definition: routine, expectedDefinitionVersion: nil))
        let b = SharedStateCoordinator()
        b.beginSession(scope: scope(accountB), client: backendB)
        let secondRefresh = try await b.refresh()
        XCTAssertTrue(secondRefresh)
        XCTAssertEqual(a.snapshot, b.snapshot)
        let started = try await b.execute(.startRun(routineID: routine.id, expectedDefinitionVersion: 1))
        let runID = try XCTUnwrap(started)
        XCTAssertEqual(b.snapshot?.state.runs[0].performerID, accountB)
        XCTAssertEqual(b.snapshot?.state.runs[0].reviewerID, accountA)
        let aConverged = try await a.refresh()
        XCTAssertTrue(aConverged)
        XCTAssertEqual(a.snapshot, b.snapshot)
        let run = try XCTUnwrap(a.snapshot?.state.runs[0])
        do {
            _ = try await a.execute(.setStandardChecked(runID: runID, itemID: run.items[0].id,
                                                         checked: true, expectedRunRevision: run.revision))
            XCTFail("A cannot act as performer on B's run")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .domain(.unauthorized))
        }
        _ = try await b.execute(.setStandardChecked(runID: runID, itemID: run.items[0].id,
                                                    checked: true, expectedRunRevision: run.revision))
        let aClosed = try await a.refresh()
        XCTAssertTrue(aClosed)
        XCTAssertEqual(a.snapshot, b.snapshot)
        XCTAssertEqual(a.snapshot?.state.runs[0].outcome, .completed)
    }

    func testLaggingFetchCannotReopenCompletedRunOrReplaceCurrentSnapshot() async throws {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Exit", items: [RoutineItem(title: "Keys")],
                                          performerID: accountA, reviewerID: accountB, now: now)
        let open = SharedSnapshot(spaceID: space, revision: 1,
                                  members: [accountA, accountB], state: state)
        try state.setStandardChecked(runID: runID, itemID: state.runs[0].items[0].id,
                                     checked: true, actorID: accountA, now: now)
        let closed = SharedSnapshot(spaceID: space, revision: 2,
                                    members: [accountA, accountB], state: state)
        let client = OutOfOrderSharedClient(newer: closed)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(accountA), client: client)
        let oldFetch = Task { try await coordinator.refresh() }
        await client.waitForFirst()
        let published = try await coordinator.refresh()
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot?.state.runs[0].outcome, .completed)
        await client.releaseFirst(with: open)
        let laggingPublished = try await oldFetch.value
        XCTAssertFalse(laggingPublished)
        XCTAssertEqual(coordinator.snapshot, closed)
    }

    func testOldSessionResponseAndDenialCannotPublishIntoNewAccount() async throws {
        let oldClient = DeferredSharedClient()
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(accountA), client: oldClient)
        let oldFetch = Task { try await coordinator.refresh() }
        await oldClient.waitUntilStarted()
        let newClient = InMemorySharedClient(snapshot: baseline(), actorID: accountB, now: now)
        coordinator.beginSession(scope: scope(accountB), client: newClient)
        let newRefresh = try await coordinator.refresh()
        XCTAssertTrue(newRefresh)
        let newSnapshot = coordinator.snapshot
        await oldClient.finish(.success(baseline()))
        do {
            _ = try await oldFetch.value
            XCTFail("An old account response must be rejected")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .sessionChanged)
        }
        XCTAssertEqual(coordinator.snapshot, newSnapshot)

        coordinator.beginSession(scope: scope(accountA), client: oldClient)
        let oldDenial = Task { try await coordinator.refresh() }
        await oldClient.waitUntilStarted()
        coordinator.endSession()
        coordinator.beginSession(scope: scope(accountA), client: InMemorySharedClient(
            snapshot: baseline(), actorID: accountA, now: now))
        let reloginRefresh = try await coordinator.refresh()
        XCTAssertTrue(reloginRefresh)
        await oldClient.finish(.failure(SharedStateFailure.forbidden))
        do {
            _ = try await oldDenial.value
            XCTFail("An old denial must be rejected")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .sessionChanged)
        }
        XCTAssertEqual(coordinator.snapshot, baseline())
    }

    func testCurrentDenialClearsProtectedStateAndEqualRevisionConflictIsRejected() async throws {
        let denial = DenyingSharedClient(initial: baseline())
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(accountA), client: denial)
        _ = try await coordinator.refresh()
        XCTAssertEqual(coordinator.snapshot, baseline())
        do {
            _ = try await coordinator.refresh()
            XCTFail("Revoked membership must not leave a visible snapshot")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .forbidden)
        }
        XCTAssertNil(coordinator.snapshot)

        let executeDenial = DenyingSharedClient(initial: baseline())
        coordinator.beginSession(scope: scope(accountA), client: executeDenial)
        _ = try await coordinator.refresh()
        let deniedCommand = SharedCommand.startOneOff(title: "Keys",
                                                        items: [RoutineItem(title: "Carry keys")],
                                                        settings: .init())
        let deniedID = UUID()
        do {
            _ = try await coordinator.execute(deniedCommand, commandID: deniedID)
            XCTFail("Expired credentials must clear protected state")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .unauthenticated)
        }
        XCTAssertNil(coordinator.snapshot)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: deniedID))

        var changed = SecondLookState()
        try changed.saveRoutine(Routine(title: "Different", items: [RoutineItem(title: "Other")]))
        let sameRevisionConflict = SharedSnapshot(spaceID: space, revision: 0,
                                                  members: [accountA, accountB], state: changed)
        coordinator.beginSession(scope: scope(accountA), client: ConflictingSharedClient(
            initial: baseline(), conflict: sameRevisionConflict))
        _ = try await coordinator.refresh()
        let malformedReplyCommand = SharedCommand.startOneOff(title: "Keys",
                                                                 items: [RoutineItem(title: "Carry keys")],
                                                                 settings: .init())
        let malformedReplyID = UUID()
        do {
            _ = try await coordinator.execute(malformedReplyCommand, commandID: malformedReplyID)
            XCTFail("A command must advance the space revision")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertEqual(coordinator.snapshot, baseline())
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: malformedReplyID))

        coordinator.beginSession(scope: scope(accountA), client: ConflictingFetchClient(
            initial: baseline(), conflict: sameRevisionConflict))
        _ = try await coordinator.refresh()
        do {
            _ = try await coordinator.refresh()
            XCTFail("Conflicting content at the same revision must be rejected")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertEqual(coordinator.snapshot, baseline())
    }
}
