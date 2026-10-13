import XCTest
@testable import SecondLookCore

private actor ConfirmedReceiptClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private let now: Date
    private var commandCount = 0
    private var fetchOverride: SharedSnapshot?
    private var fetchFailure: SharedStateFailure?

    init(snapshot: SharedSnapshot, actorID: UUID, now: Date) {
        current = snapshot
        self.actorID = actorID
        self.now = now
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        if let fetchFailure { throw fetchFailure }
        guard current.spaceID == spaceID else { throw SharedStateFailure.scopeMismatch }
        return fetchOverride ?? current
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        commandCount += 1
        // A second HTTP request would be a duplicate write attempt, not consumption
        // of the genuine receipt already returned by the first request.
        guard commandCount == 1 else { throw SharedStateFailure.staleState }
        let result = try SharedCommandProcessor.apply(envelope, to: current,
                                                       actorID: actorID, now: now)
        current = result.snapshot
        return result
    }

    func sentCommandCount() -> Int { commandCount }
    func overrideFetch(with snapshot: SharedSnapshot?) { fetchOverride = snapshot }
    func failFetch(with failure: SharedStateFailure?) { fetchFailure = failure }
}

private actor ConcurrentConfirmedClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private let now: Date
    private var waiters: [(SharedCommandEnvelope, CheckedContinuation<SharedCommandResult, Error>)] = []

    init(snapshot: SharedSnapshot, actorID: UUID, now: Date) {
        current = snapshot
        self.actorID = actorID
        self.now = now
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        guard current.spaceID == spaceID else { throw SharedStateFailure.scopeMismatch }
        return current
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            waiters.append((envelope, continuation))
            guard waiters.count == 2 else { return }
            let admitted = waiters
            waiters = []
            do {
                guard admitted[0].0 == admitted[1].0 else { throw SharedStateFailure.invalidResponse }
                let result = try SharedCommandProcessor.apply(admitted[0].0, to: current,
                                                               actorID: actorID, now: now)
                current = result.snapshot
                for (_, waiter) in admitted { waiter.resume(returning: result) }
            } catch {
                for (_, waiter) in admitted { waiter.resume(throwing: error) }
            }
        }
    }
}

private actor StaggeredConfirmedClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private let now: Date
    private var waiters: [(SharedCommandEnvelope, CheckedContinuation<SharedCommandResult, Error>)] = []
    private var firstAdmittedContinuation: CheckedContinuation<Void, Never>?
    private var admittedContinuation: CheckedContinuation<Void, Never>?
    private var committedResult: SharedCommandResult?

    init(snapshot: SharedSnapshot, actorID: UUID, now: Date) {
        current = snapshot
        self.actorID = actorID
        self.now = now
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        guard current.spaceID == spaceID else { throw SharedStateFailure.scopeMismatch }
        return current
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            waiters.append((envelope, continuation))
            if waiters.count == 1 {
                firstAdmittedContinuation?.resume()
                firstAdmittedContinuation = nil
            }
            if waiters.count == 2 { admittedContinuation?.resume(); admittedContinuation = nil }
        }
    }

    func waitUntilFirstAdmitted() async {
        if !waiters.isEmpty { return }
        await withCheckedContinuation { firstAdmittedContinuation = $0 }
    }

    func waitUntilBothAdmitted() async {
        if waiters.count == 2 { return }
        await withCheckedContinuation { admittedContinuation = $0 }
    }

    func releaseFirstSuccess() throws {
        guard waiters.count == 2, waiters[0].0 == waiters[1].0 else {
            throw SharedStateFailure.invalidResponse
        }
        let result = try SharedCommandProcessor.apply(waiters[0].0, to: current,
                                                       actorID: actorID, now: now)
        current = result.snapshot
        committedResult = result
        waiters.removeFirst().1.resume(returning: result)
    }

    func releaseFirstForbiddenHoldingSecondSuccess() throws {
        guard waiters.count == 2, waiters[0].0 == waiters[1].0 else {
            throw SharedStateFailure.invalidResponse
        }
        let result = try SharedCommandProcessor.apply(waiters[1].0, to: current,
                                                       actorID: actorID, now: now)
        current = result.snapshot
        committedResult = result
        waiters.removeFirst().1.resume(throwing: SharedStateFailure.forbidden)
    }

    func releaseSecondSuccess() throws {
        guard waiters.count == 1, let committedResult else {
            throw SharedStateFailure.invalidResponse
        }
        waiters.removeFirst().1.resume(returning: committedResult)
    }

    func commitPeerRoutine(reviewerID: UUID) throws {
        let definition = Routine(id: UUID(), title: "Peer's invented routine",
                                 items: [RoutineItem(title: "Bag")])
        let envelope = SharedCommandEnvelope(
            spaceID: current.spaceID, commandID: UUID(), expectedSpaceRevision: current.revision,
            command: .saveRoutine(definition: definition, expectedDefinitionVersion: nil)
        )
        current = try SharedCommandProcessor.apply(envelope, to: current,
                                                   actorID: reviewerID, now: now).snapshot
    }

    func releaseSecondSuccessWithCurrentSnapshot() throws {
        guard waiters.count == 1, let committedResult else {
            throw SharedStateFailure.invalidResponse
        }
        waiters.removeFirst().1.resume(returning: SharedCommandResult(
            snapshot: current, createdID: committedResult.createdID
        ))
    }
}

@MainActor
final class ConfirmedReceiptRecoveryTests: XCTestCase {
    private let actorID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let reviewerID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    private let spaceID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!

    private var scope: SharedAccountScope {
        SharedAccountScope(backend: "receipt-test", accountID: actorID, spaceID: spaceID)
    }

    private var initial: SharedSnapshot {
        SharedSnapshot(spaceID: spaceID, revision: 0,
                       members: [actorID, reviewerID], state: .init())
    }

    private func connected() async throws -> (SharedStateCoordinator, ConfirmedReceiptClient) {
        let client = ConfirmedReceiptClient(snapshot: initial, actorID: actorID,
                                            now: Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        return (coordinator, client)
    }

    func testSameScopeRetryAfterConfirmedReplyUsesOriginalReceiptWithoutSecondWrite() async throws {
        let (coordinator, client) = try await connected()
        let command = SharedCommand.startOneOff(title: "Invented departure",
                                                 items: [RoutineItem(title: "Keys")], settings: .init())
        let actionID = UUID()
        let created = try await coordinator.execute(command, commandID: actionID)
        let originalID = try XCTUnwrap(created)
        let firstCount = await client.sentCommandCount()
        XCTAssertEqual(firstCount, 1)

        // Rebinding a transport inside the same account/space also requires a
        // fresh fetch, but must not discard a receipt awaiting model acceptance.
        coordinator.beginSession(scope: scope, client: client)
        XCTAssertNil(coordinator.snapshot)
        _ = try await coordinator.refresh()
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: actionID, command: command))

        // The server and coordinator have confirmed the creation, but the caller
        // may be suspended before consuming the result for navigation.
        coordinator.suspendSession()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        XCTAssertEqual(coordinator.snapshot?.state.runs.map(\.id), [originalID])
        let recoveredID = try await coordinator.execute(command, commandID: actionID)
        XCTAssertEqual(recoveredID, originalID)
        let finalCount = await client.sentCommandCount()
        XCTAssertEqual(finalCount, 1,
                       "Consuming a confirmed receipt must never reissue the creation command")
    }

    func testConfirmedReceiptRequiresExactCommandAndOneShotAcknowledgement() async throws {
        let (coordinator, client) = try await connected()
        let command = SharedCommand.startOneOff(title: "Invented checklist",
                                                 items: [RoutineItem(title: "Door")], settings: .init())
        let wrong = SharedCommand.startOneOff(title: "Different checklist",
                                               items: [RoutineItem(title: "Door")], settings: .init())
        let actionID = UUID()
        let created = try await coordinator.execute(command, commandID: actionID)
        XCTAssertNotNil(created)
        XCTAssertFalse(coordinator.hasConfirmedReceipt(commandID: actionID, command: wrong))
        XCTAssertNil(coordinator.takeConfirmedReceipt(commandID: actionID, command: wrong))
        do {
            _ = try await coordinator.execute(wrong, commandID: actionID)
            XCTFail("The original command ID cannot acknowledge a different body")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .invalidResponse) }
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: actionID, command: command))
        let accepted = coordinator.takeConfirmedReceipt(commandID: actionID, command: command)
        XCTAssertEqual(accepted?.createdID, created)
        XCTAssertEqual(accepted?.snapshotRevision, coordinator.snapshot?.revision)
        XCTAssertNil(coordinator.takeConfirmedReceipt(commandID: actionID, command: command))
        let count = await client.sentCommandCount()
        XCTAssertEqual(count, 1)
    }

    func testChangedAccountOrBackendPurgesConfirmedReceipt() async throws {
        for changedScope in [
            SharedAccountScope(backend: "receipt-test", accountID: reviewerID, spaceID: spaceID),
            SharedAccountScope(backend: "other-backend", accountID: actorID, spaceID: spaceID),
            SharedAccountScope(backend: "receipt-test", accountID: actorID, spaceID: UUID())
        ] {
            let (coordinator, client) = try await connected()
            let command = SharedCommand.startOneOff(title: "Scoped checklist",
                                                     items: [RoutineItem(title: "Keys")], settings: .init())
            let actionID = UUID()
            _ = try await coordinator.execute(command, commandID: actionID)
            coordinator.suspendSession()
            coordinator.beginSession(scope: changedScope, client: client)
            XCTAssertFalse(coordinator.hasConfirmedReceipt(commandID: actionID, command: command))
            XCTAssertNil(coordinator.takeConfirmedReceipt(commandID: actionID, command: command))
            coordinator.beginSession(scope: scope, client: client)
            _ = try await coordinator.refresh()
            XCTAssertFalse(coordinator.hasConfirmedReceipt(commandID: actionID, command: command),
                           "Returning to the old scope must not resurrect a purged receipt")
        }
    }

    func testDeniedMembershipPurgesConfirmedReceipt() async throws {
        let (coordinator, client) = try await connected()
        let command = SharedCommand.startOneOff(title: "Denied checklist",
                                                 items: [RoutineItem(title: "Keys")], settings: .init())
        let actionID = UUID()
        _ = try await coordinator.execute(command, commandID: actionID)
        await client.failFetch(with: .forbidden)
        do {
            _ = try await coordinator.refresh()
            XCTFail("Revoked access must be rejected")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .forbidden) }
        XCTAssertNil(coordinator.snapshot)
        XCTAssertFalse(coordinator.hasConfirmedReceipt(commandID: actionID, command: command))
        XCTAssertNil(coordinator.takeConfirmedReceipt(commandID: actionID, command: command))
        await client.failFetch(with: nil)
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        XCTAssertFalse(coordinator.hasConfirmedReceipt(commandID: actionID, command: command),
                       "Restoring credentials cannot resurrect a denied receipt")
    }

    func testSuspendedReceiptRequiresFreshSnapshotAtItsCommittedRevision() async throws {
        let (coordinator, client) = try await connected()
        let command = SharedCommand.startOneOff(title: "Revision floor checklist",
                                                 items: [RoutineItem(title: "Keys")], settings: .init())
        let actionID = UUID()
        let created = try await coordinator.execute(command, commandID: actionID)
        coordinator.suspendSession()
        await client.overrideFetch(with: initial)
        coordinator.beginSession(scope: scope, client: client)
        do {
            _ = try await coordinator.refresh()
            XCTFail("A stale membership fetch cannot release a newer confirmed receipt")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .staleState) }
        XCTAssertNil(coordinator.snapshot)
        XCTAssertFalse(coordinator.hasConfirmedReceipt(commandID: actionID, command: command))
        XCTAssertNil(coordinator.takeConfirmedReceipt(commandID: actionID, command: command))
        await client.overrideFetch(with: nil)
        _ = try await coordinator.refresh()
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: actionID, command: command))
        XCTAssertEqual(coordinator.takeConfirmedReceipt(commandID: actionID,
                                                        command: command)?.createdID, created)
    }

    func testNilCreatedIDStillAcknowledgesConfirmedMutationWithoutSecondWrite() async throws {
        let (coordinator, client) = try await connected()
        let definition = Routine(id: UUID(), title: "Invented routine",
                                 items: [RoutineItem(title: "Keys")])
        let command = SharedCommand.saveRoutine(definition: definition, expectedDefinitionVersion: nil)
        let actionID = UUID()
        let firstCreated = try await coordinator.execute(command, commandID: actionID)
        XCTAssertNil(firstCreated)
        coordinator.suspendSession()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: actionID, command: command))
        let recoveredCreated = try await coordinator.execute(command, commandID: actionID)
        XCTAssertNil(recoveredCreated)
        let receipt = coordinator.takeConfirmedReceipt(commandID: actionID, command: command)
        XCTAssertNotNil(receipt, "A nil created ID is still a confirmed server mutation")
        XCTAssertNil(receipt?.createdID)
        let count = await client.sentCommandCount()
        XCTAssertEqual(count, 1)
    }

    func testOverlappingIdenticalSuccessesLeaveOnlyOneConsumableReceipt() async throws {
        let client = ConcurrentConfirmedClient(snapshot: initial, actorID: actorID,
                                               now: Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        let command = SharedCommand.startOneOff(title: "Overlapping synthetic checklist",
                                                 items: [RoutineItem(title: "Keys")], settings: .init())
        let actionID = UUID()
        let first = Task { try await coordinator.execute(command, commandID: actionID) }
        let second = Task { try await coordinator.execute(command, commandID: actionID) }
        let firstID = try await first.value
        let secondID = try await second.value
        XCTAssertNotNil(firstID)
        XCTAssertEqual(firstID, secondID)
        XCTAssertEqual(coordinator.snapshot?.state.runs.count, 1)
        XCTAssertEqual(coordinator.takeConfirmedReceipt(commandID: actionID,
                                                        command: command)?.createdID, firstID)
        XCTAssertNil(coordinator.takeConfirmedReceipt(commandID: actionID, command: command),
                     "Two matching replies must still have one model acknowledgement")
    }

    func testLateIdenticalSuccessCannotResurrectAlreadyConsumedReceipt() async throws {
        let client = StaggeredConfirmedClient(snapshot: initial, actorID: actorID,
                                              now: Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        let command = SharedCommand.startOneOff(title: "Late synthetic checklist",
                                                 items: [RoutineItem(title: "Keys")], settings: .init())
        let actionID = UUID()
        let first = Task { try await coordinator.execute(command, commandID: actionID) }
        await client.waitUntilFirstAdmitted()
        let second = Task { try await coordinator.execute(command, commandID: actionID) }
        await client.waitUntilBothAdmitted()
        try await client.releaseFirstSuccess()
        let firstID = try await first.value
        XCTAssertEqual(coordinator.takeConfirmedReceipt(commandID: actionID,
                                                        command: command)?.createdID, firstID)
        try await client.releaseSecondSuccess()
        let secondID = try await second.value
        XCTAssertEqual(secondID, firstID)
        XCTAssertNil(coordinator.takeConfirmedReceipt(commandID: actionID, command: command),
                     "A response from the same already-admitted request cannot restore its used receipt")
    }

    func testLaterPeerRevisionInMatchingReplayKeepsOriginalCreationReceipt() async throws {
        let client = StaggeredConfirmedClient(snapshot: initial, actorID: actorID,
                                              now: Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        let command = SharedCommand.startOneOff(title: "Invented checklist",
                                                 items: [RoutineItem(title: "Keys")], settings: .init())
        let actionID = UUID()
        let first = Task { try await coordinator.execute(command, commandID: actionID) }
        await client.waitUntilFirstAdmitted()
        let replay = Task { try await coordinator.execute(command, commandID: actionID) }
        await client.waitUntilBothAdmitted()
        try await client.releaseFirstSuccess()
        let firstResult = try await first.value
        let createdID = try XCTUnwrap(firstResult)
        XCTAssertEqual(coordinator.snapshot?.revision, 1)

        try await client.commitPeerRoutine(reviewerID: reviewerID)
        try await client.releaseSecondSuccessWithCurrentSnapshot()
        let replayedID = try await replay.value
        XCTAssertEqual(replayedID, createdID)
        XCTAssertEqual(coordinator.snapshot?.revision, 2)
        XCTAssertEqual(coordinator.snapshot?.state.runs.map(\.id), [createdID])
        XCTAssertEqual(coordinator.snapshot?.state.routines.count, 1)
        let receipt = coordinator.takeConfirmedReceipt(commandID: actionID, command: command)
        XCTAssertEqual(receipt?.createdID, createdID)
        XCTAssertEqual(receipt?.snapshotRevision, 1,
                       "The original commit revision remains the receipt's minimum safe view")
        XCTAssertNil(coordinator.takeConfirmedReceipt(commandID: actionID, command: command))
    }

    func testLaterPeerRevisionCannotRestoreConsumedCreationReceipt() async throws {
        let client = StaggeredConfirmedClient(snapshot: initial, actorID: actorID,
                                              now: Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        let command = SharedCommand.startOneOff(title: "Invented checklist",
                                                 items: [RoutineItem(title: "Keys")], settings: .init())
        let actionID = UUID()
        let first = Task { try await coordinator.execute(command, commandID: actionID) }
        await client.waitUntilFirstAdmitted()
        let replay = Task { try await coordinator.execute(command, commandID: actionID) }
        await client.waitUntilBothAdmitted()
        try await client.releaseFirstSuccess()
        let firstResult = try await first.value
        let createdID = try XCTUnwrap(firstResult)
        XCTAssertEqual(coordinator.takeConfirmedReceipt(commandID: actionID,
                                                        command: command)?.createdID, createdID)

        try await client.commitPeerRoutine(reviewerID: reviewerID)
        try await client.releaseSecondSuccessWithCurrentSnapshot()
        let replayedID = try await replay.value
        XCTAssertEqual(replayedID, createdID)
        XCTAssertEqual(coordinator.snapshot?.revision, 2)
        XCTAssertNil(coordinator.takeConfirmedReceipt(commandID: actionID, command: command),
                     "A later view of the same committed command cannot restore its used receipt")
    }

    func testConsumedReceiptStillKeepsRevisionFloorAcrossSuspension() async throws {
        let (coordinator, client) = try await connected()
        let command = SharedCommand.startOneOff(title: "Committed synthetic checklist",
                                                 items: [RoutineItem(title: "Keys")], settings: .init())
        let actionID = UUID()
        let created = try await coordinator.execute(command, commandID: actionID)
        let originalID = try XCTUnwrap(created)
        XCTAssertNotNil(coordinator.takeConfirmedReceipt(commandID: actionID, command: command))
        coordinator.suspendSession()
        await client.overrideFetch(with: initial)
        coordinator.beginSession(scope: scope, client: client)
        do {
            _ = try await coordinator.refresh()
            XCTFail("An older fetch must not erase an already-consumed committed run")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .staleState) }
        XCTAssertNil(coordinator.snapshot)
        await client.overrideFetch(with: nil)
        _ = try await coordinator.refresh()
        XCTAssertEqual(coordinator.snapshot?.state.runs.map(\.id), [originalID])
    }

    func testDeniedResponseInvalidatesAlreadyAdmittedSuccessfulResponse() async throws {
        let client = StaggeredConfirmedClient(snapshot: initial, actorID: actorID,
                                              now: Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        let command = SharedCommand.startOneOff(title: "Revoked synthetic checklist",
                                                 items: [RoutineItem(title: "Keys")], settings: .init())
        let actionID = UUID()
        let denied = Task { try await coordinator.execute(command, commandID: actionID) }
        await client.waitUntilFirstAdmitted()
        let delayedSuccess = Task { try await coordinator.execute(command, commandID: actionID) }
        await client.waitUntilBothAdmitted()
        try await client.releaseFirstForbiddenHoldingSecondSuccess()
        do {
            _ = try await denied.value
            XCTFail("The first response must deny access")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .forbidden) }
        XCTAssertNil(coordinator.snapshot)
        try await client.releaseSecondSuccess()
        do {
            _ = try await delayedSuccess.value
            XCTFail("An older admitted success cannot republish after access loss")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .sessionChanged) }
        XCTAssertNil(coordinator.snapshot)
        XCTAssertFalse(coordinator.hasConfirmedReceipt(commandID: actionID, command: command))
    }
}
