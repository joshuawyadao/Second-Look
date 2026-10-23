import Foundation
import XCTest
@testable import SecondLookCore

private actor HistoryTransitionClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private let now: Date
    private var nextCommandOverride: SharedSnapshot?
    private var receipts: [UUID: SharedCommandResult] = [:]

    init(current: SharedSnapshot, actorID: UUID, now: Date) {
        self.current = current
        self.actorID = actorID
        self.now = now
    }

    func setCurrent(_ snapshot: SharedSnapshot) { current = snapshot }
    func overrideNextCommand(with snapshot: SharedSnapshot) { nextCommandOverride = snapshot }
    func currentSnapshot() -> SharedSnapshot { current }

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
        if let override = nextCommandOverride {
            nextCommandOverride = nil
            return SharedCommandResult(snapshot: override, createdID: result.createdID)
        }
        return result
    }
}

@MainActor
final class HistoryTransitionTests: XCTestCase {
    private let owner = UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "60000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "60000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var scope: SharedAccountScope {
        SharedAccountScope(backend: "history-test", accountID: owner, spaceID: space)
    }

    private func view(_ state: SecondLookState, revision: Int) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision,
                       members: [owner, peer], state: state)
    }

    private func history() throws -> (SecondLookState, UUID, UUID) {
        var state = SecondLookState()
        let openID = try state.startOneOff(title: "Open invented list", items: [
            RoutineItem(title: "Keys"), RoutineItem(title: "Wallet")
        ], performerID: owner, reviewerID: nil, now: now)
        let closedID = try state.startOneOff(title: "Closed invented list",
                                             items: [RoutineItem(title: "Door")],
                                             performerID: owner, reviewerID: nil, now: now)
        try state.cancel(runID: closedID, actorID: owner, now: now)
        XCTAssertEqual(state.archives.map(\.id), [closedID])
        try view(state, revision: 1).validate(for: owner)
        return (state, openID, closedID)
    }

    private func withoutOpenRun(_ state: SecondLookState, openID: UUID) -> SecondLookState {
        SecondLookState(routines: state.routines,
                        runs: state.runs.filter { $0.id != openID }, archives: state.archives)
    }

    private func withoutClosedHistory(_ state: SecondLookState, closedID: UUID) -> SecondLookState {
        SecondLookState(routines: state.routines,
                        runs: state.runs.filter { $0.id != closedID },
                        archives: state.archives.filter { $0.id != closedID })
    }

    private func rewrittenClosedHistory(_ state: SecondLookState, closedID: UUID) -> SecondLookState {
        var runs = state.runs
        var archives = state.archives
        runs[runs.firstIndex { $0.id == closedID }!].title = "Rewritten closed list"
        archives[archives.firstIndex { $0.id == closedID }!].title = "Rewritten closed list"
        return SecondLookState(routines: state.routines, runs: runs, archives: archives)
    }

    private func expectInvalidRefresh(_ coordinator: SharedStateCoordinator,
                                      references: [SharedSnapshot] = [],
                                      file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await coordinator.refresh(validatingAgainst: references)
            XCTFail("A higher revision erased or rewrote known history", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    func testUnseededReferencesRejectRunOrArchiveLossAndClosedRewrite() async throws {
        let (state, openID, closedID) = try history()
        let trusted = view(state, revision: 1)
        let candidates = [withoutOpenRun(state, openID: openID),
                          withoutClosedHistory(state, closedID: closedID),
                          rewrittenClosedHistory(state, closedID: closedID)]
        for changed in candidates {
            let incoming = view(changed, revision: 2)
            try incoming.validate(for: owner) // Each view is structurally valid on its own.
            let client = HistoryTransitionClient(current: incoming, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            await expectInvalidRefresh(coordinator, references: [trusted])
            XCTAssertNil(coordinator.snapshot)
            XCTAssertEqual(coordinator.scope, scope)
        }
    }

    func testChronologicalReferencesRejectTransientHistoryLossEvenWhenFetchRestoresIt() async throws {
        let (state, openID, _) = try history()
        let first = view(state, revision: 1)
        let lost = view(withoutOpenRun(state, openID: openID), revision: 2)
        let restored = view(state, revision: 3)
        let client = HistoryTransitionClient(current: restored, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalidRefresh(coordinator, references: [lost, first])
        XCTAssertNil(coordinator.snapshot)
    }

    func testSeededRefreshRejectsHistoryRewriteWithoutReferences() async throws {
        let (state, _, closedID) = try history()
        let baseline = view(state, revision: 1)
        let client = HistoryTransitionClient(current: baseline, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let rewritten = view(rewrittenClosedHistory(state, closedID: closedID), revision: 2)
        try rewritten.validate(for: owner)
        await client.setCurrent(rewritten)
        await expectInvalidRefresh(coordinator)
        XCTAssertEqual(coordinator.snapshot, baseline)
    }

    func testCommandResponseCannotEraseHistoryAndExactRetryRecoversReceipt() async throws {
        let (state, _, closedID) = try history()
        let baseline = view(state, revision: 0)
        let client = HistoryTransitionClient(current: baseline, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let command: SharedCommand = .saveRoutine(definition: Routine(title: "New invented routine",
            items: [RoutineItem(title: "Coat")]), expectedDefinitionVersion: nil)
        let commandID = UUID()
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: commandID,
                                             expectedSpaceRevision: 0, command: command)
        let genuine = try SharedCommandProcessor.apply(envelope, to: baseline,
                                                       actorID: owner, now: now)
        let erased = view(withoutClosedHistory(genuine.snapshot.state, closedID: closedID), revision: 1)
        try erased.validate(for: owner)
        await client.overrideNextCommand(with: erased)
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("A command response erased a closed record")
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

        let laterErasure = view(withoutOpenRun(genuine.snapshot.state,
                                               openID: state.runs.first { $0.isOpen }!.id), revision: 2)
        await client.setCurrent(laterErasure)
        await expectInvalidRefresh(coordinator)
        XCTAssertEqual(coordinator.snapshot, genuine.snapshot)
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
    }

    func testOpenProgressClosureNewRunsAndRoutineDeletionRemainValid() async throws {
        let (baseState, openID, closedID) = try history()
        var withRoutine = baseState
        try withRoutine.saveRoutine(Routine(title: "Removable routine",
                                            items: [RoutineItem(title: "Umbrella")]))
        let first = view(withRoutine, revision: 1)
        let client = HistoryTransitionClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)

        var progress = baseState // Routine deletion and an open-run edit are allowed.
        let open = progress.runs.first { $0.id == openID }!
        try progress.setStandardChecked(runID: openID, itemID: open.items[0].id,
                                        checked: true, actorID: owner, now: now)
        let second = view(progress, revision: 3)
        await client.setCurrent(second)
        let progressed = try await coordinator.refresh(validatingAgainst: [first])
        XCTAssertTrue(progressed)
        XCTAssertEqual(coordinator.snapshot, second)

        try progress.setStandardChecked(runID: openID, itemID: open.items[1].id,
                                        checked: true, actorID: owner, now: now)
        let newID = try progress.startOneOff(title: "Another invented list",
            items: [RoutineItem(title: "Lights")], performerID: owner, reviewerID: nil, now: now)
        let third = view(progress, revision: 5)
        await client.setCurrent(third)
        let closedAndAdded = try await coordinator.refresh(validatingAgainst: [second, first])
        XCTAssertTrue(closedAndAdded)
        XCTAssertEqual(coordinator.snapshot, third)
        XCTAssertTrue(third.state.archives.contains { $0.id == openID })
        XCTAssertTrue(third.state.archives.contains { $0.id == closedID })
        XCTAssertTrue(third.state.runs.contains { $0.id == newID })
    }
}
