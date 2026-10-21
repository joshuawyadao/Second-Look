import Foundation
import XCTest
@testable import SecondLookCore

private actor KnownResultClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private let now: Date
    private var wrong: SharedCommandResult?
    private var receipt: SharedCommandResult?
    private var held = false
    private var compressCreation = false
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    init(_ snapshot: SharedSnapshot, actorID: UUID, now: Date) {
        current = snapshot
        self.actorID = actorID
        self.now = now
    }

    func replyOnce(with result: SharedCommandResult) { wrong = result }
    func holdReply() { held = true }
    func compressNextCreation() { compressCreation = true }
    func waitUntilReplyHeld() async {
        if release != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func releaseReply() {
        release?.resume()
        release = nil
    }
    func setCurrent(_ snapshot: SharedSnapshot) { current = snapshot }
    func fetch(spaceID: UUID) async throws -> SharedSnapshot { current }
    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        if let receipt { return receipt }
        let actual = try SharedCommandProcessor.apply(envelope, to: current,
                                                      actorID: actorID, now: now)
        current = actual.snapshot
        receipt = actual
        if compressCreation {
            compressCreation = false
            var state = actual.snapshot.state
            let oldRun = state.runs[0]
            try state.setStandardChecked(runID: oldRun.id, itemID: oldRun.items[0].id,
                checked: true, actorID: actorID, now: now)
            wrong = SharedCommandResult(snapshot: SharedSnapshot(spaceID: actual.snapshot.spaceID,
                revision: actual.snapshot.revision, members: actual.snapshot.members, state: state),
                createdID: actual.createdID)
        }
        if held {
            held = false
            await withCheckedContinuation { continuation in
                release = continuation
                started?.resume()
                started = nil
            }
        }
        if let wrong {
            self.wrong = nil
            return wrong
        }
        return actual
    }
}

@MainActor
final class KnownResultAdmissionTests: XCTestCase {
    private let owner = UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "AA000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "AA000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func initial() throws -> SharedSnapshot {
        var state = SecondLookState()
        _ = try state.startOneOff(title: "Packing", items: [
            RoutineItem(title: "Keys"), RoutineItem(title: "Wallet")
        ], performerID: owner, reviewerID: peer, now: now)
        return SharedSnapshot(spaceID: space, revision: 1, members: [owner, peer], state: state)
    }

    private func applied(_ command: SharedCommand, to first: SharedSnapshot,
                         actor: UUID? = nil) throws -> SharedCommandResult {
        try SharedCommandProcessor.apply(SharedCommandEnvelope(spaceID: space,
            commandID: UUID(), expectedSpaceRevision: first.revision, command: command),
            to: first, actorID: actor ?? owner, now: now)
    }

    private func coordinator(_ client: KnownResultClient, actor: UUID? = nil) async throws
        -> SharedStateCoordinator {
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: SharedAccountScope(backend: "known-result-test",
            accountID: actor ?? owner, spaceID: space), client: client)
        _ = try await coordinator.refresh()
        return coordinator
    }

    private func rejects(_ command: SharedCommand, wrong: SharedCommandResult,
                         first: SharedSnapshot, actor: UUID? = nil,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        try wrong.snapshot.validate(for: actor ?? owner)
        let client = KnownResultClient(first, actorID: actor ?? owner, now: now)
        let coordinator = try await coordinator(client, actor: actor)
        let commandID = UUID()
        await client.replyOnce(with: wrong)
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("Confirmed a result for a different original command", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
        XCTAssertEqual(coordinator.snapshot, first, file: file, line: line)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID), file: file, line: line)
        _ = try await coordinator.execute(command, commandID: commandID)
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command),
                      file: file, line: line)
    }

    func testImmediateWrongItemSettingsAndRoutineAreRejectedThenGenuineReceiptRecovers() async throws {
        let first = try initial()
        let run = try XCTUnwrap(first.state.runs.first)
        let firstItem = run.items[0].id
        let secondItem = run.items[1].id
        let checkFirst: SharedCommand = .setStandardChecked(runID: run.id, itemID: firstItem,
            checked: true, expectedRunRevision: run.revision)
        let checkSecond: SharedCommand = .setStandardChecked(runID: run.id, itemID: secondItem,
            checked: true, expectedRunRevision: run.revision)
        try await rejects(checkFirst, wrong: applied(checkSecond, to: first), first: first)

        let wanted = RunSettings(reminders: ReminderPreferences(remindPerformer: true))
        let other = RunSettings(reminders: ReminderPreferences(remindReviewer: true))
        try await rejects(.updateRunSettings(runID: run.id, settings: wanted,
            expectedRunRevision: run.revision), wrong: applied(.updateRunSettings(runID: run.id,
            settings: other, expectedRunRevision: run.revision), to: first), first: first)

        let routineA = Routine(title: "A", items: [RoutineItem(title: "Door")])
        let routineB = Routine(title: "B", items: [RoutineItem(title: "Door")])
        try await rejects(.saveRoutine(definition: routineA, expectedDefinitionVersion: nil),
            wrong: applied(.saveRoutine(definition: routineB,
            expectedDefinitionVersion: nil), to: first), first: first)
    }

    func testGenuineImmediateAndNewerReceiptRemainAccepted() async throws {
        let first = try initial()
        let run = try XCTUnwrap(first.state.runs.first)
        let command: SharedCommand = .setStandardChecked(runID: run.id,
            itemID: run.items[0].id, checked: true, expectedRunRevision: run.revision)
        let client = KnownResultClient(first, actorID: owner, now: now)
        let coordinator = try await coordinator(client)
        let commandID = UUID()
        _ = try await coordinator.execute(command, commandID: commandID)
        XCTAssertEqual(coordinator.snapshot, try applied(command, to: first).snapshot)
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
    }

    #if DEBUG
    func testImmediateWrongHumanReviewDecisionIsRejectedThenOriginalReviewRecovers() async throws {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Seal", items: [
            RoutineItem(title: "Seal", priority: .high)
        ], performerID: owner, reviewerID: peer, now: now)
        let itemID = try XCTUnwrap(state.runs[0].items.first?.id)
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: owner,
            fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: runID, itemID: itemID,
                                          actorID: owner, now: now)
        try state.acceptSend(runID: runID, itemID: itemID,
                             actorID: owner, expectedVersion: version, now: now)
        let first = SharedSnapshot(spaceID: space, revision: 1,
                                   members: [owner, peer], state: state)
        try first.validate(for: peer)
        let revision = state.runs[0].revision
        let approve: SharedCommand = .approve(runID: runID, itemID: itemID,
            expectedVersion: version, expectedRunRevision: revision)
        let request: SharedCommand = .requestAnother(runID: runID, itemID: itemID,
            expectedVersion: version, note: "Another angle", expectedRunRevision: revision)
        try await rejects(approve, wrong: applied(request, to: first, actor: peer),
                          first: first, actor: peer)
    }
    #endif

    func testLaggingReplyStillNeedsOriginalHistoryAndMustFitNewerLiveView() async throws {
        let first = try initial()
        let run = try XCTUnwrap(first.state.runs.first)
        let firstCheck: SharedCommand = .setStandardChecked(runID: run.id,
            itemID: run.items[0].id, checked: true, expectedRunRevision: run.revision)
        let actual = try applied(firstCheck, to: first)
        let secondCheck: SharedCommand = .setStandardChecked(runID: run.id,
            itemID: run.items[1].id, checked: true,
            expectedRunRevision: actual.snapshot.state.runs[0].revision)
        let live = try applied(secondCheck, to: actual.snapshot).snapshot
        let client = KnownResultClient(first, actorID: owner, now: now)
        let coordinator = try await coordinator(client)
        await client.holdReply()
        let missing = SecondLookState(routines: actual.snapshot.state.routines,
                                      runs: [], archives: actual.snapshot.state.archives)
        let malformedHistory = SharedCommandResult(snapshot: SharedSnapshot(spaceID: space,
            revision: actual.snapshot.revision, members: first.members, state: missing),
            createdID: nil)
        try malformedHistory.snapshot.validate(for: owner)
        await client.replyOnce(with: malformedHistory)
        let commandID = UUID()
        let task = Task { try await coordinator.execute(firstCheck, commandID: commandID) }
        await client.waitUntilReplyHeld()
        await client.setCurrent(live)
        _ = try await coordinator.refresh()
        XCTAssertEqual(coordinator.snapshot, live)
        await client.releaseReply()
        do {
            _ = try await task.value
            XCTFail("Confirmed a lagging reply that deleted the original run")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertEqual(coordinator.snapshot, live)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))

        // A genuine N+1 receipt can arrive after a separately observed N+2 write.
        let goodClient = KnownResultClient(first, actorID: owner, now: now)
        let goodCoordinator = try await self.coordinator(goodClient)
        await goodClient.holdReply()
        let goodID = UUID()
        let goodTask = Task { try await goodCoordinator.execute(firstCheck, commandID: goodID) }
        await goodClient.waitUntilReplyHeld()
        await goodClient.setCurrent(live)
        _ = try await goodCoordinator.refresh()
        await goodClient.releaseReply()
        _ = try await goodTask.value
        XCTAssertEqual(goodCoordinator.snapshot, live)
        XCTAssertTrue(goodCoordinator.hasConfirmedReceipt(commandID: goodID, command: firstCheck))
    }

    func testLaggingConflictingRunCannotBeHiddenByNewerLiveView() async throws {
        let first = try initial()
        let run = first.state.runs[0]
        let command: SharedCommand = .setStandardChecked(runID: run.id,
            itemID: run.items[0].id, checked: true, expectedRunRevision: run.revision)
        let genuine = try applied(command, to: first).snapshot
        let later = try applied(.setStandardChecked(runID: run.id,
            itemID: run.items[1].id, checked: true,
            expectedRunRevision: genuine.state.runs[0].revision), to: genuine).snapshot
        let other: SharedCommand = .setStandardChecked(runID: run.id,
            itemID: run.items[1].id, checked: true, expectedRunRevision: run.revision)
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: first.revision, command: other)
        let conflicting = try SharedCommandProcessor.apply(envelope, to: first,
            actorID: owner, now: now.addingTimeInterval(10))
        try conflicting.snapshot.validate(for: owner)
        let client = KnownResultClient(first, actorID: owner, now: now)
        let coordinator = try await coordinator(client)
        await client.replyOnce(with: conflicting)
        await client.holdReply()
        let commandID = UUID()
        let task = Task { try await coordinator.execute(command, commandID: commandID) }
        await client.waitUntilReplyHeld()
        await client.setCurrent(later)
        _ = try await coordinator.refresh()
        await client.releaseReply()
        do {
            _ = try await task.value
            XCTFail("A conflicting lagging run was confirmed")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertEqual(coordinator.snapshot, later)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
    }

    func testOlderCompressedCreationCannotBeConfirmedAfterNewerFetch() async throws {
        let first = try initial()
        let command: SharedCommand = .startOneOff(title: "New", items: [
            RoutineItem(title: "Coat")
        ], settings: .init())
        let client = KnownResultClient(first, actorID: owner, now: now)
        let coordinator = try await coordinator(client)
        await client.compressNextCreation()
        await client.holdReply()
        let commandID = UUID()
        let task = Task { try await coordinator.execute(command, commandID: commandID) }
        await client.waitUntilReplyHeld()
        let created = try await client.fetch(spaceID: space)
        let oldRun = first.state.runs[0]
        let later = try applied(.updateRunSettings(runID: oldRun.id,
            settings: RunSettings(reminders: ReminderPreferences(remindPerformer: true)),
            expectedRunRevision: oldRun.revision), to: created).snapshot
        await client.setCurrent(later)
        _ = try await coordinator.refresh()
        await client.releaseReply()
        do {
            _ = try await task.value
            XCTFail("An older creation with an extra run mutation was confirmed")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertEqual(coordinator.snapshot, later)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
    }
}
