import XCTest
@testable import SecondLookCore

private enum CreatedIDResponseChange: Sendable {
    case missing
    case unrelated
    case existing(UUID)
    case unexpected
}

private actor CreatedIDResponseClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private let change: CreatedIDResponseChange
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let unrelatedID = UUID(uuidString: "20000000-0000-0000-0000-000000000099")!

    init(snapshot: SharedSnapshot, actorID: UUID, change: CreatedIDResponseChange) {
        current = snapshot
        self.actorID = actorID
        self.change = change
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        guard spaceID == current.spaceID else { throw SharedStateFailure.scopeMismatch }
        return current
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        let genuine = try SharedCommandProcessor.apply(envelope, to: current,
                                                       actorID: actorID, now: now)
        current = genuine.snapshot
        switch change {
        case .missing:
            return SharedCommandResult(snapshot: current, createdID: nil)
        case let .existing(id):
            return SharedCommandResult(snapshot: current, createdID: id)
        case .unrelated, .unexpected:
            return SharedCommandResult(snapshot: current, createdID: unrelatedID)
        }
    }
}

private actor DeletedCreatedRoutineReplayClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    init(snapshot: SharedSnapshot, actorID: UUID) {
        current = snapshot
        self.actorID = actorID
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        guard spaceID == current.spaceID else { throw SharedStateFailure.scopeMismatch }
        return current
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        let creation = try SharedCommandProcessor.apply(envelope, to: current,
                                                        actorID: actorID, now: now)
        guard let routineID = creation.createdID else { throw SharedStateFailure.invalidResponse }
        let delete = SharedCommandEnvelope(
            spaceID: current.spaceID, commandID: UUID(),
            expectedSpaceRevision: creation.snapshot.revision,
            command: .deleteRoutine(routineID: routineID, expectedDefinitionVersion: 1)
        )
        current = try SharedCommandProcessor.apply(delete, to: creation.snapshot,
                                                   actorID: actorID, now: now).snapshot
        return SharedCommandResult(snapshot: current, createdID: routineID)
    }
}

private actor LostCreationReplyClient: SharedStateClient {
    private var current: SharedSnapshot
    private var originalEnvelope: SharedCommandEnvelope?
    private var committed: SharedCommandResult?
    private let actorID: UUID
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    init(snapshot: SharedSnapshot, actorID: UUID) {
        current = snapshot
        self.actorID = actorID
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        guard spaceID == current.spaceID else { throw SharedStateFailure.scopeMismatch }
        return current
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        if let committed {
            guard originalEnvelope == envelope else { throw SharedStateFailure.invalidResponse }
            return committed
        }
        let result = try SharedCommandProcessor.apply(envelope, to: current,
                                                      actorID: actorID, now: now)
        current = result.snapshot
        originalEnvelope = envelope
        committed = result
        throw SharedStateFailure.serviceUnavailable
    }
}

@MainActor
final class SharedCreatedIDValidationTests: XCTestCase {
    private let actorID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let reviewerID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private let spaceID = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var scope: SharedAccountScope {
        SharedAccountScope(backend: "created-id-test", accountID: actorID, spaceID: spaceID)
    }

    private func snapshot(state: SecondLookState = .init()) -> SharedSnapshot {
        SharedSnapshot(spaceID: spaceID, revision: 0,
                       members: [actorID, reviewerID], state: state)
    }

    private func creationCases() throws -> [(String, SharedSnapshot, SharedCommand)] {
        let items = [RoutineItem(title: "Keys")]
        let routine = Routine(title: "Invented routine", items: items)
        var withRoutine = SecondLookState()
        try withRoutine.saveRoutine(routine)

        var withRun = SecondLookState()
        let oldRunID = try withRun.startOneOff(title: "Old checklist", items: items,
                                               performerID: actorID, reviewerID: reviewerID, now: now)
        let openRunRevision = try XCTUnwrap(withRun.runs.first { $0.id == oldRunID }?.revision)
        let openRun = snapshot(state: withRun)
        try withRun.cancel(runID: oldRunID, actorID: actorID, now: now)
        let closedRunRevision = try XCTUnwrap(withRun.runs.first { $0.id == oldRunID }?.revision)

        return [
            ("startRun", snapshot(state: withRoutine),
             .startRun(routineID: routine.id, expectedDefinitionVersion: 1)),
            ("startOneOff", snapshot(),
             .startOneOff(title: "Invented checklist", items: items, settings: .init())),
            ("repeatRun", snapshot(state: withRun),
             .repeatRun(runID: oldRunID, expectedRunRevision: closedRunRevision)),
            ("saveRunAsRoutine", openRun,
             .saveRunAsRoutine(runID: oldRunID, expectedRunRevision: openRunRevision, title: nil))
        ]
    }

    func testCreationRepliesRequireAnIDThatMatchesReturnedRunOrRoutine() async throws {
        for (name, initial, command) in try creationCases() {
            for change in [CreatedIDResponseChange.missing, .unrelated] {
                let client = CreatedIDResponseClient(snapshot: initial, actorID: actorID, change: change)
                let coordinator = SharedStateCoordinator()
                coordinator.beginSession(scope: scope, client: client)
                _ = try await coordinator.refresh()
                let actionID = UUID()
                do {
                    _ = try await coordinator.execute(command, commandID: actionID)
                    XCTFail("\(name) accepted a \(change) created ID")
                } catch {
                    XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, name)
                }
                XCTAssertEqual(coordinator.snapshot, initial, name)
                XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: actionID), name)
                XCTAssertFalse(coordinator.hasConfirmedReceipt(commandID: actionID, command: command), name)
            }
        }
    }

    func testNonCreationReplyRejectsUnexpectedCreatedID() async throws {
        let initial = snapshot()
        let definition = Routine(title: "Invented routine", items: [RoutineItem(title: "Keys")])
        let command = SharedCommand.saveRoutine(definition: definition, expectedDefinitionVersion: nil)
        let client = CreatedIDResponseClient(snapshot: initial, actorID: actorID, change: .unexpected)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        let actionID = UUID()
        do {
            _ = try await coordinator.execute(command, commandID: actionID)
            XCTFail("A non-creation command accepted an invented created ID")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .invalidResponse) }
        XCTAssertEqual(coordinator.snapshot, initial)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: actionID))
    }

    func testRunCreationCannotClaimAnExistingPeersRun() async throws {
        var state = SecondLookState()
        let peerRunID = try state.startOneOff(title: "Peer checklist",
                                              items: [RoutineItem(title: "Bag")],
                                              performerID: reviewerID, reviewerID: actorID, now: now)
        let initial = snapshot(state: state)
        let command = SharedCommand.startOneOff(title: "My checklist",
                                                 items: [RoutineItem(title: "Keys")], settings: .init())
        let client = CreatedIDResponseClient(snapshot: initial, actorID: actorID,
                                             change: .existing(peerRunID))
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        let actionID = UUID()
        do {
            _ = try await coordinator.execute(command, commandID: actionID)
            XCTFail("The returned ID belonged to the other performer")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .invalidResponse) }
        XCTAssertEqual(coordinator.snapshot, initial)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: actionID))
    }

    func testStartRunCannotClaimExistingOneOffRunFromSamePerformer() async throws {
        var state = SecondLookState()
        let oldRunID = try state.startOneOff(title: "Old checklist",
                                             items: [RoutineItem(title: "Bag")],
                                             performerID: actorID, reviewerID: reviewerID, now: now)
        let routine = Routine(title: "New routine", items: [RoutineItem(title: "Keys")])
        try state.saveRoutine(routine)
        let initial = snapshot(state: state)
        let command = SharedCommand.startRun(routineID: routine.id, expectedDefinitionVersion: 1)
        let client = CreatedIDResponseClient(snapshot: initial, actorID: actorID,
                                             change: .existing(oldRunID))
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        let actionID = UUID()
        do {
            _ = try await coordinator.execute(command, commandID: actionID)
            XCTFail("The returned ID belonged to an unrelated one-off run")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .invalidResponse) }
        XCTAssertEqual(coordinator.snapshot, initial)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: actionID))
    }

    func testCreationCannotClaimPreexistingSameAccountObject() async throws {
        let items = [RoutineItem(title: "Keys")]
        let routine = Routine(title: "Morning", items: items)
        var state = SecondLookState()
        try state.saveRoutine(routine)
        let priorRoutineRunID = try state.startRun(routineID: routine.id,
                                                   performerID: actorID, reviewerID: reviewerID, now: now)
        let otherRoutineRunID = try state.startRun(routineID: routine.id,
                                                   performerID: actorID, reviewerID: reviewerID, now: now)
        let priorOneOffID = try state.startOneOff(title: "Old one-off", items: items,
                                                 performerID: actorID, reviewerID: reviewerID, now: now)
        let priorOneOffRevision = try XCTUnwrap(state.runs.first { $0.id == priorOneOffID }?.revision)
        try state.cancel(runID: priorRoutineRunID, actorID: actorID, now: now)
        let closedRunRevision = try XCTUnwrap(state.runs.first { $0.id == priorRoutineRunID }?.revision)
        let initial = snapshot(state: state)
        let cases: [(String, SharedCommand, UUID)] = [
            ("startRun", .startRun(routineID: routine.id, expectedDefinitionVersion: 1), priorRoutineRunID),
            ("startOneOff", .startOneOff(title: "New one-off", items: items, settings: .init()), priorOneOffID),
            ("repeatRun", .repeatRun(runID: priorRoutineRunID, expectedRunRevision: closedRunRevision),
             otherRoutineRunID),
            ("saveRunAsRoutine", .saveRunAsRoutine(runID: priorOneOffID,
                                                   expectedRunRevision: priorOneOffRevision, title: nil), routine.id)
        ]
        for (name, command, oldID) in cases {
            let client = CreatedIDResponseClient(snapshot: initial, actorID: actorID,
                                                 change: .existing(oldID))
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            _ = try await coordinator.refresh()
            let actionID = UUID()
            do {
                _ = try await coordinator.execute(command, commandID: actionID)
                XCTFail("\(name) accepted a preexisting created ID")
            } catch { XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, name) }
            XCTAssertEqual(coordinator.snapshot, initial, name)
            XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: actionID), name)
            XCTAssertFalse(coordinator.hasConfirmedReceipt(commandID: actionID, command: command), name)
        }
    }

    func testGenuineCreatedIDSurvivesLostReplyAndRefreshBeforeExactRetry() async throws {
        var state = SecondLookState()
        _ = try state.startOneOff(title: "Old one-off", items: [RoutineItem(title: "Keys")],
                                  performerID: actorID, reviewerID: reviewerID, now: now)
        let initial = snapshot(state: state)
        let command = SharedCommand.startOneOff(title: "New one-off",
                                                 items: [RoutineItem(title: "Wallet")], settings: .init())
        let client = LostCreationReplyClient(snapshot: initial, actorID: actorID)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        let actionID = UUID()
        do {
            _ = try await coordinator.execute(command, commandID: actionID)
            XCTFail("The first reply should have been lost")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable) }
        XCTAssertEqual(coordinator.snapshot, initial)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: actionID))
        _ = try await coordinator.refresh()
        XCTAssertEqual(coordinator.snapshot?.revision, 1)
        let resultID = try await coordinator.execute(command, commandID: actionID)
        let createdID = try XCTUnwrap(resultID)
        XCTAssertFalse(initial.state.runs.contains { $0.id == createdID })
        XCTAssertEqual(coordinator.takeConfirmedReceipt(commandID: actionID,
                                                        command: command)?.createdID, createdID)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: actionID))
    }

    func testSaveAsRoutineReplayAfterRoutineDeletionRetainsOriginalCreatedID() async throws {
        let (_, initial, command) = try XCTUnwrap(creationCases().first { $0.0 == "saveRunAsRoutine" })
        let client = DeletedCreatedRoutineReplayClient(snapshot: initial, actorID: actorID)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        let actionID = UUID()
        let resultID = try await coordinator.execute(command, commandID: actionID)
        let createdID = try XCTUnwrap(resultID)
        XCTAssertEqual(coordinator.snapshot?.revision, 2)
        XCTAssertTrue(coordinator.snapshot?.state.routines.isEmpty == true)
        XCTAssertEqual(coordinator.takeConfirmedReceipt(commandID: actionID,
                                                        command: command)?.createdID, createdID)
    }
}
