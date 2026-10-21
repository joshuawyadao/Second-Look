import Foundation
import XCTest
@testable import SecondLookCore

private actor EvidenceHistoryClient: SharedStateClient {
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
final class EvidenceHistoryTransitionTests: XCTestCase {
    private let owner = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "A1000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var scope: SharedAccountScope {
        SharedAccountScope(backend: "evidence-history-test", accountID: owner, spaceID: space)
    }

    private func base() throws -> (SecondLookState, UUID, UUID) {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Invented departure", items: [
            RoutineItem(title: "Door", priority: .high), RoutineItem(title: "Keys")
        ], performerID: owner, reviewerID: peer, now: now)
        return (state, runID, state.runs[0].items[0].id)
    }

    private func accepted(_ source: SecondLookState, runID: UUID,
                          itemID: UUID) throws -> SecondLookState {
        var state = source
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: owner,
            fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera,
            now: now.addingTimeInterval(1))
        let version = try state.beginSend(runID: runID, itemID: itemID, actorID: owner)
        try state.acceptSend(runID: runID, itemID: itemID, actorID: owner,
                             expectedVersion: version, now: now.addingTimeInterval(2))
        return state
    }

    private func withdrawn(_ source: SecondLookState, runID: UUID,
                           itemID: UUID, decision: Bool = false) throws -> SecondLookState {
        var state = try accepted(source, runID: runID, itemID: itemID)
        if decision {
            try state.requestAnother(runID: runID, itemID: itemID, actorID: peer,
                expectedVersion: 1, note: "Different angle", now: now.addingTimeInterval(3))
        }
        try state.withdraw(runID: runID, itemID: itemID, actorID: owner,
                           expectedVersion: 1, now: now.addingTimeInterval(4))
        return state
    }

    private func view(_ state: SecondLookState, revision: Int) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision, members: [owner, peer], state: state)
    }

    private func editRun(_ state: SecondLookState,
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
            XCTFail("A retained item lost version or review provenance", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    func testValidatedUnseededReferencesRejectCounterRollbackDecisionEraseAndRewrite() async throws {
        let (source, runID, itemID) = try base()
        let decided = try withdrawn(source, runID: runID, itemID: itemID, decision: true)
        let baseline = view(decided, revision: 1)
        try baseline.validate(for: owner)
        let rewrites: [SecondLookState] = [
            editRun(decided) { $0.revision += 1; $0.items[0].lastVersion = 0;
                $0.items[0].priorDecisions = [] },
            editRun(decided) { $0.revision += 1; $0.items[0].priorDecisions = [] },
            editRun(decided) { $0.revision += 1; $0.items[0].priorDecisions[0].note = "Rewritten" },
        ]
        for changed in rewrites {
            let incoming = view(changed, revision: 2)
            try incoming.validate(for: owner)
            let client = EvidenceHistoryClient(current: incoming, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            await expectInvalid(coordinator, references: [baseline])
            XCTAssertNil(coordinator.snapshot)
        }
    }

    func testValidatedUnseededReferencesRejectBackfilledWithdrawnDecision() async throws {
        let (source, runID, itemID) = try base()
        let undecided = try withdrawn(source, runID: runID, itemID: itemID)
        let decided = try withdrawn(source, runID: runID, itemID: itemID, decision: true)
        let incoming = view(editRun(decided) { $0.revision = undecided.runs[0].revision + 1 },
                            revision: 2)
        try view(undecided, revision: 1).validate(for: owner)
        try incoming.validate(for: owner)
        let client = EvidenceHistoryClient(current: incoming, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalid(coordinator, references: [view(undecided, revision: 1)])
        XCTAssertNil(coordinator.snapshot)
    }

    func testChronologicalReferencesCannotHideDecisionRewrite() async throws {
        let (source, runID, itemID) = try base()
        let decided = try withdrawn(source, runID: runID, itemID: itemID, decision: true)
        let first = view(decided, revision: 1)
        let rewritten = view(editRun(decided) {
            $0.revision += 1; $0.items[0].priorDecisions[0].note = "Rewritten"
        }, revision: 2)
        let restored = view(editRun(decided) { $0.revision += 2 }, revision: 3)
        try first.validate(for: owner)
        try rewritten.validate(for: owner)
        try restored.validate(for: owner)
        let client = EvidenceHistoryClient(current: restored, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalid(coordinator, references: [rewritten, first])
        XCTAssertNil(coordinator.snapshot)
    }

    func testSeededRefreshCannotEraseWithdrawnDecision() async throws {
        let (source, runID, itemID) = try base()
        let decided = try withdrawn(source, runID: runID, itemID: itemID, decision: true)
        let first = view(decided, revision: 1)
        let client = EvidenceHistoryClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let erased = view(editRun(decided) {
            $0.revision += 1; $0.items[0].priorDecisions = []
        }, revision: 2)
        try erased.validate(for: owner)
        await client.setCurrent(erased)
        await expectInvalid(coordinator)
        XCTAssertEqual(coordinator.snapshot, first)
    }

    func testCommandResponseCannotResetCounterAndExactRetryRecovers() async throws {
        let (source, runID, itemID) = try base()
        let withdrawnState = try withdrawn(source, runID: runID, itemID: itemID)
        let first = view(withdrawnState, revision: 0)
        let client = EvidenceHistoryClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let command: SharedCommand = .saveRoutine(definition: Routine(title: "Independent",
            items: [RoutineItem(title: "Coat")]), expectedDefinitionVersion: nil)
        let commandID = UUID()
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: commandID,
                                             expectedSpaceRevision: 0, command: command)
        let genuine = try SharedCommandProcessor.apply(envelope, to: first,
                                                       actorID: owner, now: now)
        let altered = view(editRun(genuine.snapshot.state) {
            $0.revision += 1; $0.items[0].lastVersion = 0
        }, revision: 1)
        try altered.validate(for: owner)
        await client.overrideNextCommand(with: altered)
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("A command response reset a retained evidence counter")
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

    #if DEBUG
    func testClosureArchiveCannotRewriteExistingReviewDecision() async throws {
        let (source, runID, itemID) = try base()
        var waiting = try accepted(source, runID: runID, itemID: itemID)
        try waiting.requestAnother(runID: runID, itemID: itemID, actorID: peer,
            expectedVersion: 1, note: "Original review", now: now.addingTimeInterval(3))
        let earlier = view(waiting, revision: 1)
        try earlier.validate(for: owner)
        var closed = waiting
        try closed.cancel(runID: runID, actorID: owner, now: now.addingTimeInterval(4))
        var archive = closed.archives[0]
        archive.items[0].decisions[0].note = "Rewritten at closure"
        let incoming = view(SecondLookState(routines: closed.routines,
            runs: closed.runs, archives: [archive]), revision: 2)
        try incoming.validate(for: owner)
        let client = EvidenceHistoryClient(current: incoming, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalid(coordinator, references: [earlier])
    }
    #endif

    #if DEBUG
    func testCurrentVersionCannotResurrectOrRewriteRetainedTimestamps() async throws {
        let (source, runID, itemID) = try base()
        let acceptedState = try accepted(source, runID: runID, itemID: itemID)
        let oldAccepted = view(acceptedState, revision: 1)
        try oldAccepted.validate(for: owner)
        let timestampChanges = [
            editRun(acceptedState) { $0.revision += 1;
                $0.items[0].submission?.preparedAt = now.addingTimeInterval(10) },
            editRun(acceptedState) { $0.revision += 1;
                $0.items[0].submission?.acceptedAt = now.addingTimeInterval(10) },
        ]
        for changed in timestampChanges {
            let incoming = view(changed, revision: 2)
            try incoming.validate(for: owner)
            let client = EvidenceHistoryClient(current: incoming, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            await expectInvalid(coordinator, references: [oldAccepted])
        }

        let removed = try withdrawn(source, runID: runID, itemID: itemID)
        let oldWithdrawn = view(removed, revision: 1)
        let resurrected = view(editRun(acceptedState) {
            $0.revision = removed.runs[0].revision + 1
        }, revision: 2)
        try oldWithdrawn.validate(for: owner)
        try resurrected.validate(for: owner)
        let client = EvidenceHistoryClient(current: resurrected, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalid(coordinator, references: [oldWithdrawn])
    }

    func testActualSendReviewWithdrawReplacementApprovalAndClosureStayValid() async throws {
        let (source, runID, itemID) = try base()
        let first = view(source, revision: 1)
        let client = EvidenceHistoryClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        var state = try accepted(source, runID: runID, itemID: itemID)
        var last = first
        func advance() async throws {
            let next = view(state, revision: last.revision + 1)
            try next.validate(for: owner)
            await client.setCurrent(next)
            let published = try await coordinator.refresh(validatingAgainst: [last])
            XCTAssertTrue(published)
            last = next
        }
        try await advance()
        try state.requestAnother(runID: runID, itemID: itemID, actorID: peer,
            expectedVersion: 1, note: "Different angle", now: now.addingTimeInterval(3))
        try await advance()
        try state.withdraw(runID: runID, itemID: itemID, actorID: owner,
            expectedVersion: 1, now: now.addingTimeInterval(4))
        try await advance()
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: owner,
            fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera,
            now: now.addingTimeInterval(5))
        let secondVersion = try state.beginSend(runID: runID, itemID: itemID, actorID: owner)
        try state.acceptSend(runID: runID, itemID: itemID, actorID: owner,
                             expectedVersion: secondVersion, now: now.addingTimeInterval(6))
        try await advance()
        try state.approve(runID: runID, itemID: itemID, actorID: peer,
                          expectedVersion: secondVersion, now: now.addingTimeInterval(7))
        try await advance()
        try state.setStandardChecked(runID: runID, itemID: state.runs[0].items[1].id,
                                     checked: true, actorID: owner,
                                     now: now.addingTimeInterval(8))
        try await advance()
        XCTAssertEqual(last.state.runs[0].outcome, .completed)
        XCTAssertEqual(last.state.archives[0].items[0].decisions.map(\.submissionVersion), [1, 2])
    }
    #endif

    func testWithdrawnTextHistorySettingsAndIndependentRunRemainValidInBothBuilds() async throws {
        let (source, runID, itemID) = try base()
        var state = try withdrawn(source, runID: runID, itemID: itemID, decision: true)
        let first = view(state, revision: 1)
        try first.validate(for: owner)
        let client = EvidenceHistoryClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        try state.updateRunSettings(runID: runID, actorID: owner,
            settings: RunSettings(reminders: ReminderPreferences(remindPerformer: true)))
        try state.setStandardChecked(runID: runID, itemID: state.runs[0].items[1].id,
                                     checked: true, actorID: owner, now: now)
        let next = view(state, revision: 2)
        try next.validate(for: owner)
        await client.setCurrent(next)
        let progressed = try await coordinator.refresh(validatingAgainst: [first])
        XCTAssertTrue(progressed)
        try state.cancel(runID: runID, actorID: owner, now: now.addingTimeInterval(5))
        _ = try state.startOneOff(title: "Independent", items: [RoutineItem(title: "Bag")],
            performerID: peer, reviewerID: owner, now: now.addingTimeInterval(6))
        let closed = view(state, revision: 4)
        try closed.validate(for: owner)
        await client.setCurrent(closed)
        let published = try await coordinator.refresh(validatingAgainst: [first, next])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, closed)
        XCTAssertEqual(closed.state.archives[0].items[0].decisions.count, 1)
    }
}
