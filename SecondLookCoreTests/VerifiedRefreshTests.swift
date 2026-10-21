import Foundation
import XCTest
@testable import SecondLookCore

private actor VerifiedRefreshClient: SharedStateClient {
    private var current: SharedSnapshot
    private var queuedFetches: [SharedSnapshot] = []
    private var receipts: [UUID: (SharedCommandEnvelope, SharedCommandResult)] = [:]
    private var loseNextReply = false
    private let actorID: UUID
    private let now: Date

    init(current: SharedSnapshot, actorID: UUID, now: Date) {
        self.current = current
        self.actorID = actorID
        self.now = now
    }

    func queueFetch(_ snapshot: SharedSnapshot) { queuedFetches.append(snapshot) }
    func setCurrent(_ snapshot: SharedSnapshot) { current = snapshot }
    func dropNextReply() { loseNextReply = true }
    func currentSnapshot() -> SharedSnapshot { current }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        guard current.spaceID == spaceID else { throw SharedStateFailure.scopeMismatch }
        return queuedFetches.isEmpty ? current : queuedFetches.removeFirst()
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        if let receipt = receipts[envelope.commandID] {
            guard envelope == receipt.0 else { throw SharedStateFailure.invalidResponse }
            return SharedCommandResult(snapshot: current, createdID: receipt.1.createdID)
        }
        let result = try SharedCommandProcessor.apply(envelope, to: current, actorID: actorID, now: now)
        current = result.snapshot
        receipts[envelope.commandID] = (envelope, result)
        if loseNextReply {
            loseNextReply = false
            throw SharedStateFailure.serviceUnavailable
        }
        return result
    }
}

@MainActor
final class VerifiedRefreshTests: XCTestCase {
    private let account = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private let outsider = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
    private let space = UUID(uuidString: "20000000-0000-0000-0000-000000000004")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var scope: SharedAccountScope {
        SharedAccountScope(backend: "verified-local-test", accountID: account, spaceID: space)
    }

    private func snapshot(_ title: String, revision: Int = 1) throws -> SharedSnapshot {
        var state = SecondLookState()
        try state.saveRoutine(Routine(title: title, items: [RoutineItem(title: "Invented task")]))
        return SharedSnapshot(spaceID: space, revision: revision,
                              members: [account, peer], state: state)
    }

    private func expectRefreshFailure(_ expected: SharedStateFailure,
                                      from coordinator: SharedStateCoordinator,
                                      references: [SharedSnapshot],
                                      file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await coordinator.refresh(validatingAgainst: references)
            XCTFail("Conflicting verified refresh was published", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, expected, file: file, line: line)
        }
    }

    func testUnseededEqualRevisionConflictRejectsThenGenuineRefreshAndWriteRecover() async throws {
        let membership = try snapshot("Original")
        let changed = try snapshot("Altered")
        let client = VerifiedRefreshClient(current: membership, actorID: account, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await client.queueFetch(changed)
        await expectRefreshFailure(.invalidResponse, from: coordinator, references: [membership])
        XCTAssertNil(coordinator.snapshot)
        XCTAssertEqual(coordinator.scope, scope)

        let recovered = try await coordinator.refresh(validatingAgainst: [membership])
        XCTAssertTrue(recovered)
        XCTAssertEqual(coordinator.snapshot, membership)
        let createdID = try await coordinator.execute(.startOneOff(title: "Invented exit",
            items: [RoutineItem(title: "Keys")], settings: .init()))
        XCTAssertNotNil(createdID)
        XCTAssertEqual(coordinator.snapshot?.revision, 2)
        XCTAssertEqual(coordinator.snapshot?.state.runs.first?.id, createdID)
    }

    func testMembershipAndVisibleReferencesBothGuardSeededView() async throws {
        let visible = try snapshot("Visible")
        let changed = try snapshot("Altered")
        let client = VerifiedRefreshClient(current: visible, actorID: account, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        await client.queueFetch(changed)
        await expectRefreshFailure(.invalidResponse, from: coordinator, references: [changed, visible])
        XCTAssertEqual(coordinator.snapshot, visible)
        await client.queueFetch(changed)
        await expectRefreshFailure(.invalidResponse, from: coordinator, references: [visible])
        XCTAssertEqual(coordinator.snapshot, visible)
        let unchanged = try await coordinator.refresh(validatingAgainst: [visible, visible])
        XCTAssertFalse(unchanged)
    }

    func testWrongScopeAccountAndStaleReferenceLeaveCoordinatorUnchanged() async throws {
        let original = try snapshot("Original")
        let newer = try snapshot("Original", revision: 2)
        let client = VerifiedRefreshClient(current: original, actorID: account, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        var wrongSpace = original
        wrongSpace.spaceID = UUID()
        await expectRefreshFailure(.invalidResponse, from: coordinator, references: [wrongSpace])
        var wrongAccount = original
        wrongAccount.members = [peer, outsider]
        await expectRefreshFailure(.invalidResponse, from: coordinator, references: [wrongAccount])
        await expectRefreshFailure(.staleState, from: coordinator, references: [newer])
        XCTAssertNil(coordinator.snapshot)
        XCTAssertEqual(coordinator.scope, scope)

        await client.setCurrent(newer)
        let recovered = try await coordinator.refresh(validatingAgainst: [newer])
        XCTAssertTrue(recovered)
        XCTAssertEqual(coordinator.snapshot, newer)
    }

    func testMatchingReferencesAllowEqualAndHigherViewsButContradictoryOnesDoNot() async throws {
        let base = try snapshot("Original")
        let conflicting = try snapshot("Altered")
        let higher = try snapshot("Original", revision: 2)
        let client = VerifiedRefreshClient(current: higher, actorID: account, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectRefreshFailure(.invalidResponse, from: coordinator, references: [base, conflicting])
        XCTAssertNil(coordinator.snapshot)
        let published = try await coordinator.refresh(validatingAgainst: [base, base])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, higher)
        let unchanged = try await coordinator.refresh(validatingAgainst: [higher])
        XCTAssertFalse(unchanged)
    }

    func testRejectedRefreshRetainsUnconfirmedActionAndConfirmedReceipt() async throws {
        let base = try snapshot("Original", revision: 0)
        let changed = try snapshot("Altered", revision: 0)
        let client = VerifiedRefreshClient(current: base, actorID: account, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let command: SharedCommand = .startOneOff(title: "Invented exit",
            items: [RoutineItem(title: "Keys")], settings: .init())
        let commandID = UUID()
        await client.dropNextReply()
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("Synthetic lost reply must leave an unconfirmed action")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable)
        }
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        XCTAssertEqual(coordinator.snapshot, base)
        let committed = await client.currentSnapshot()
        await client.queueFetch(changed)
        await expectRefreshFailure(.invalidResponse, from: coordinator, references: [base])
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        XCTAssertEqual(coordinator.snapshot, base)

        let recovered = try await coordinator.refresh(validatingAgainst: [committed])
        XCTAssertTrue(recovered)
        let createdID = try await coordinator.execute(command, commandID: commandID)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: commandID))
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
        await client.queueFetch(base)
        await expectRefreshFailure(.staleState, from: coordinator, references: [committed])
        XCTAssertEqual(coordinator.snapshot, committed)
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
        XCTAssertEqual(coordinator.takeConfirmedReceipt(commandID: commandID, command: command)?.createdID,
                       createdID)
    }
}
