import Foundation
import XCTest
@testable import SecondLookCore

private actor AdmissionClient: SharedStateClient {
    private(set) var fetchCount = 0
    var current: SharedSnapshot
    let actorID: UUID

    init(_ current: SharedSnapshot, actorID: UUID) {
        self.current = current
        self.actorID = actorID
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        fetchCount += 1
        return current
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        let result = try SharedCommandProcessor.apply(envelope, to: current,
            actorID: actorID, now: Date(timeIntervalSince1970: 1_700_000_000))
        current = result.snapshot
        return result
    }
}

private actor RateLimitedClient: SharedStateClient {
    let view: SharedSnapshot
    init(_ view: SharedSnapshot) { self.view = view }
    func fetch(spaceID: UUID) async throws -> SharedSnapshot { view }
    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        throw SharedStateFailure.rateLimited
    }
}

private actor LostReplyThenRateLimitClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private var originalEnvelope: SharedCommandEnvelope?
    private var committed: SharedCommandResult?
    private var attempts = 0

    init(_ view: SharedSnapshot, actorID: UUID) {
        current = view
        self.actorID = actorID
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot { current }
    func currentSnapshot() -> SharedSnapshot { current }
    func attemptCount() -> Int { attempts }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        attempts += 1
        if let originalEnvelope {
            guard envelope == originalEnvelope, let committed else {
                throw SharedStateFailure.invalidResponse
            }
            if attempts == 2 { throw SharedStateFailure.rateLimited }
            return committed
        }
        let result = try SharedCommandProcessor.apply(envelope, to: current,
            actorID: actorID, now: Date(timeIntervalSince1970: 1_700_000_000))
        originalEnvelope = envelope
        current = result.snapshot
        committed = result
        throw SharedStateFailure.serviceUnavailable
    }
}

private actor ConcurrentRateLimitClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private var attempts = 0
    private var firstEnvelope: SharedCommandEnvelope?
    private var firstResult: CheckedContinuation<SharedCommandResult, any Error>?
    private var firstReady: CheckedContinuation<Void, Never>?

    init(_ view: SharedSnapshot, actorID: UUID) {
        current = view
        self.actorID = actorID
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot { current }
    func currentSnapshot() -> SharedSnapshot { current }

    func waitForFirst() async {
        if firstEnvelope != nil { return }
        await withCheckedContinuation { firstReady = $0 }
    }

    func completeFirst() throws {
        guard let firstEnvelope, let firstResult else { throw SharedStateFailure.invalidResponse }
        let result = try SharedCommandProcessor.apply(firstEnvelope, to: current,
            actorID: actorID, now: Date(timeIntervalSince1970: 1_700_000_000))
        current = result.snapshot
        self.firstResult = nil
        firstResult.resume(returning: result)
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        attempts += 1
        if attempts == 1 {
            firstEnvelope = envelope
            firstReady?.resume()
            firstReady = nil
            return try await withCheckedThrowingContinuation { firstResult = $0 }
        }
        guard envelope == firstEnvelope else { throw SharedStateFailure.invalidResponse }
        throw SharedStateFailure.rateLimited
    }
}

@MainActor
final class SharedRefreshAdmissionTests: XCTestCase {
    private let account = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!

    private var scope: SharedAccountScope {
        SharedAccountScope(backend: "local-admission", accountID: account, spaceID: space)
    }

    private func snapshot(_ title: String = "Routine", revision: Int = 1) throws -> SharedSnapshot {
        var state = SecondLookState()
        try state.saveRoutine(Routine(title: title, items: [RoutineItem(title: "Check")]))
        return SharedSnapshot(spaceID: space, revision: revision, members: [account, peer], state: state)
    }

    private func validator(revision: Int = 1, spaceID: UUID? = nil) -> SharedSnapshotValidator {
        SharedSnapshotValidator(spaceID: spaceID ?? space, revision: revision,
            token: String(repeating: "a", count: 64))
    }

    func testDirectAdmissionDoesNotFetchAndRejectsGenerationAndScope() async throws {
        let view = try snapshot()
        let client = AdmissionClient(view, actorID: account)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let generation = coordinator.generation
        XCTAssertTrue(try coordinator.acceptFetchedSnapshot(view, expectedGeneration: generation))
        let fetchCount = await client.fetchCount
        XCTAssertEqual(fetchCount, 0)
        XCTAssertFalse(try coordinator.acceptFetchedSnapshot(view, expectedGeneration: generation))
        XCTAssertThrowsError(try coordinator.acceptFetchedSnapshot(view,
            expectedGeneration: generation &+ 1)) { error in
            XCTAssertEqual(error as? SharedStateFailure, .sessionChanged)
        }
        var wrongScope = view
        wrongScope.spaceID = UUID()
        XCTAssertThrowsError(try coordinator.acceptFetchedSnapshot(wrongScope,
            expectedGeneration: generation)) { error in
            XCTAssertEqual(error as? SharedStateFailure, .scopeMismatch)
        }
        XCTAssertNil(coordinator.snapshot)
    }

    func testDirectAdmissionPreservesStaleConflictAndReferenceChecks() throws {
        let original = try snapshot()
        let changed = try snapshot("Changed")
        let client = AdmissionClient(original, actorID: account)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let generation = coordinator.generation
        XCTAssertThrowsError(try coordinator.acceptFetchedSnapshot(changed,
            expectedGeneration: generation, validatingAgainst: [original])) { error in
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertThrowsError(try coordinator.acceptFetchedSnapshot(original,
            expectedGeneration: generation, validatingAgainst: [try snapshot(revision: 2)])) { error in
            XCTAssertEqual(error as? SharedStateFailure, .staleState)
        }
        XCTAssertThrowsError(try coordinator.acceptFetchedSnapshot(original,
            expectedGeneration: generation, validatingAgainst: [original, changed])) { error in
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertNil(coordinator.snapshot)
    }

    func testUnchangedCannotSeedRestoreOrConsumeReceipt() async throws {
        let view = try snapshot()
        let client = AdmissionClient(view, actorID: account)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let generation = coordinator.generation
        let token = validator()
        XCTAssertThrowsError(try coordinator.acceptUnchanged(token,
            expectedValidator: token, expectedGeneration: generation)) { error in
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertNil(coordinator.snapshot)
        XCTAssertTrue(try coordinator.acceptFetchedSnapshot(view, expectedGeneration: generation))
        let command = SharedCommand.startOneOff(title: "Run", items: [RoutineItem(title: "Do")], settings: .init())
        let commandID = UUID()
        _ = try await coordinator.execute(command, commandID: commandID)
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
        let currentToken = validator(revision: coordinator.snapshot!.revision)
        XCTAssertFalse(try coordinator.acceptUnchanged(currentToken,
            expectedValidator: currentToken, expectedGeneration: generation,
            validatingAgainst: [coordinator.snapshot!]))
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
        XCTAssertThrowsError(try coordinator.acceptUnchanged(currentToken,
            expectedValidator: token, expectedGeneration: generation))
        XCTAssertThrowsError(try coordinator.acceptUnchanged(currentToken,
            expectedValidator: currentToken, expectedGeneration: generation,
            validatingAgainst: [view]))
        coordinator.suspendSession()
        XCTAssertThrowsError(try coordinator.acceptUnchanged(currentToken,
            expectedValidator: currentToken, expectedGeneration: generation)) { error in
            XCTAssertEqual(error as? SharedStateFailure, .sessionChanged)
        }
        XCTAssertNil(coordinator.snapshot)
    }

    func testUnchangedRequiresExactValidTokenAndRevision() throws {
        let view = try snapshot()
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: AdmissionClient(view, actorID: account))
        let generation = coordinator.generation
        _ = try coordinator.acceptFetchedSnapshot(view, expectedGeneration: generation)
        let good = validator()
        let badHash = SharedSnapshotValidator(spaceID: space, revision: 1, token: "bad")
        let otherHash = SharedSnapshotValidator(spaceID: space, revision: 1,
            token: String(repeating: "b", count: 64))
        for pair in [(badHash, badHash), (otherHash, good),
                     (validator(revision: 2), validator(revision: 2)),
                     (validator(spaceID: UUID()), validator(spaceID: UUID()))] {
            XCTAssertThrowsError(try coordinator.acceptUnchanged(pair.0,
                expectedValidator: pair.1, expectedGeneration: generation))
        }
        XCTAssertEqual(coordinator.snapshot, view)
    }

    func testFreshRateLimitKeepsExactRequestForExplicitRetry() async throws {
        let view = try snapshot()
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: RateLimitedClient(view))
        _ = try coordinator.acceptFetchedSnapshot(view, expectedGeneration: coordinator.generation)
        let commandID = UUID()
        do {
            _ = try await coordinator.execute(.startOneOff(title: "Run",
                items: [RoutineItem(title: "Do")], settings: .init()), commandID: commandID)
            XCTFail("Rate-limited command unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .rateLimited)
        }
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        XCTAssertEqual(coordinator.snapshot, view)
    }

    func testLostCreationReplyThenRateLimitRecoversOneEffectWithSameID() async throws {
        let view = try snapshot()
        let client = LostReplyThenRateLimitClient(view, actorID: account)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try coordinator.acceptFetchedSnapshot(view, expectedGeneration: coordinator.generation)
        let command = SharedCommand.startOneOff(title: "Run", items: [RoutineItem(title: "Do")], settings: .init())
        let commandID = UUID()
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("Lost reply unexpectedly returned")
        }
        catch { XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable) }
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("Rate-limited retry unexpectedly returned")
        }
        catch { XCTAssertEqual(error as? SharedStateFailure, .rateLimited) }
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        let createdID = try await coordinator.execute(command, commandID: commandID)
        XCTAssertEqual(createdID, coordinator.snapshot?.state.runs.first?.id)
        XCTAssertEqual(coordinator.snapshot?.state.runs.count, 1)
        let server = await client.currentSnapshot()
        let attempts = await client.attemptCount()
        XCTAssertEqual(server.state.runs.count, 1)
        XCTAssertEqual(attempts, 3)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: commandID))
    }

    func testOverlappingRateLimitCannotDiscardFirstAttempt() async throws {
        let view = try snapshot()
        let client = ConcurrentRateLimitClient(view, actorID: account)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        _ = try coordinator.acceptFetchedSnapshot(view, expectedGeneration: coordinator.generation)
        let command = SharedCommand.startOneOff(title: "Run", items: [RoutineItem(title: "Do")], settings: .init())
        let commandID = UUID()
        let first = Task { try await coordinator.execute(command, commandID: commandID) }
        await client.waitForFirst()
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("Overlapping request unexpectedly returned")
        }
        catch { XCTAssertEqual(error as? SharedStateFailure, .rateLimited) }
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        try await client.completeFirst()
        let createdID = try await first.value
        XCTAssertEqual(createdID, coordinator.snapshot?.state.runs.first?.id)
        let server = await client.currentSnapshot()
        XCTAssertEqual(server.state.runs.count, 1)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: commandID))
    }
}
