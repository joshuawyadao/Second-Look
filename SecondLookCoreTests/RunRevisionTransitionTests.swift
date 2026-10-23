import Foundation
import XCTest
@testable import SecondLookCore

private actor RunRevisionClient: SharedStateClient {
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

    func setCurrent(_ snapshot: SharedSnapshot) { current = snapshot }
    func overrideNextCommand(with snapshot: SharedSnapshot) { nextCommandView = snapshot }

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
final class RunRevisionTransitionTests: XCTestCase {
    private let owner = UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "D0000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "D0000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var scope: SharedAccountScope {
        SharedAccountScope(backend: "revision-test", accountID: owner, spaceID: space)
    }

    private func fixture() throws -> (SecondLookState, UUID, UUID) {
        var state = SecondLookState()
        let routine = Routine(title: "Invented departure", items: [
            RoutineItem(title: "Keys"), RoutineItem(title: "Door")
        ])
        try state.saveRoutine(routine)
        let runID = try state.startRun(routineID: routine.id, performerID: owner,
                                       reviewerID: peer, now: now)
        return (state, runID, routine.id)
    }

    private func view(_ state: SecondLookState, revision: Int) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision, members: [owner, peer], state: state)
    }

    private func changedRun(_ state: SecondLookState,
                            edit: (inout ChecklistRun) -> Void) -> SecondLookState {
        var run = state.runs[0]
        edit(&run)
        return SecondLookState(routines: state.routines, runs: [run], archives: state.archives)
    }

    private func expectInvalid(_ coordinator: SharedStateCoordinator,
                               references: [SharedSnapshot] = [],
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await coordinator.refresh(validatingAgainst: references)
            XCTFail("A retained run changed without advancing its revision", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    func testUnseededReferencesRejectProgressRollbackAndSameRevisionSettingsRewrite() async throws {
        let (state, runID, _) = try fixture()
        var progressed = state
        try progressed.setStandardChecked(runID: runID, itemID: state.runs[0].items[0].id,
                                          checked: true, actorID: owner, now: now)
        let earlier = view(progressed, revision: 2)
        let regressions = [state, changedRun(progressed) {
            $0.settings = RunSettings(reminders: ReminderPreferences(remindPerformer: true))
        }]
        for candidate in regressions {
            let incoming = view(candidate, revision: 3)
            try incoming.validate(for: owner)
            let client = RunRevisionClient(current: incoming, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            await expectInvalid(coordinator, references: [earlier])
            XCTAssertNil(coordinator.snapshot)
        }
    }

    func testChronologicalReferencesRejectSameRevisionProgressRewriteEvenIfLaterRestored() async throws {
        let (state, runID, _) = try fixture()
        let first = view(state, revision: 1)
        var progress = state
        try progress.setStandardChecked(runID: runID, itemID: state.runs[0].items[0].id,
                                        checked: true, actorID: owner, now: now)
        let altered = view(changedRun(progress) {
            $0.revision = state.runs[0].revision
        }, revision: 2)
        let restored = view(state, revision: 3)
        try altered.validate(for: owner)
        let client = RunRevisionClient(current: restored, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalid(coordinator, references: [altered, first])
        XCTAssertNil(coordinator.snapshot)
        XCTAssertEqual(restored.state.runs[0].id, runID)
    }

    func testSeededRefreshRejectsSameRevisionClosureRewrite() async throws {
        let (state, runID, _) = try fixture()
        let first = view(state, revision: 1)
        let client = RunRevisionClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        var closedState = state
        try closedState.cancel(runID: runID, actorID: owner, now: now)
        let closed = changedRun(closedState) { $0.revision = state.runs[0].revision }
        let incoming = view(closed, revision: 2)
        try incoming.validate(for: owner)
        await client.setCurrent(incoming)
        await expectInvalid(coordinator)
        XCTAssertEqual(coordinator.snapshot, first)
    }

    func testCommandResponseRejectsSameRevisionRewriteAndExactReceiptRetryRecovers() async throws {
        let (state, _, _) = try fixture()
        let first = view(state, revision: 0)
        let client = RunRevisionClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let command: SharedCommand = .saveRoutine(definition: Routine(title: "Another",
            items: [RoutineItem(title: "Coat")]), expectedDefinitionVersion: nil)
        let commandID = UUID()
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: commandID,
                                             expectedSpaceRevision: 0, command: command)
        let genuine = try SharedCommandProcessor.apply(envelope, to: first,
                                                       actorID: owner, now: now)
        let altered = view(changedRun(genuine.snapshot.state) {
            $0.settings = RunSettings(reminders: ReminderPreferences(remindPerformer: true))
        }, revision: 1)
        try altered.validate(for: owner)
        await client.overrideNextCommand(with: altered)
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("A command response rewrote a retained run at the same run revision")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertEqual(coordinator.snapshot, first)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        XCTAssertFalse(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
        _ = try await coordinator.execute(command, commandID: commandID)
        XCTAssertEqual(coordinator.snapshot, genuine.snapshot)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: commandID))
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
    }

    func testHigherRunRevisionsAndUnchangedRunDuringOtherWritesRemainValid() async throws {
        let (state, runID, _) = try fixture()
        let first = view(state, revision: 1)
        let client = RunRevisionClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)

        var next = state
        let itemID = state.runs[0].items[0].id
        try next.setStandardChecked(runID: runID, itemID: itemID, checked: true,
                                    actorID: owner, now: now)
        let checked = view(next, revision: 2)
        await client.setCurrent(checked)
        let checkedPublished = try await coordinator.refresh(validatingAgainst: [first])
        XCTAssertTrue(checkedPublished)
        try next.setStandardChecked(runID: runID, itemID: itemID, checked: false,
                                    actorID: owner, now: now)
        try next.updateRunSettings(runID: runID, actorID: owner,
            settings: RunSettings(reminders: ReminderPreferences(remindPerformer: true)))
        let settings = view(next, revision: 4)
        await client.setCurrent(settings)
        let settingsPublished = try await coordinator.refresh(validatingAgainst: [checked])
        XCTAssertTrue(settingsPublished)

        let newID = try next.startOneOff(title: "New independent run",
            items: [RoutineItem(title: "Lights")], performerID: peer, reviewerID: owner, now: now)
        let independent = view(next, revision: 5)
        await client.setCurrent(independent)
        let independentPublished = try await coordinator.refresh(validatingAgainst: [settings])
        XCTAssertTrue(independentPublished)
        XCTAssertEqual(independent.state.runs[0], settings.state.runs[0])
        XCTAssertTrue(independent.state.runs.contains { $0.id == newID })

        try next.cancel(runID: runID, actorID: owner, now: now)
        let closed = view(next, revision: 6)
        await client.setCurrent(closed)
        let closedPublished = try await coordinator.refresh(validatingAgainst: [independent])
        XCTAssertTrue(closedPublished)
        XCTAssertEqual(coordinator.snapshot, closed)
        XCTAssertGreaterThan(closed.state.runs[0].revision, independent.state.runs[0].revision)
    }

    func testSkippedSpaceRevisionsRejectUnreachableRunRevision() async throws {
        let (state, _, _) = try fixture()
        let first = view(state, revision: 1)
        let client = RunRevisionClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        let incoming = view(changedRun(state) { $0.revision = 100 }, revision: 3)
        try incoming.validate(for: owner)
        await client.setCurrent(incoming)
        await expectInvalid(coordinator)
        XCTAssertEqual(coordinator.snapshot, first)
    }

    func testUnseededReferencesRejectUnreachableSkippedRunRevision() async throws {
        let (state, _, _) = try fixture()
        let first = view(state, revision: 1)
        let incoming = view(changedRun(state) { $0.revision = 100 }, revision: 3)
        try incoming.validate(for: owner)
        let client = RunRevisionClient(current: incoming, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalid(coordinator, references: [first])
        XCTAssertNil(coordinator.snapshot)
    }

    func testSkippedRevisionBudgetCannotBeSpentByTwoRuns() async throws {
        var (state, firstRun, _) = try fixture()
        let secondRun = try state.startOneOff(title: "Invented second list",
            items: [RoutineItem(title: "Coat")], performerID: owner, reviewerID: peer, now: now)
        let first = view(state, revision: 1)
        let client = RunRevisionClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        for runID in [firstRun, secondRun] {
            for enabled in [true, false] {
                try state.updateRunSettings(runID: runID, actorID: owner,
                    settings: RunSettings(reminders: .init(remindPerformer: enabled)))
            }
        }
        let incoming = view(state, revision: 3)
        try incoming.validate(for: owner)
        await client.setCurrent(incoming)
        await expectInvalid(coordinator)
        XCTAssertEqual(coordinator.snapshot, first)
    }

    func testSkippedMalformedCommandViewRetainsOriginalReceiptRetry() async throws {
        let (state, _, _) = try fixture()
        let first = view(state, revision: 0)
        let client = RunRevisionClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        let command: SharedCommand = .saveRoutine(definition: Routine(title: "Invented extra",
            items: [RoutineItem(title: "Scarf")]), expectedDefinitionVersion: nil)
        let commandID = UUID()
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: commandID,
                                             expectedSpaceRevision: 0, command: command)
        let genuine = try SharedCommandProcessor.apply(envelope, to: first,
                                                       actorID: owner, now: now)
        let incoming = view(changedRun(genuine.snapshot.state) { $0.revision = 100 }, revision: 3)
        try incoming.validate(for: owner)
        await client.overrideNextCommand(with: incoming)
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("An unreachable run revision was accepted from a newer receipt view")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertEqual(coordinator.snapshot, first)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        _ = try await coordinator.execute(command, commandID: commandID)
        XCTAssertEqual(coordinator.snapshot, genuine.snapshot)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: commandID))
    }

    func testSkippedRealStandardCompletionAccountsForAutomaticClosureIncrement() async throws {
        var (state, runID, _) = try fixture()
        let first = view(state, revision: 1)
        let client = RunRevisionClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        for item in state.runs[0].items {
            try state.setStandardChecked(runID: runID, itemID: item.id,
                                          checked: true, actorID: owner, now: now)
        }
        XCTAssertEqual(state.runs[0].revision, first.state.runs[0].revision + 3)
        await client.setCurrent(view(state, revision: 3))
        let published = try await coordinator.refresh()
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot?.state, state)
    }

    #if DEBUG
    func testSkippedSyntheticSendAndApprovalFitTwoSpaceCommands() async throws {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Invented review",
            items: [RoutineItem(title: "Door", priority: .high)],
            performerID: owner, reviewerID: peer, now: now)
        let first = view(state, revision: 1)
        let client = RunRevisionClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        let itemID = state.runs[0].items[0].id
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: owner,
            fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: runID, itemID: itemID, actorID: owner, now: now)
        try state.acceptSend(runID: runID, itemID: itemID, actorID: owner,
                             expectedVersion: version, now: now)
        try state.approve(runID: runID, itemID: itemID, actorID: peer,
                           expectedVersion: version, now: now)
        XCTAssertEqual(state.runs[0].revision, first.state.runs[0].revision + 5)
        await client.setCurrent(view(state, revision: 3))
        let published = try await coordinator.refresh()
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot?.state, state)
    }
    #endif

    func testLargeSkippedRevisionBudgetDoesNotMultiplyOrOverflow() async throws {
        let (state, runID, _) = try fixture()
        let first = view(state, revision: 1)
        var updated = state
        try updated.updateRunSettings(runID: runID, actorID: owner,
            settings: RunSettings(reminders: .init(remindPerformer: true)))
        let incoming = view(updated, revision: Int.max)
        let client = RunRevisionClient(current: incoming, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let published = try await coordinator.refresh(validatingAgainst: [first])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, incoming)
    }

    private func assertGapCost(_ first: SharedSnapshot, state: SecondLookState,
                               members: [UUID]? = nil, commands: Int,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        for (gap, accepted) in [(commands - 1, false), (commands, true)] {
            let client = RunRevisionClient(current: first, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            _ = try await coordinator.refresh()
            let incoming = SharedSnapshot(spaceID: space, revision: first.revision + gap,
                members: members ?? first.members, state: state)
            try incoming.validate(for: owner)
            await client.setCurrent(incoming)
            if accepted {
                let published = try await coordinator.refresh()
                XCTAssertTrue(published, file: file, line: line)
                XCTAssertEqual(coordinator.snapshot, incoming, file: file, line: line)
            } else {
                await expectInvalid(coordinator, file: file, line: line)
                XCTAssertEqual(coordinator.snapshot, first, file: file, line: line)
            }
        }
    }

    func testSkippedBudgetIncludesNewRunAndRetainedRunMutations() async throws {
        var (state, runID, _) = try fixture()
        let first = view(state, revision: 1)
        for enabled in [true, false] {
            try state.updateRunSettings(runID: runID, actorID: owner,
                settings: RunSettings(reminders: .init(remindPerformer: enabled)))
        }
        _ = try state.startOneOff(title: "New invented list", items: [RoutineItem(title: "Coat")],
            performerID: owner, reviewerID: peer, now: now)
        try await assertGapCost(first, state: state, commands: 3)
    }

    func testSkippedBudgetIncludesEachNewRunAndItsAutomaticCompletion() async throws {
        let first = view(.init(), revision: 0)
        var state = SecondLookState()
        for index in 0..<3 {
            let runID = try state.startOneOff(title: "Invented list \(index)",
                items: [RoutineItem(title: "Keys")], performerID: owner, reviewerID: peer, now: now)
            if index == 0 {
                let itemID = try XCTUnwrap(state.runs.first?.items.first?.id)
                try state.setStandardChecked(runID: runID, itemID: itemID,
                    checked: true, actorID: owner, now: now)
            }
        }
        try await assertGapCost(first, state: state, commands: 4)
    }

    func testSkippedBudgetIncludesRoutineDeleteRecreateAndRetainedRunMutation() async throws {
        var (state, runID, routineID) = try fixture()
        let first = view(state, revision: 1)
        try state.updateRunSettings(runID: runID, actorID: owner,
            settings: RunSettings(reminders: .init(remindPerformer: true)))
        try state.deleteRoutine(id: routineID)
        try state.saveRoutine(Routine(id: routineID, title: "Changed invented definition",
            items: [RoutineItem(title: "Hat")]))
        try await assertGapCost(first, state: state, commands: 3)
    }

    func testSkippedBudgetIncludesNewRoutineVersions() async throws {
        let (initial, _, _) = try fixture()
        let first = view(initial, revision: 1)
        var state = initial
        let routine = Routine(title: "New invented definition", items: [RoutineItem(title: "Hat")])
        for _ in 0..<3 { try state.saveRoutine(routine) }
        try await assertGapCost(first, state: state, commands: 3)
    }

    func testSkippedBudgetIncludesRoutineReordering() async throws {
        var (state, runID, routineID) = try fixture()
        try state.saveRoutine(Routine(title: "Second invented definition",
            items: [RoutineItem(title: "Coat")]))
        let first = view(state, revision: 1)
        let original = try XCTUnwrap(state.routines.first)
        try state.deleteRoutine(id: routineID)
        try state.saveRoutine(original)
        try state.updateRunSettings(runID: runID, actorID: owner,
            settings: RunSettings(reminders: .init(remindPerformer: true)))
        try await assertGapCost(first, state: state, commands: 3)
    }

    func testSkippedBudgetIncludesJoiningAndRunMutations() async throws {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Invented solo list",
            items: [RoutineItem(title: "Keys")], performerID: owner, reviewerID: nil, now: now)
        let first = SharedSnapshot(spaceID: space, revision: 1, members: [owner], state: state)
        for enabled in [true, false] {
            try state.updateRunSettings(runID: runID, actorID: owner,
                settings: RunSettings(reminders: .init(remindPerformer: enabled)))
        }
        try await assertGapCost(first, state: state, members: [owner, peer], commands: 3)
    }

    func testPairedSingleUnaccountedRevisionRejectsCombinedRunEffect() async throws {
        let (state, runID, _) = try fixture()
        let first = view(state, revision: 1)
        var mutated = state
        try mutated.setStandardChecked(runID: runID, itemID: state.runs[0].items[0].id,
            checked: true, actorID: owner, now: now)
        try mutated.updateRunSettings(runID: runID, actorID: owner,
            settings: RunSettings(reminders: .init(remindPerformer: true)))
        // Two distinct effects require two run increments. An extra space
        // revision cannot justify compressing both effects into one run write.
        let impossible = view(changedRun(mutated) { $0.revision -= 1 }, revision: 3)
        try impossible.validate(for: owner)
        for seeded in [false, true] {
            let client = RunRevisionClient(current: seeded ? first : impossible,
                                           actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            if seeded { _ = try await coordinator.refresh() }
            await client.setCurrent(impossible)
            await expectInvalid(coordinator, references: seeded ? [] : [first])
            XCTAssertEqual(coordinator.snapshot, seeded ? first : nil)
        }
    }

    func testUnaccountedRevisionKeepsOriginalCommandRetry() async throws {
        let (state, runID, _) = try fixture()
        let first = view(state, revision: 1)
        let client = RunRevisionClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try await coordinator.refresh()
        let command: SharedCommand = .updateRunSettings(runID: runID,
            settings: RunSettings(reminders: .init(remindPerformer: true)),
            expectedRunRevision: state.runs[0].revision)
        let commandID = UUID()
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: commandID,
            expectedSpaceRevision: first.revision, command: command)
        let genuine = try SharedCommandProcessor.apply(envelope, to: first,
                                                       actorID: owner, now: now)
        let impossible = view(genuine.snapshot.state, revision: first.revision + 2)
        await client.overrideNextCommand(with: impossible)
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("A paired receipt view cannot hide a single unchanged command")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .invalidResponse) }
        XCTAssertEqual(coordinator.snapshot, first)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        _ = try await coordinator.execute(command, commandID: commandID)
        XCTAssertEqual(coordinator.snapshot, genuine.snapshot)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: commandID))
    }

    func testSingleHiddenSaveBeforeRoutineDeletionRemainsReachable() async throws {
        var (state, _, routineID) = try fixture()
        let first = view(state, revision: 1)
        let definition = try XCTUnwrap(state.routines.first)
        try state.saveRoutine(definition)
        try state.deleteRoutine(id: routineID)
        let incoming = view(state, revision: 3)
        let client = RunRevisionClient(current: incoming, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let published = try await coordinator.refresh(validatingAgainst: [first])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, incoming)
    }

    func testSingleHiddenSaveBeforeForcedRoutineRecreationRemainsReachable() async throws {
        var (state, _, routineID) = try fixture()
        let first = view(state, revision: 1)
        let definition = try XCTUnwrap(state.routines.first)
        try state.saveRoutine(definition)
        try state.deleteRoutine(id: routineID)
        try state.saveRoutine(Routine(id: routineID, title: "Recreated invented definition",
            items: [RoutineItem(title: "Hat")]))
        let incoming = view(state, revision: 4)
        let client = RunRevisionClient(current: incoming, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let published = try await coordinator.refresh(validatingAgainst: [first])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, incoming)
    }

    func testSingleHiddenInvitationRenewalBeforeJoinRemainsReachable() async throws {
        let first = SharedSnapshot(spaceID: space, revision: 1, members: [owner], state: .init())
        let incoming = view(.init(), revision: 3)
        let client = RunRevisionClient(current: incoming, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let published = try await coordinator.refresh(validatingAgainst: [first])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, incoming)
    }

    func testRoutineVersionRejectsSingleSlackButTemporaryRoutineCyclesRemainValid() async throws {
        let (state, _, _) = try fixture()
        let first = view(state, revision: 1)
        var saved = state
        try saved.saveRoutine(try XCTUnwrap(state.routines.first))
        let impossible = view(saved, revision: 3)
        let invalidClient = RunRevisionClient(current: impossible, actorID: owner, now: now)
        let invalidCoordinator = SharedStateCoordinator()
        invalidCoordinator.beginSession(scope: scope, client: invalidClient)
        await expectInvalid(invalidCoordinator, references: [first])
        XCTAssertNil(invalidCoordinator.snapshot)
        for extraSave in [false, true] {
            var transient = state
            let temporary = Routine(title: "Temporary invented definition",
                items: [RoutineItem(title: "Hat")])
            try transient.saveRoutine(temporary)
            if extraSave { try transient.saveRoutine(temporary) }
            try transient.deleteRoutine(id: temporary.id)
            XCTAssertEqual(transient, state)
            let incoming = view(transient, revision: first.revision + (extraSave ? 3 : 2))
            let client = RunRevisionClient(current: incoming, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            let published = try await coordinator.refresh(validatingAgainst: [first])
            XCTAssertTrue(published)
            XCTAssertEqual(coordinator.snapshot, incoming)
        }
    }
}
