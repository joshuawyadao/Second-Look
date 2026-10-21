import Foundation
import XCTest
@testable import SecondLookCore

private actor RunDefinitionClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private let now: Date
    private var commandOverride: SharedSnapshot?
    private var receipts: [UUID: SharedCommandResult] = [:]

    init(current: SharedSnapshot, actorID: UUID, now: Date) {
        self.current = current
        self.actorID = actorID
        self.now = now
    }

    func setCurrent(_ snapshot: SharedSnapshot) { current = snapshot }
    func overrideNextCommand(with snapshot: SharedSnapshot) { commandOverride = snapshot }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        guard current.spaceID == spaceID else { throw SharedStateFailure.scopeMismatch }
        return current
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        if let receipt = receipts[envelope.commandID] { return receipt }
        let result = try SharedCommandProcessor.apply(envelope, to: current,
                                                      actorID: actorID, now: now)
        current = result.snapshot
        receipts[envelope.commandID] = result
        if let commandOverride {
            self.commandOverride = nil
            return SharedCommandResult(snapshot: commandOverride, createdID: result.createdID)
        }
        return result
    }
}

@MainActor
final class RunDefinitionTransitionTests: XCTestCase {
    private let owner = UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "C0000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var scope: SharedAccountScope {
        SharedAccountScope(backend: "definition-test", accountID: owner, spaceID: space)
    }

    private func fixture() throws -> (SecondLookState, UUID, UUID) {
        var state = SecondLookState()
        let routine = Routine(title: "Invented departure", items: [
            RoutineItem(title: "Keys"),
            RoutineItem(title: "Door", priority: .high, photoInstructions: "Show the lock")
        ])
        try state.saveRoutine(routine)
        let runID = try state.startRun(routineID: routine.id, performerID: owner,
                                       reviewerID: peer, now: now)
        return (state, runID, routine.id)
    }

    private func view(_ state: SecondLookState, revision: Int) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision,
                       members: [owner, peer], state: state)
    }

    private func changedRun(_ state: SecondLookState,
                            edit: (inout ChecklistRun) -> Void) -> SecondLookState {
        var run = state.runs[0]
        edit(&run)
        return SecondLookState(routines: state.routines, runs: [run], archives: state.archives)
    }

    private func expectInvalidRefresh(_ coordinator: SharedStateCoordinator,
                                      references: [SharedSnapshot] = [],
                                      file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await coordinator.refresh(validatingAgainst: references)
            XCTFail("A retained run changed its frozen definition", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    func testUnseededReferencesRejectRemovalDowngradeReorderReplacementAndTextChanges() async throws {
        let (state, _, _) = try fixture()
        let baseline = view(state, revision: 1)
        let changes: [SecondLookState] = [
            changedRun(state) { $0.items.removeLast() },
            changedRun(state) { $0.items[1].priority = .standard },
            changedRun(state) { $0.items.swapAt(0, 1) },
            changedRun(state) { $0.items[1] = RunItem(definition: RoutineItem(
                title: "Door", priority: .high, photoInstructions: "Show the lock")) },
            changedRun(state) { $0.items[0].title = "Different keys" },
            changedRun(state) { $0.items[1].photoInstructions = "Different view" },
            changedRun(state) { $0.title = "Different departure" },
        ]
        for changed in changes {
            let incoming = view(changed, revision: 2)
            try incoming.validate(for: owner) // The snapshots are coherent; their transition is not.
            let client = RunDefinitionClient(current: incoming, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            await expectInvalidRefresh(coordinator, references: [baseline])
            XCTAssertNil(coordinator.snapshot)
        }
    }

    func testUnseededReferencesRejectRoutineProvenanceAndStartTimeChanges() async throws {
        let (state, _, _) = try fixture()
        let baseline = view(state, revision: 1)
        let changes: [SecondLookState] = [
            changedRun(state) { $0.routineID = UUID() },
            changedRun(state) { $0.routineVersion = 2 },
            changedRun(state) { $0.startedAt = now.addingTimeInterval(10) },
        ]
        for changed in changes {
            let incoming = view(changed, revision: 2)
            try incoming.validate(for: owner)
            let client = RunDefinitionClient(current: incoming, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            await expectInvalidRefresh(coordinator, references: [baseline])
            XCTAssertNil(coordinator.snapshot)
        }
    }

    func testChronologicalReferencesCannotHideTemporaryDefinitionRewrite() async throws {
        let (state, _, _) = try fixture()
        let first = view(state, revision: 1)
        let changed = view(changedRun(state) { $0.items[1].priority = .standard }, revision: 2)
        let restored = view(state, revision: 3)
        let client = RunDefinitionClient(current: restored, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalidRefresh(coordinator, references: [changed, first])
        XCTAssertNil(coordinator.snapshot)
    }

    func testClosureCannotHideAChangedRunDefinitionBehindMatchingArchive() async throws {
        let (state, runID, _) = try fixture()
        let first = view(state, revision: 1)
        var changed = changedRun(state) { $0.items[1].priority = .standard }
        try changed.cancel(runID: runID, actorID: owner, now: now)
        let incoming = view(changed, revision: 2)
        try incoming.validate(for: owner)
        let client = RunDefinitionClient(current: incoming, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalidRefresh(coordinator, references: [first])
        XCTAssertNil(coordinator.snapshot)
    }

    func testSeededRefreshRejectsChangedDefinitionWithoutReferences() async throws {
        let (state, _, _) = try fixture()
        let first = view(state, revision: 1)
        let client = RunDefinitionClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let changed = view(changedRun(state) { $0.title = "Rewritten" }, revision: 2)
        await client.setCurrent(changed)
        await expectInvalidRefresh(coordinator)
        XCTAssertEqual(coordinator.snapshot, first)
    }

    func testCommandResponseCannotRewriteDefinitionAndExactRetryRecovers() async throws {
        let (state, _, _) = try fixture()
        let baseline = view(state, revision: 0)
        let client = RunDefinitionClient(current: baseline, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let command: SharedCommand = .saveRoutine(definition: Routine(title: "Other routine",
            items: [RoutineItem(title: "Coat")]), expectedDefinitionVersion: nil)
        let commandID = UUID()
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: commandID,
                                             expectedSpaceRevision: 0, command: command)
        let genuine = try SharedCommandProcessor.apply(envelope, to: baseline,
                                                       actorID: owner, now: now)
        let altered = view(changedRun(genuine.snapshot.state) {
            $0.items[1].priority = .standard
        }, revision: 1)
        try altered.validate(for: owner)
        await client.overrideNextCommand(with: altered)
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("A command response downgraded a retained required item")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertEqual(coordinator.snapshot, baseline)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        XCTAssertFalse(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))

        _ = try await coordinator.execute(command, commandID: commandID)
        XCTAssertEqual(coordinator.snapshot, genuine.snapshot)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: commandID))
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
    }

    func testPreferencesProgressClosureRoutineDeletionAndNewRunRemainValid() async throws {
        let (state, runID, routineID) = try fixture()
        let first = view(state, revision: 1)
        let client = RunDefinitionClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)

        var progress = state
        try progress.updateRunSettings(runID: runID, actorID: owner,
            settings: RunSettings(reminders: ReminderPreferences(remindPerformer: true)))
        let standardID = progress.runs[0].items[0].id
        try progress.setStandardChecked(runID: runID, itemID: standardID,
                                        checked: true, actorID: owner, now: now)
        var edited = progress.routines[0]
        edited.title = "Edited future routine"
        try progress.saveRoutine(edited)
        let second = view(progress, revision: 2)
        await client.setCurrent(second)
        let progressed = try await coordinator.refresh(validatingAgainst: [first])
        XCTAssertTrue(progressed)

        try progress.deleteRoutine(id: routineID)
        try progress.cancel(runID: runID, actorID: owner, now: now)
        let newID = try progress.startOneOff(title: "New independent run",
            items: [RoutineItem(title: "Lights")], performerID: peer, reviewerID: owner, now: now)
        let third = view(progress, revision: 3)
        await client.setCurrent(third)
        let published = try await coordinator.refresh(validatingAgainst: [first, second])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, third)
        XCTAssertEqual(third.state.runs.first { $0.id == runID }?.title, state.runs[0].title)
        XCTAssertTrue(third.state.archives.contains { $0.id == runID })
        XCTAssertTrue(third.state.runs.contains { $0.id == newID })
    }
}
