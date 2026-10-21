import Foundation
import XCTest
@testable import SecondLookCore

private actor RunRoleClient: SharedStateClient {
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
final class RunRoleTransitionTests: XCTestCase {
    private let owner = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var scope: SharedAccountScope {
        SharedAccountScope(backend: "roles-test", accountID: owner, spaceID: space)
    }

    private func state(reviewer: UUID?) throws -> (SecondLookState, UUID) {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Invented run", items: [
            RoutineItem(title: "Keys"), RoutineItem(title: "Wallet")
        ], performerID: owner, reviewerID: reviewer, now: now)
        return (state, runID)
    }

    private func view(_ state: SecondLookState, revision: Int) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision,
                       members: [owner, peer], state: state)
    }

    private func changedRoles(_ state: SecondLookState,
                              performer: UUID, reviewer: UUID?) -> SecondLookState {
        var run = state.runs[0]
        run.performerID = performer
        run.reviewerID = reviewer
        return SecondLookState(routines: state.routines, runs: [run], archives: state.archives)
    }

    private func expectInvalidRefresh(_ coordinator: SharedStateCoordinator,
                                      references: [SharedSnapshot] = [],
                                      file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await coordinator.refresh(validatingAgainst: references)
            XCTFail("A retained run changed its assigned roles", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    func testUnseededReferencesRejectOpenRoleSwapReviewerDropAndReassignment() async throws {
        let (original, _) = try state(reviewer: peer)
        let baseline = view(original, revision: 1)
        let changes = [changedRoles(original, performer: peer, reviewer: owner),
                       changedRoles(original, performer: owner, reviewer: nil)]
        for changed in changes {
            let incoming = view(changed, revision: 2)
            try incoming.validate(for: owner)
            let client = RunRoleClient(current: incoming, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            await expectInvalidRefresh(coordinator, references: [baseline])
            XCTAssertNil(coordinator.snapshot)
        }
        let (unassigned, _) = try state(reviewer: nil)
        let addedReviewer = view(changedRoles(unassigned, performer: owner, reviewer: peer), revision: 2)
        try addedReviewer.validate(for: owner)
        let client = RunRoleClient(current: addedReviewer, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalidRefresh(coordinator, references: [view(unassigned, revision: 1)])
        XCTAssertNil(coordinator.snapshot)
    }

    func testChronologicalReferencesCannotHideTemporaryRoleSwap() async throws {
        let (original, _) = try state(reviewer: peer)
        let first = view(original, revision: 1)
        let swapped = view(changedRoles(original, performer: peer, reviewer: owner), revision: 2)
        let restored = view(original, revision: 3)
        let client = RunRoleClient(current: restored, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalidRefresh(coordinator, references: [swapped, first])
        XCTAssertNil(coordinator.snapshot)
    }

    func testClosingRunCannotSwapAssignedRolesEvenWithMatchingArchive() async throws {
        let (original, runID) = try state(reviewer: peer)
        let first = view(original, revision: 1)
        var closed = original
        try closed.cancel(runID: runID, actorID: owner, now: now)
        var run = closed.runs[0]
        var archive = closed.archives[0]
        run.performerID = peer
        run.reviewerID = owner
        archive.performerID = peer
        archive.reviewerID = owner
        let changed = SecondLookState(runs: [run], archives: [archive])
        let incoming = view(changed, revision: 2)
        try incoming.validate(for: owner)
        let client = RunRoleClient(current: incoming, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalidRefresh(coordinator, references: [first])
        XCTAssertNil(coordinator.snapshot)
    }

    func testSeededRefreshCannotReassignReviewerWhileRunStaysOpen() async throws {
        let (original, _) = try state(reviewer: peer)
        let first = view(original, revision: 1)
        let client = RunRoleClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let dropped = view(changedRoles(original, performer: owner, reviewer: nil), revision: 2)
        try dropped.validate(for: owner)
        await client.setCurrent(dropped)
        await expectInvalidRefresh(coordinator)
        XCTAssertEqual(coordinator.snapshot, first)
    }

    func testCommandResponseRoleSwapKeepsRequestForExactGenuineRetry() async throws {
        let (original, _) = try state(reviewer: peer)
        let baseline = view(original, revision: 0)
        let client = RunRoleClient(current: baseline, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let command: SharedCommand = .saveRoutine(definition: Routine(title: "Invented routine",
            items: [RoutineItem(title: "Coat")]), expectedDefinitionVersion: nil)
        let commandID = UUID()
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: commandID,
                                             expectedSpaceRevision: 0, command: command)
        let genuine = try SharedCommandProcessor.apply(envelope, to: baseline,
                                                       actorID: owner, now: now)
        let swapped = view(changedRoles(genuine.snapshot.state,
                                        performer: peer, reviewer: owner), revision: 1)
        try swapped.validate(for: owner)
        await client.overrideNextCommand(with: swapped)
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("A command response swapped retained run roles")
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

    func testOpenProgressClosureAndNewRunWithIndependentRolesRemainValid() async throws {
        let (original, runID) = try state(reviewer: peer)
        let first = view(original, revision: 1)
        let client = RunRoleClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)

        var progress = original
        let firstItem = progress.runs[0].items[0].id
        let secondItem = progress.runs[0].items[1].id
        try progress.setStandardChecked(runID: runID, itemID: firstItem,
                                        checked: true, actorID: owner, now: now)
        let second = view(progress, revision: 2)
        await client.setCurrent(second)
        let progressed = try await coordinator.refresh(validatingAgainst: [first])
        XCTAssertTrue(progressed)

        try progress.setStandardChecked(runID: runID, itemID: secondItem,
                                        checked: true, actorID: owner, now: now)
        let newID = try progress.startOneOff(title: "New independent run",
            items: [RoutineItem(title: "Lights")], performerID: peer, reviewerID: owner, now: now)
        let third = view(progress, revision: 3)
        await client.setCurrent(third)
        let published = try await coordinator.refresh(validatingAgainst: [first, second])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, third)
        XCTAssertEqual(third.state.runs.first { $0.id == runID }?.performerID, owner)
        XCTAssertEqual(third.state.archives.first { $0.id == runID }?.reviewerID, peer)
        XCTAssertEqual(third.state.runs.first { $0.id == newID }?.performerID, peer)
    }
}
