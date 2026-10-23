import Foundation
import XCTest
@testable import SecondLookCore

private actor MembershipTransitionClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private var returnedCommandOverride: SharedSnapshot?
    private var receipts: [UUID: SharedCommandResult] = [:]

    init(current: SharedSnapshot, actorID: UUID) {
        self.current = current
        self.actorID = actorID
    }

    func setCurrent(_ snapshot: SharedSnapshot) { current = snapshot }
    func overrideNextCommand(with snapshot: SharedSnapshot) { returnedCommandOverride = snapshot }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        guard current.spaceID == spaceID else { throw SharedStateFailure.scopeMismatch }
        return current
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        if let receipt = receipts[envelope.commandID] { return receipt }
        let result = try SharedCommandProcessor.apply(envelope, to: current, actorID: actorID,
                                                      now: Date(timeIntervalSince1970: 1_700_000_000))
        current = result.snapshot
        receipts[envelope.commandID] = result
        if let returnedCommandOverride {
            self.returnedCommandOverride = nil
            return SharedCommandResult(snapshot: returnedCommandOverride, createdID: result.createdID)
        }
        return result
    }
}

@MainActor
final class MembershipTransitionTests: XCTestCase {
    private let owner = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
    private let replacement = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    private let space = UUID(uuidString: "30000000-0000-0000-0000-000000000004")!

    private var scope: SharedAccountScope {
        SharedAccountScope(backend: "membership-test", accountID: owner, spaceID: space)
    }

    private func view(_ revision: Int, _ members: [UUID]) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision, members: members, state: SecondLookState())
    }

    private func expectInvalidRefresh(_ coordinator: SharedStateCoordinator,
                                      references: [SharedSnapshot],
                                      file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await coordinator.refresh(validatingAgainst: references)
            XCTFail("Invalid membership transition was published", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    func testUnseededTrustedPairCannotShrinkReplaceOrReorderAtHigherRevision() async throws {
        let baseline = view(1, [owner, peer])
        for changedMembers in [[owner], [owner, replacement], [peer, owner]] {
            let incoming = view(2, changedMembers)
            try incoming.validate(for: owner) // The transition, not basic shape, is the rejection.
            let client = MembershipTransitionClient(current: incoming, actorID: owner)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            await expectInvalidRefresh(coordinator, references: [baseline])
            XCTAssertNil(coordinator.snapshot)
            XCTAssertEqual(coordinator.scope, scope)
        }
    }

    func testChronologicalTrustedReferencesCannotHideLossBehindLaterFetch() async throws {
        let first = view(1, [owner, peer])
        let contradictory = view(2, [owner])
        let latest = view(3, [owner, peer])
        let client = MembershipTransitionClient(current: latest, actorID: owner)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalidRefresh(coordinator, references: [contradictory, first])
        XCTAssertNil(coordinator.snapshot)
    }

    func testFirstJoinCannotReplaceTheOwner() async throws {
        let first = view(1, [owner])
        let inverted = view(2, [peer, owner])
        try inverted.validate(for: owner)
        let client = MembershipTransitionClient(current: inverted, actorID: owner)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalidRefresh(coordinator, references: [first])
        XCTAssertNil(coordinator.snapshot)
    }

    func testSeededRefreshCannotChangeOwnerOrDropPeer() async throws {
        let baseline = view(1, [owner, peer])
        let client = MembershipTransitionClient(current: baseline, actorID: owner)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        for changedMembers in [[peer, owner], [owner]] {
            let incoming = view(2, changedMembers)
            try incoming.validate(for: owner)
            await client.setCurrent(incoming)
            await expectInvalidRefresh(coordinator, references: [])
            XCTAssertEqual(coordinator.snapshot, baseline)
        }
    }

    func testCommandResponseCannotDropPeerWhileRetainingActiveActor() async throws {
        let baseline = view(0, [owner, peer])
        let client = MembershipTransitionClient(current: baseline, actorID: owner)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let command: SharedCommand = .saveRoutine(definition: Routine(title: "Invented task",
            items: [RoutineItem(title: "Check key")]), expectedDefinitionVersion: nil)
        let commandID = UUID()
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: commandID,
                                             expectedSpaceRevision: 0, command: command)
        let genuine = try SharedCommandProcessor.apply(envelope, to: baseline, actorID: owner,
                                                       now: Date(timeIntervalSince1970: 1_700_000_000))
        var dropped = genuine.snapshot
        dropped.members = [owner]
        try dropped.validate(for: owner)
        await client.overrideNextCommand(with: dropped)

        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("A command response dropped a joined member")
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

    func testOwnerFirstJoinAndStablePairedMembershipRemainValid() async throws {
        let first = view(1, [owner])
        let joined = view(2, [owner, peer])
        let save = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: joined.revision,
            command: .saveRoutine(definition: Routine(title: "Stable paired write",
                items: [RoutineItem(title: "Keys")]), expectedDefinitionVersion: nil))
        let stable = try SharedCommandProcessor.apply(save, to: joined, actorID: owner,
            now: Date(timeIntervalSince1970: 1_700_000_000)).snapshot
        let client = MembershipTransitionClient(current: stable, actorID: owner)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let published = try await coordinator.refresh(validatingAgainst: [joined, first])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, stable)
        let unchanged = try await coordinator.refresh(validatingAgainst: [joined, stable])
        XCTAssertFalse(unchanged)

        let seededCoordinator = SharedStateCoordinator()
        await client.setCurrent(first)
        seededCoordinator.beginSession(scope: scope, client: client)
        let firstPublished = try await seededCoordinator.refresh()
        XCTAssertTrue(firstPublished)
        await client.setCurrent(joined)
        let joinedPublished = try await seededCoordinator.refresh()
        XCTAssertTrue(joinedPublished)
        XCTAssertEqual(seededCoordinator.snapshot, joined)
    }
}
