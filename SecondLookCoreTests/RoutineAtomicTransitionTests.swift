import Foundation
import XCTest
@testable import SecondLookCore

private actor RoutineAtomicClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private let now: Date
    private var alterNextReply = false
    private var receipts: [UUID: SharedCommandResult] = [:]

    init(current: SharedSnapshot, actorID: UUID, now: Date) {
        self.current = current
        self.actorID = actorID
        self.now = now
    }
    func setCurrent(_ snapshot: SharedSnapshot) { current = snapshot }
    func mixNextReply() { alterNextReply = true }
    func fetch(spaceID: UUID) async throws -> SharedSnapshot { current }
    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        if let stored = receipts[envelope.commandID] { return stored }
        let actual = try SharedCommandProcessor.apply(envelope, to: current,
                                                      actorID: actorID, now: now)
        current = actual.snapshot
        receipts[envelope.commandID] = actual
        if alterNextReply {
            alterNextReply = false
            var mixed = actual.snapshot.state
            try mixed.saveRoutine(Routine(title: "Extra", items: [RoutineItem(title: "Other")]))
            return SharedCommandResult(snapshot: SharedSnapshot(spaceID: actual.snapshot.spaceID,
                revision: actual.snapshot.revision, members: actual.snapshot.members,
                state: mixed), createdID: actual.createdID)
        }
        return actual
    }
}

@MainActor
final class RoutineAtomicTransitionTests: XCTestCase {
    private let owner = UUID(uuidString: "A6000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "A6000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "A6000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var scope: SharedAccountScope {
        SharedAccountScope(backend: "routine-atomic-test", accountID: owner, spaceID: space)
    }
    private func view(_ state: SecondLookState, revision: Int,
                      members: [UUID]? = nil) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision,
                       members: members ?? [owner, peer], state: state)
    }
    private func fixture() throws -> (SecondLookState, UUID, UUID) {
        var state = SecondLookState()
        let first = Routine(title: "First", items: [RoutineItem(title: "Door")])
        let second = Routine(title: "Second", items: [RoutineItem(title: "Keys")])
        try state.saveRoutine(first)
        try state.saveRoutine(second)
        let runID = try state.startOneOff(title: "Existing", items: [RoutineItem(title: "Bag")],
                                          performerID: owner, reviewerID: peer, now: now)
        return (state, first.id, runID)
    }
    private func expectInvalid(_ coordinator: SharedStateCoordinator,
                               references: [SharedSnapshot] = [],
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await coordinator.refresh(validatingAgainst: references)
            XCTFail("One shared revision accepted multiple routine/aggregate writes", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    func testUnseededReferencesRejectTwoRoutineWritesVersionJumpAndMixedAggregateWrites() async throws {
        let (source, firstID, runID) = try fixture()
        let first = view(source, revision: 1)
        let mixed: [SecondLookState] = try [
            { var s = source; try s.saveRoutine(Routine(title: "Third", items: [RoutineItem(title: "One")]))
                try s.saveRoutine(Routine(title: "Fourth", items: [RoutineItem(title: "Two")]))
                return s }(),
            { var s = source; var r = s.routines[0]; r.title = "Changed"; try s.saveRoutine(r)
                r = s.routines[1]; r.title = "Changed too"; try s.saveRoutine(r); return s }(),
            { var s = source; var r = s.routines[0]; try s.saveRoutine(r)
                r = s.routines[0]; try s.saveRoutine(r); return s }(),
            { var s = source; let r = Routine(title: "Third", items: [RoutineItem(title: "One")])
                try s.saveRoutine(r); try s.saveRoutine(r); return s }(),
            { var s = source; try s.deleteRoutine(id: firstID)
                try s.saveRoutine(Routine(title: "Replacement", items: [RoutineItem(title: "New")]))
                return s }(),
            { var s = source; try s.saveRoutine(Routine(title: "Third", items: [RoutineItem(title: "One")]))
                try s.updateRunSettings(runID: runID, actorID: owner,
                    settings: RunSettings(reminders: ReminderPreferences(remindPerformer: true)))
                return s }(),
            { var s = source; try s.deleteRoutine(id: firstID)
                try s.setStandardChecked(runID: runID, itemID: source.runs[0].items[0].id,
                    checked: true, actorID: owner, now: now); return s }(),
            { var s = source; try s.saveRoutine(Routine(title: "Third", items: [RoutineItem(title: "One")]))
                return SecondLookState(routines: [s.routines[2], s.routines[0], s.routines[1]],
                    runs: s.runs, archives: s.archives) }(),
        ]
        for state in mixed {
            let candidate = view(state, revision: 2)
            try candidate.validate(for: owner)
            let client = RoutineAtomicClient(current: candidate, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            await expectInvalid(coordinator, references: [first])
            XCTAssertNil(coordinator.snapshot)
        }
    }

    func testChronologyAndSeededRefreshRejectRoutineWriteCombinedWithJoinOrOldRunEdit() async throws {
        let (source, _, runID) = try fixture()
        let first = view(source, revision: 1)
        var changed = source
        try changed.saveRoutine(Routine(title: "Added", items: [RoutineItem(title: "One")]))
        try changed.updateRunSettings(runID: runID, actorID: owner,
            settings: RunSettings(reminders: ReminderPreferences(remindPerformer: true)))
        let middle = view(changed, revision: 2)
        let latest = view(changed, revision: 3)
        try middle.validate(for: owner)
        let client = RoutineAtomicClient(current: latest, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalid(coordinator, references: [first, middle])
        await client.setCurrent(first)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        await client.setCurrent(middle)
        await expectInvalid(coordinator)
        XCTAssertEqual(coordinator.snapshot, first)

        var savedOnly = SecondLookState(routines: source.routines)
        let oneMember = view(savedOnly, revision: 1, members: [owner])
        try savedOnly.saveRoutine(Routine(title: "Added", items: [RoutineItem(title: "One")]))
        let joinedAndSaved = view(savedOnly, revision: 2)
        try oneMember.validate(for: owner)
        try joinedAndSaved.validate(for: owner)
        let joiningClient = RoutineAtomicClient(current: joinedAndSaved, actorID: owner, now: now)
        let joining = SharedStateCoordinator()
        joining.beginSession(scope: scope, client: joiningClient)
        await expectInvalid(joining, references: [oneMember])
    }

    func testCommandReplyCannotCombineRoutineSavesAndExactRetryUsesOriginalReceipt() async throws {
        let (source, _, _) = try fixture()
        let first = view(source, revision: 1)
        let client = RoutineAtomicClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let routine = Routine(title: "New", items: [RoutineItem(title: "Thing")])
        let command: SharedCommand = .saveRoutine(definition: routine,
                                                   expectedDefinitionVersion: nil)
        let commandID = UUID()
        await client.mixNextReply()
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("Combined routine save reply was published")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertEqual(coordinator.snapshot, first)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        _ = try await coordinator.execute(command, commandID: commandID)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: commandID))
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
        XCTAssertEqual(coordinator.snapshot?.state.routines.count, 3)
    }

    func testActualSaveEditDeleteSaveAsAndMultiStepGapRemainValid() async throws {
        let (source, firstID, runID) = try fixture()
        let first = view(source, revision: 1)
        let save = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 1, command: .saveRoutine(definition:
                Routine(title: "Third", items: [RoutineItem(title: "One")]),
                expectedDefinitionVersion: nil))
        let added = try SharedCommandProcessor.apply(save, to: first, actorID: peer, now: now).snapshot
        try await expectPublished(first, added)
        let same = added.state.routines[0]
        let edit = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 2, command: .saveRoutine(definition: same,
                expectedDefinitionVersion: same.definitionVersion))
        let edited = try SharedCommandProcessor.apply(edit, to: added, actorID: owner, now: now).snapshot
        XCTAssertEqual(edited.state.routines[0].definitionVersion, 2)
        try await expectPublished(added, edited)
        let delete = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 3, command: .deleteRoutine(routineID: firstID,
                expectedDefinitionVersion: 2))
        let deleted = try SharedCommandProcessor.apply(delete, to: edited, actorID: peer, now: now).snapshot
        try await expectPublished(edited, deleted)
        let saveAs = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 4, command: .saveRunAsRoutine(runID: runID,
                expectedRunRevision: deleted.state.runs[0].revision, title: "Copied"))
        let copied = try SharedCommandProcessor.apply(saveAs, to: deleted, actorID: owner, now: now).snapshot
        try await expectPublished(deleted, copied)
        try await expectPublished(first, copied)
    }

    private func expectPublished(_ earlier: SharedSnapshot, _ later: SharedSnapshot) async throws {
        try earlier.validate(for: owner)
        try later.validate(for: owner)
        let client = RoutineAtomicClient(current: later, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let published = try await coordinator.refresh(validatingAgainst: [earlier])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, later)
    }
}
