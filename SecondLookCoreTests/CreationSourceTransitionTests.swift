import Foundation
import XCTest
@testable import SecondLookCore

private actor CreationSourceClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private let now: Date
    private var altered: ((SharedCommandResult) -> SharedCommandResult)?
    private var receipts: [UUID: SharedCommandResult] = [:]

    init(current: SharedSnapshot, actorID: UUID, now: Date) {
        self.current = current
        self.actorID = actorID
        self.now = now
    }
    func setCurrent(_ snapshot: SharedSnapshot) { current = snapshot }
    func alterNext(_ transform: @escaping @Sendable (SharedCommandResult) -> SharedCommandResult) {
        altered = transform
    }
    func fetch(spaceID: UUID) async throws -> SharedSnapshot { current }
    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        if let receipt = receipts[envelope.commandID] { return receipt }
        let actual = try SharedCommandProcessor.apply(envelope, to: current, actorID: actorID, now: now)
        current = actual.snapshot
        receipts[envelope.commandID] = actual
        if let altered {
            self.altered = nil
            return altered(actual)
        }
        return actual
    }
}

@MainActor
final class CreationSourceTransitionTests: XCTestCase {
    private let owner = UUID(uuidString: "A5000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "A5000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "A5000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let settings = RunSettings(reminders: ReminderPreferences(remindPerformer: true))

    private var scope: SharedAccountScope {
        SharedAccountScope(backend: "source-test", accountID: owner, spaceID: space)
    }
    private func view(_ state: SecondLookState, revision: Int) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision, members: [owner, peer], state: state)
    }
    private func fixture() throws -> (SecondLookState, UUID) {
        var state = SecondLookState()
        let routine = Routine(title: "Original", items: [
            RoutineItem(title: "First", photoInstructions: "Look at latch"),
            RoutineItem(title: "Second", priority: .high, photoInstructions: "Look at seal")
        ], settings: settings)
        try state.saveRoutine(routine)
        return (state, routine.id)
    }
    private func result(_ first: SharedSnapshot, _ command: SharedCommand,
                        actor: UUID? = nil) throws -> SharedCommandResult {
        try SharedCommandProcessor.apply(SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: first.revision, command: command), to: first,
            actorID: actor ?? owner, now: now)
    }
    private func withRun(_ snapshot: SharedSnapshot,
                         _ change: (inout ChecklistRun) -> Void) -> SharedSnapshot {
        var runs = snapshot.state.runs
        change(&runs[runs.count - 1])
        return view(SecondLookState(routines: snapshot.state.routines,
            runs: runs, archives: snapshot.state.archives), revision: snapshot.revision)
    }
    private func expectInvalid(_ coordinator: SharedStateCoordinator,
                               references: [SharedSnapshot] = [],
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await coordinator.refresh(validatingAgainst: references)
            XCTFail("Accepted a run whose claimed source did not match its frozen definition", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    func testAdjacentRoutineSourceMismatchRejectedAcrossUnseededReferences() async throws {
        let (source, routineID) = try fixture()
        let first = view(source, revision: 1)
        let actual = try result(first, .startRun(routineID: routineID, expectedDefinitionVersion: 1)).snapshot
        let bad: [SharedSnapshot] = [
            withRun(actual) { $0.title = "Invented" },
            withRun(actual) { $0.items.swapAt(0, 1) },
            withRun(actual) { $0.items[0].photoInstructions = "Other" },
            withRun(actual) { $0.items[1].priority = .standard },
            withRun(actual) { $0.settings = .init() },
            withRun(actual) { $0.routineVersion = 2 },
            withRun(actual) { $0.routineID = UUID() },
        ]
        for candidate in bad {
            try candidate.validate(for: owner)
            let client = CreationSourceClient(current: candidate, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            await expectInvalid(coordinator, references: [first])
            XCTAssertNil(coordinator.snapshot)
        }
    }

    func testAdjacentRoutineSourceMismatchRejectedInChronologyAndSeededRefresh() async throws {
        let (source, routineID) = try fixture()
        let first = view(source, revision: 1)
        let actual = try result(first, .startRun(routineID: routineID, expectedDefinitionVersion: 1)).snapshot
        let bad = withRun(actual) { $0.title = "Altered" }
        try bad.validate(for: owner)
        let latest = view(bad.state, revision: 3)
        let client = CreationSourceClient(current: latest, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalid(coordinator, references: [bad, first])
        XCTAssertNil(coordinator.snapshot)
        await client.setCurrent(first)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        await client.setCurrent(bad)
        await expectInvalid(coordinator)
        XCTAssertEqual(coordinator.snapshot, first)
    }

    func testKnownStartMustUseOriginalLiveVersionDespiteCompatibleClosedRepeatSource() async throws {
        let (source, routineID) = try fixture()
        var state = source
        let oldID = try state.startRun(routineID: routineID, performerID: owner,
                                       reviewerID: peer, now: now)
        try state.cancel(runID: oldID, actorID: owner, now: now)
        var edited = state.routines[0]
        edited.title = "Current version"
        try state.saveRoutine(edited)
        let first = view(state, revision: 5)
        let command: SharedCommand = .startRun(routineID: routineID, expectedDefinitionVersion: 2)
        let client = CreationSourceClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let commandID = UUID()
        let old = first.state.runs[0]
        await client.alterNext { actual in
            var runs = actual.snapshot.state.runs
            runs[runs.count - 1].title = old.title
            runs[runs.count - 1].routineVersion = old.routineVersion
            runs[runs.count - 1].items = old.items.map { RunItem(definition: RoutineItem(title: $0.title,
                priority: $0.priority, photoInstructions: $0.photoInstructions)) }
            let other = SharedSnapshot(spaceID: actual.snapshot.spaceID,
                revision: actual.snapshot.revision, members: actual.snapshot.members,
                state: SecondLookState(routines: actual.snapshot.state.routines,
                    runs: runs, archives: actual.snapshot.state.archives))
            return SharedCommandResult(snapshot: other, createdID: actual.createdID)
        }
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("Known live-template start accepted the old repeat source")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertEqual(coordinator.snapshot, first)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        coordinator.suspendSession()
        coordinator.beginSession(scope: scope, client: client)
        let restored = try await coordinator.refresh()
        XCTAssertTrue(restored)
        _ = try await coordinator.execute(command, commandID: commandID)
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
    }

    func testKnownRepeatCannotUseNewerLiveTemplateAndKnownOneOffKeepsDefinition() async throws {
        let (source, routineID) = try fixture()
        var state = source
        let oldID = try state.startRun(routineID: routineID, performerID: owner,
                                       reviewerID: peer, now: now)
        try state.cancel(runID: oldID, actorID: owner, now: now)
        var edited = state.routines[0]
        edited.title = "New live title"
        try state.saveRoutine(edited)
        let liveTitle = edited.title
        let liveVersion = edited.definitionVersion + 1
        let first = view(state, revision: 5)
        let repeatCommand: SharedCommand = .repeatRun(runID: oldID,
            expectedRunRevision: state.runs[0].revision)
        let oneOffCommand: SharedCommand = .startOneOff(title: "Invented one-off",
            items: [RoutineItem(title: "Door")], settings: settings)
        for scenario in 0..<3 {
            let command = scenario == 0 ? repeatCommand : oneOffCommand
            let client = CreationSourceClient(current: first, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            let seeded = try await coordinator.refresh()
            XCTAssertTrue(seeded)
            await client.alterNext { actual in
                var runs = actual.snapshot.state.runs
                let last = runs.count - 1
                if scenario == 0 {
                    runs[last].title = liveTitle
                    runs[last].routineVersion = liveVersion
                } else if scenario == 1 {
                    runs[last].title = "Other one-off"
                    runs[last].items[0].photoInstructions = "Other instruction"
                } else {
                    runs[last].settings = .init()
                }
                return SharedCommandResult(snapshot: SharedSnapshot(spaceID: actual.snapshot.spaceID,
                    revision: actual.snapshot.revision, members: actual.snapshot.members,
                    state: SecondLookState(routines: actual.snapshot.state.routines,
                        runs: runs, archives: actual.snapshot.state.archives)),
                    createdID: actual.createdID)
            }
            do {
                _ = try await coordinator.execute(command)
                XCTFail("Known command accepted another source definition")
            } catch {
                XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
            }
            XCTAssertEqual(coordinator.snapshot, first)
        }
    }

    func testKnownImmediateSaveAsRoutineMustMatchOriginalRun() async throws {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Source", items: [RoutineItem(title: "Key")],
            settings: settings, performerID: owner, reviewerID: peer, now: now)
        let first = view(state, revision: 2)
        let command: SharedCommand = .saveRunAsRoutine(runID: runID,
            expectedRunRevision: state.runs[0].revision, title: "Saved title")
        for alteration in 0..<4 {
            let client = CreationSourceClient(current: first, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            let seeded = try await coordinator.refresh()
            XCTAssertTrue(seeded)
            await client.alterNext { actual in
                var routines = actual.snapshot.state.routines
                switch alteration {
                case 0: routines[0].title = "Wrong title"
                case 1: routines[0].items[0].photoInstructions = "Wrong source"
                case 2: routines[0].settings = .init()
                default: routines[0].definitionVersion = 2
                }
                return SharedCommandResult(snapshot: SharedSnapshot(spaceID: actual.snapshot.spaceID,
                    revision: actual.snapshot.revision, members: actual.snapshot.members,
                    state: SecondLookState(routines: routines, runs: actual.snapshot.state.runs,
                        archives: actual.snapshot.state.archives)), createdID: actual.createdID)
            }
            let commandID = UUID()
            do {
                _ = try await coordinator.execute(command, commandID: commandID)
                XCTFail("Immediate save-as reply did not preserve the original run definition")
            } catch {
                XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
            }
            XCTAssertEqual(coordinator.snapshot, first)
            XCTAssertFalse(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
        }
    }

    func testNewerReceiptAllowsRunSettingsAndSourceChangesAfterOriginalCreation() async throws {
        let (source, routineID) = try fixture()
        let first = view(source, revision: 1)
        let client = CreationSourceClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let command: SharedCommand = .startRun(routineID: routineID,
            expectedDefinitionVersion: 1)
        let actor = owner
        let timestamp = now
        await client.alterNext { actual in
            let runID = actual.createdID!
            let settingsCommand = SharedCommandEnvelope(spaceID: actual.snapshot.spaceID,
                commandID: UUID(), expectedSpaceRevision: actual.snapshot.revision,
                command: .updateRunSettings(runID: runID, settings: .init(),
                    expectedRunRevision: actual.snapshot.state.runs[0].revision))
            let afterSettings = try! SharedCommandProcessor.apply(settingsCommand,
                to: actual.snapshot, actorID: actor, now: timestamp)
            var edited = afterSettings.snapshot.state
            var routine = edited.routines[0]
            routine.title = "Changed future source"
            try! edited.saveRoutine(routine)
            return SharedCommandResult(snapshot: SharedSnapshot(spaceID: actual.snapshot.spaceID,
                revision: afterSettings.snapshot.revision + 1, members: actual.snapshot.members,
                state: edited), createdID: runID)
        }
        let commandID = UUID()
        let created = try await coordinator.execute(command, commandID: commandID)
        XCTAssertNotNil(created)
        XCTAssertEqual(coordinator.snapshot?.revision, 4)
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
    }

    func testActualSourcesAndLargerGapRemainValid() async throws {
        let (source, routineID) = try fixture()
        let first = view(source, revision: 1)
        let started = try result(first, .startRun(routineID: routineID, expectedDefinitionVersion: 1)).snapshot
        try await expectPublished(first, started)
        var closedState = started.state
        let oldID = started.state.runs[0].id
        try closedState.cancel(runID: oldID, actorID: owner, now: now)
        try closedState.deleteRoutine(id: routineID)
        let beforeRepeat = view(closedState, revision: 4)
        let repeated = try result(beforeRepeat,
            .repeatRun(runID: oldID, expectedRunRevision: closedState.runs[0].revision)).snapshot
        try await expectPublished(beforeRepeat, repeated)
        let gap = view(repeated.state, revision: 6)
        try await expectPublished(first, gap)
    }

    private func expectPublished(_ earlier: SharedSnapshot, _ later: SharedSnapshot) async throws {
        try earlier.validate(for: owner)
        try later.validate(for: owner)
        let client = CreationSourceClient(current: later, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let published = try await coordinator.refresh(validatingAgainst: [earlier])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, later)
    }
}
