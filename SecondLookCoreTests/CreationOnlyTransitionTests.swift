import Foundation
import XCTest
@testable import SecondLookCore

private actor CreationOnlyClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private let now: Date
    private var rewriteOldRunOnNextCommand = false
    private var receipts: [UUID: SharedCommandResult] = [:]

    init(current: SharedSnapshot, actorID: UUID, now: Date) {
        self.current = current
        self.actorID = actorID
        self.now = now
    }
    func setCurrent(_ view: SharedSnapshot) { current = view }
    func rewriteOldRunOnNextResponse() { rewriteOldRunOnNextCommand = true }
    func storedResult(for commandID: UUID) -> SharedCommandResult? { receipts[commandID] }
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
        if rewriteOldRunOnNextCommand {
            rewriteOldRunOnNextCommand = false
            var runs = result.snapshot.state.runs
            runs[0].settings = RunSettings(reminders:
                ReminderPreferences(remindPerformer: true))
            runs[0].revision += 1
            let alteredState = SecondLookState(routines: result.snapshot.state.routines,
                                               runs: runs, archives: result.snapshot.state.archives)
            let altered = SharedSnapshot(spaceID: result.snapshot.spaceID,
                revision: result.snapshot.revision, members: result.snapshot.members,
                state: alteredState)
            return SharedCommandResult(snapshot: altered, createdID: result.createdID)
        }
        return result
    }
}

@MainActor
final class CreationOnlyTransitionTests: XCTestCase {
    private let owner = UUID(uuidString: "A4000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "A4000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "A4000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func scope(_ actor: UUID? = nil) -> SharedAccountScope {
        SharedAccountScope(backend: "creation-only-test", accountID: actor ?? owner, spaceID: space)
    }
    private func view(_ state: SecondLookState, revision: Int,
                      members: [UUID]? = nil) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision,
                       members: members ?? [owner, peer], state: state)
    }
    private func fixture() throws -> (SecondLookState, UUID, UUID) {
        var state = SecondLookState()
        let routine = Routine(title: "Template", items: [RoutineItem(title: "Door")])
        try state.saveRoutine(routine)
        let oldID = try state.startOneOff(title: "Existing", items: [
            RoutineItem(title: "First"), RoutineItem(title: "Second")
        ], performerID: owner, reviewerID: peer, now: now)
        return (state, routine.id, oldID)
    }
    private func withFreshRun(_ source: SecondLookState) throws -> SecondLookState {
        var state = source
        _ = try state.startOneOff(title: "New", items: [RoutineItem(title: "Step")],
                                  performerID: owner, reviewerID: peer, now: now)
        return state
    }
    private func expectInvalid(_ coordinator: SharedStateCoordinator,
                               references: [SharedSnapshot] = [],
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await coordinator.refresh(validatingAgainst: references)
            XCTFail("A new run was combined with another adjacent aggregate mutation",
                    file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    func testUnseededReferencesRejectNewRunMixedWithOldProgressSettingsClosureAndRoutineWrites() async throws {
        let (source, routineID, oldID) = try fixture()
        let first = view(source, revision: 1)
        try first.validate(for: owner)
        let mixed: [SecondLookState] = try [
            { var s = try withFreshRun(source); try s.setStandardChecked(runID: oldID,
                itemID: source.runs[0].items[0].id, checked: true, actorID: owner, now: now); return s }(),
            { var s = try withFreshRun(source); try s.updateRunSettings(runID: oldID,
                actorID: owner, settings: RunSettings(reminders:
                    ReminderPreferences(remindPerformer: true))); return s }(),
            { var s = try withFreshRun(source); try s.cancel(runID: oldID,
                actorID: owner, now: now); return s }(),
            { var s = try withFreshRun(source); for item in source.runs[0].items {
                try s.setStandardChecked(runID: oldID, itemID: item.id,
                                         checked: true, actorID: owner, now: now)
              }; return s }(),
            { var s = try withFreshRun(source); var edited = s.routines[0];
                edited.title = "Edited template"; try s.saveRoutine(edited); return s }(),
            { var s = try withFreshRun(source); try s.deleteRoutine(id: routineID); return s }(),
            { var s = try withFreshRun(source); try s.saveRoutine(Routine(title: "Other",
                items: [RoutineItem(title: "Extra")])); return s }(),
            { let s = try withFreshRun(source); return SecondLookState(routines: s.routines,
                runs: [s.runs[1], s.runs[0]], archives: s.archives) }(),
        ]
        for state in mixed {
            let incoming = view(state, revision: 2)
            try incoming.validate(for: owner)
            let client = CreationOnlyClient(current: incoming, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope(), client: client)
            await expectInvalid(coordinator, references: [first])
            XCTAssertNil(coordinator.snapshot)
        }
    }

    func testUnseededReferenceRejectsJoiningWhileCreatingRun() async throws {
        var source = SecondLookState()
        _ = try source.startOneOff(title: "Existing", items: [RoutineItem(title: "Step")],
            performerID: owner, reviewerID: nil, now: now)
        let first = view(source, revision: 1, members: [owner])
        let incoming = view(try withFreshRun(source), revision: 2, members: [owner, peer])
        try first.validate(for: owner)
        try incoming.validate(for: owner)
        let client = CreationOnlyClient(current: incoming, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(), client: client)
        await expectInvalid(coordinator, references: [first])
    }

    func testChronologicalReferencesCannotHideCreationAndOldRunProgress() async throws {
        let (source, _, oldID) = try fixture()
        let first = view(source, revision: 1)
        var mixed = try withFreshRun(source)
        try mixed.setStandardChecked(runID: oldID, itemID: source.runs[0].items[0].id,
                                     checked: true, actorID: owner, now: now)
        let middle = view(mixed, revision: 2)
        let latest = view(mixed, revision: 3)
        try middle.validate(for: owner)
        let client = CreationOnlyClient(current: latest, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(), client: client)
        await expectInvalid(coordinator, references: [middle, first])
        XCTAssertNil(coordinator.snapshot)
    }

    func testSeededRefreshRejectsNewRunAndRoutineEdit() async throws {
        let (source, _, _) = try fixture()
        let first = view(source, revision: 1)
        let client = CreationOnlyClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(), client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        var mixed = try withFreshRun(source)
        var routine = mixed.routines[0]
        routine.title = "Changed template"
        try mixed.saveRoutine(routine)
        let incoming = view(mixed, revision: 2)
        try incoming.validate(for: owner)
        await client.setCurrent(incoming)
        await expectInvalid(coordinator)
        XCTAssertEqual(coordinator.snapshot, first)
    }

    func testCommandResponseCannotChangeOldRunDuringStartAndExactRetryRecovers() async throws {
        let (source, _, oldID) = try fixture()
        let first = view(source, revision: 0)
        let client = CreationOnlyClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(), client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let command: SharedCommand = .startOneOff(title: "New",
            items: [RoutineItem(title: "Step")], settings: .init())
        let commandID = UUID()
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: commandID,
                                             expectedSpaceRevision: 0, command: command)
        let candidate = try SharedCommandProcessor.apply(envelope, to: first,
                                                         actorID: owner, now: now)
        var alteredRuns = candidate.snapshot.state.runs
        alteredRuns[0].settings = RunSettings(reminders:
            ReminderPreferences(remindPerformer: true))
        alteredRuns[0].revision += 1
        let standaloneAltered = view(SecondLookState(routines: candidate.snapshot.state.routines,
            runs: alteredRuns, archives: candidate.snapshot.state.archives), revision: 1)
        try standaloneAltered.validate(for: owner)
        await client.rewriteOldRunOnNextResponse()
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("A start command response changed an older run")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertEqual(coordinator.snapshot, first)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        XCTAssertFalse(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
        _ = try await coordinator.execute(command, commandID: commandID)
        let stored = await client.storedResult(for: commandID)
        XCTAssertEqual(coordinator.snapshot, stored?.snapshot)
        XCTAssertNotNil(stored?.createdID)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: commandID))
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
        XCTAssertEqual(stored?.snapshot.state.runs[0].id, oldID)
    }

    func testActualStartsAndTwoStepCreateThenAnotherCommandRemainValid() async throws {
        let (source, routineID, oldID) = try fixture()
        let first = view(source, revision: 1)
        let start = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 1, command: .startRun(routineID: routineID,
                expectedDefinitionVersion: 1))
        let started = try SharedCommandProcessor.apply(start, to: first,
                                                       actorID: owner, now: now).snapshot
        try await expectPublished(from: first, to: started)
        let peerStart = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 2, command: .startOneOff(title: "Peer run",
                items: [RoutineItem(title: "Step")], settings: .init()))
        let peerStarted = try SharedCommandProcessor.apply(peerStart, to: started,
                                                           actorID: peer, now: now).snapshot
        try await expectPublished(from: started, to: peerStarted, actor: peer)

        var closed = source
        try closed.cancel(runID: oldID, actorID: owner, now: now)
        try closed.deleteRoutine(id: routineID)
        let afterDeletion = view(closed, revision: 3)
        let repeatEnvelope = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 3, command: .repeatRun(runID: oldID,
                expectedRunRevision: closed.runs[0].revision))
        let repeated = try SharedCommandProcessor.apply(repeatEnvelope, to: afterDeletion,
                                                        actorID: owner, now: now).snapshot
        try await expectPublished(from: afterDeletion, to: repeated)

        let currentNewID = try XCTUnwrap(started.state.runs.last?.id)
        let settings = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 2, command: .updateRunSettings(runID: currentNewID,
                settings: RunSettings(reminders: ReminderPreferences(remindPerformer: true)),
                expectedRunRevision: started.state.runs.last!.revision))
        let afterSettings = try SharedCommandProcessor.apply(settings, to: started,
                                                             actorID: owner, now: now).snapshot
        try await expectPublished(from: first, to: afterSettings)
    }

    private func expectPublished(from earlier: SharedSnapshot, to later: SharedSnapshot,
                                 actor: UUID? = nil) async throws {
        let account = actor ?? owner
        try earlier.validate(for: account)
        try later.validate(for: account)
        let client = CreationOnlyClient(current: later, actorID: account, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(account), client: client)
        let published = try await coordinator.refresh(validatingAgainst: [earlier])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, later)
    }
}
