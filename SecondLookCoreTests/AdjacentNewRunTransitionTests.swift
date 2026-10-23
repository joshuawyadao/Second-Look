import Foundation
import XCTest
@testable import SecondLookCore

private actor AdjacentRunClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private let now: Date
    private var nextCommandView: SharedSnapshot?
    private var receipts: [UUID: SharedCommandResult] = [:]

    init(current: SharedSnapshot, actorID: UUID, now: Date) {
        self.current = current
        self.actorID = actorID
        self.now = now
    }
    func setCurrent(_ view: SharedSnapshot) { current = view }
    func overrideNextCommand(with view: SharedSnapshot) { nextCommandView = view }
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
        if let nextCommandView {
            self.nextCommandView = nil
            return SharedCommandResult(snapshot: nextCommandView, createdID: result.createdID)
        }
        return result
    }
}

@MainActor
final class AdjacentNewRunTransitionTests: XCTestCase {
    private let owner = UUID(uuidString: "A3000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "A3000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "A3000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func scope(for actor: UUID) -> SharedAccountScope {
        SharedAccountScope(backend: "adjacent-run-test", accountID: actor, spaceID: space)
    }
    private func view(_ state: SecondLookState, revision: Int) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision,
                       members: [owner, peer], state: state)
    }
    private func initial() -> SharedSnapshot { view(.init(), revision: 1) }

    private func validate(_ candidate: SharedSnapshot, for actor: UUID? = nil) throws {
        try candidate.validate(for: actor ?? owner)
    }

    private func expectInvalid(_ coordinator: SharedStateCoordinator,
                               references: [SharedSnapshot] = [],
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await coordinator.refresh(validatingAgainst: references)
            XCTFail("An adjacent revision introduced progressed or multiple runs", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    private func closedCandidate(completed: Bool) throws -> SecondLookState {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Invented task",
            items: [RoutineItem(title: "One")], performerID: owner, reviewerID: peer, now: now)
        if completed {
            try state.setStandardChecked(runID: runID, itemID: state.runs[0].items[0].id,
                                         checked: true, actorID: owner, now: now)
        } else {
            try state.cancel(runID: runID, actorID: owner, now: now)
        }
        return state
    }

    private func partiallyCheckedCandidate() throws -> SecondLookState {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Invented task", items: [
            RoutineItem(title: "One"), RoutineItem(title: "Two")
        ], performerID: owner, reviewerID: peer, now: now)
        try state.setStandardChecked(runID: runID, itemID: state.runs[0].items[0].id,
                                     checked: true, actorID: owner, now: now)
        var run = state.runs[0]
        run.revision = 1 // A coherent standalone view can forge an initial run revision.
        return SecondLookState(runs: [run])
    }

    private func consumedEvidenceCandidate() throws -> SecondLookState {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Invented review",
            items: [RoutineItem(title: "Door", priority: .high)],
            performerID: owner, reviewerID: peer, now: now)
        let itemID = state.runs[0].items[0].id
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: owner,
            fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: runID, itemID: itemID, actorID: owner)
        try state.acceptSend(runID: runID, itemID: itemID, actorID: owner,
                             expectedVersion: version, now: now)
        try state.withdraw(runID: runID, itemID: itemID, actorID: owner,
                           expectedVersion: version, now: now)
        var run = state.runs[0]
        run.revision = 1
        return SecondLookState(runs: [run])
    }

    private func twoFreshCandidate() throws -> SecondLookState {
        var state = SecondLookState()
        for title in ["First", "Second"] {
            _ = try state.startOneOff(title: title, items: [RoutineItem(title: "Step")],
                                      performerID: owner, reviewerID: peer, now: now)
        }
        return state
    }

    func testUnseededReferencesRejectCompressedClosureProgressAndTwoFreshRuns() async throws {
        let baseline = initial()
        try validate(baseline)
        let candidates = try [closedCandidate(completed: false), closedCandidate(completed: true),
                              partiallyCheckedCandidate(), consumedEvidenceCandidate(),
                              twoFreshCandidate()]
        for state in candidates {
            let incoming = view(state, revision: 2)
            try validate(incoming)
            let client = AdjacentRunClient(current: incoming, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope(for: owner), client: client)
            await expectInvalid(coordinator, references: [baseline])
            XCTAssertNil(coordinator.snapshot)
        }
    }

    func testChronologicalReferencesCannotHideCompressedNewRun() async throws {
        let first = initial()
        let compressed = view(try partiallyCheckedCandidate(), revision: 2)
        let latest = view(compressed.state, revision: 3)
        try validate(compressed)
        try validate(latest)
        let client = AdjacentRunClient(current: latest, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(for: owner), client: client)
        await expectInvalid(coordinator, references: [compressed, first])
        XCTAssertNil(coordinator.snapshot)
    }

    func testSeededRefreshRejectsTwoNewRunsAtOneRevision() async throws {
        let baseline = initial()
        let client = AdjacentRunClient(current: baseline, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(for: owner), client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let incoming = view(try twoFreshCandidate(), revision: 2)
        try validate(incoming)
        await client.setCurrent(incoming)
        await expectInvalid(coordinator)
        XCTAssertEqual(coordinator.snapshot, baseline)
    }

    func testCommandResponseCannotAddCompressedRunAndExactRetryRecovers() async throws {
        let baseline = view(.init(), revision: 0)
        let client = AdjacentRunClient(current: baseline, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(for: owner), client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let command: SharedCommand = .saveRoutine(definition: Routine(title: "Independent",
            items: [RoutineItem(title: "Coat")]), expectedDefinitionVersion: nil)
        let commandID = UUID()
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: commandID,
                                             expectedSpaceRevision: 0, command: command)
        let genuine = try SharedCommandProcessor.apply(envelope, to: baseline,
                                                       actorID: owner, now: now)
        let coherent = try closedCandidate(completed: false)
        let compressed = view(SecondLookState(routines: genuine.snapshot.state.routines,
            runs: coherent.runs, archives: coherent.archives), revision: 1)
        try validate(compressed)
        await client.overrideNextCommand(with: compressed)
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("A command response compressed a run creation and closure")
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

    func testActualCoreCreationsWithCustomSettingsPeerAndDeletedTemplateRemainValid() async throws {
        let settings = RunSettings(reminders: ReminderPreferences(remindPerformer: true),
                                   unreviewedTimeoutSeconds: 120)
        let routine = Routine(title: "Template", items: [RoutineItem(title: "Door", priority: .high)],
                              settings: settings)
        var state = SecondLookState()
        try state.saveRoutine(routine)
        let baseline = view(state, revision: 1)
        let start = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 1, command: .startRun(routineID: routine.id,
                expectedDefinitionVersion: 1))
        let started = try SharedCommandProcessor.apply(start, to: baseline,
                                                       actorID: owner, now: now).snapshot
        try await expectPublished(from: baseline, to: started, actor: owner)
        XCTAssertEqual(started.state.runs[0].settings, settings)

        let peerStart = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: started.revision,
            command: .startOneOff(title: "Peer run", items: [RoutineItem(title: "Step")],
                                  settings: settings))
        let peerStarted = try SharedCommandProcessor.apply(peerStart, to: started,
                                                           actorID: peer, now: now).snapshot
        try await expectPublished(from: started, to: peerStarted, actor: peer)
        XCTAssertEqual(peerStarted.state.runs[1].performerID, peer)

        var closed = peerStarted.state
        try closed.cancel(runID: started.state.runs[0].id, actorID: owner, now: now)
        try closed.deleteRoutine(id: routine.id)
        let afterDeletion = view(closed, revision: peerStarted.revision + 2)
        try validate(afterDeletion)
        let repeatEnvelope = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: afterDeletion.revision,
            command: .repeatRun(runID: started.state.runs[0].id,
                                expectedRunRevision: closed.runs[0].revision))
        let repeated = try SharedCommandProcessor.apply(repeatEnvelope, to: afterDeletion,
                                                        actorID: owner, now: now).snapshot
        try await expectPublished(from: afterDeletion, to: repeated, actor: owner)
        XCTAssertEqual(repeated.state.runs.last?.routineID, routine.id)
        XCTAssertEqual(repeated.state.runs.last?.settings, settings)
    }

    func testRealCreateThenCloseAndTwoStartsAcrossTwoRevisionsRemainValid() async throws {
        let baseline = initial()
        let first = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 1, command: .startOneOff(title: "First",
                items: [RoutineItem(title: "Step")], settings: .init()))
        let started = try SharedCommandProcessor.apply(first, to: baseline,
                                                       actorID: owner, now: now).snapshot
        let runID = try XCTUnwrap(started.state.runs.first?.id)
        let close = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 2, command: .cancel(runID: runID,
                expectedRunRevision: started.state.runs[0].revision))
        let closed = try SharedCommandProcessor.apply(close, to: started,
                                                      actorID: owner, now: now).snapshot
        try await expectPublished(from: baseline, to: closed, actor: owner)

        let second = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 2, command: .startOneOff(title: "Second",
                items: [RoutineItem(title: "Step")], settings: .init()))
        let twiceStarted = try SharedCommandProcessor.apply(second, to: started,
                                                            actorID: owner, now: now).snapshot
        try await expectPublished(from: baseline, to: twiceStarted, actor: owner)
        XCTAssertEqual(twiceStarted.state.runs.count, 2)
    }

    private func expectPublished(from earlier: SharedSnapshot, to later: SharedSnapshot,
                                 actor: UUID) async throws {
        try validate(earlier, for: actor)
        try validate(later, for: actor)
        let client = AdjacentRunClient(current: later, actorID: actor, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(for: actor), client: client)
        let published = try await coordinator.refresh(validatingAgainst: [earlier])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, later)
    }
}
