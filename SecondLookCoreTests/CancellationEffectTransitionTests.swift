import Foundation
import XCTest
@testable import SecondLookCore

private actor CancellationEffectClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private let now: Date
    private var mixNextCancel = false
    private var receipts: [UUID: SharedCommandResult] = [:]

    init(current: SharedSnapshot, actorID: UUID, now: Date) {
        self.current = current
        self.actorID = actorID
        self.now = now
    }
    func setCurrent(_ snapshot: SharedSnapshot) { current = snapshot }
    func mixNextCancellation() { mixNextCancel = true }
    func fetch(spaceID: UUID) async throws -> SharedSnapshot { current }
    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        if let receipt = receipts[envelope.commandID] { return receipt }
        let original = current
        let actual = try SharedCommandProcessor.apply(envelope, to: original,
                                                      actorID: actorID, now: now)
        current = actual.snapshot
        receipts[envelope.commandID] = actual
        if mixNextCancel {
            mixNextCancel = false
            guard case let .cancel(runID, _) = envelope.command else { return actual }
            var state = original.state
            let itemID = state.runs.first { $0.id == runID }!.items[0].id
            try state.setStandardChecked(runID: runID, itemID: itemID,
                                         checked: true, actorID: actorID, now: now)
            try state.cancel(runID: runID, actorID: actorID, now: now)
            return SharedCommandResult(snapshot: SharedSnapshot(spaceID: original.spaceID,
                revision: actual.snapshot.revision, members: original.members, state: state),
                createdID: nil)
        }
        return actual
    }
}

@MainActor
final class CancellationEffectTransitionTests: XCTestCase {
    private let owner = UUID(uuidString: "A8000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "A8000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "A8000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func scope(_ actor: UUID? = nil) -> SharedAccountScope {
        SharedAccountScope(backend: "cancel-effect-test", accountID: actor ?? owner, spaceID: space)
    }
    private func view(_ state: SecondLookState, revision: Int) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision,
                       members: [owner, peer], state: state)
    }
    private func standard() throws -> (SecondLookState, UUID) {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Existing", items: [
            RoutineItem(title: "First"), RoutineItem(title: "Second")
        ], performerID: owner, reviewerID: peer, now: now)
        _ = try state.startOneOff(title: "Other", items: [RoutineItem(title: "Bag")],
                                  performerID: owner, reviewerID: peer, now: now)
        return (state, runID)
    }
    private func canceled(_ first: SharedSnapshot, runID: UUID,
                          actor: UUID? = nil) throws -> SharedSnapshot {
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: first.revision,
            command: .cancel(runID: runID, expectedRunRevision:
                first.state.runs.first { $0.id == runID }!.revision))
        return try SharedCommandProcessor.apply(envelope, to: first,
            actorID: actor ?? owner, now: now).snapshot
    }
    private func expectInvalid(_ coordinator: SharedStateCoordinator,
                               references: [SharedSnapshot] = [],
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await coordinator.refresh(validatingAgainst: references)
            XCTFail("Adjacent cancellation changed more than Core cancel does", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    func testStandardCancelCombinedWithCheckSettingsOrOtherRunEditRejectsAllPublicationPaths() async throws {
        let (source, runID) = try standard()
        let first = view(source, revision: 1)
        let others: [SecondLookState] = try [
            { var s = source; try s.setStandardChecked(runID: runID,
                itemID: source.runs[0].items[0].id, checked: true, actorID: owner, now: now)
                try s.cancel(runID: runID, actorID: owner, now: now); return s }(),
            { var s = source; try s.updateRunSettings(runID: runID, actorID: owner,
                settings: RunSettings(reminders: ReminderPreferences(remindPerformer: true)))
                try s.cancel(runID: runID, actorID: owner, now: now); return s }(),
            { var s = source; try s.cancel(runID: runID, actorID: owner, now: now)
                try s.updateRunSettings(runID: source.runs[1].id, actorID: owner,
                    settings: RunSettings(reminders: ReminderPreferences(remindPerformer: true)))
                return s }(),
        ]
        for state in others {
            let candidate = view(state, revision: 2)
            try candidate.validate(for: owner)
            let client = CancellationEffectClient(current: candidate, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope(), client: client)
            await expectInvalid(coordinator, references: [first])
            XCTAssertNil(coordinator.snapshot)
        }

        let bad = view(others[0], revision: 2)
        let latest = view(others[0], revision: 3)
        let client = CancellationEffectClient(current: latest, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(), client: client)
        await expectInvalid(coordinator, references: [bad, first])
        await client.setCurrent(first)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        await client.setCurrent(bad)
        await expectInvalid(coordinator)
        XCTAssertEqual(coordinator.snapshot, first)
    }

    func testCancelCommandRejectsMixedReplyThenExactReceiptRetryRecovers() async throws {
        let (source, runID) = try standard()
        let first = view(source, revision: 1)
        let client = CancellationEffectClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(), client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let command: SharedCommand = .cancel(runID: runID,
            expectedRunRevision: source.runs[0].revision)
        let commandID = UUID()
        await client.mixNextCancellation()
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("Mixed cancel response was published")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertEqual(coordinator.snapshot, first)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        _ = try await coordinator.execute(command, commandID: commandID)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: commandID))
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
        XCTAssertEqual(coordinator.snapshot?.state.runs[0].outcome, .canceled)
    }

    #if DEBUG
    private func undecidedEvidence() throws -> (SecondLookState, UUID) {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Synthetic review", items: [
            RoutineItem(title: "Seal", priority: .high), RoutineItem(title: "Keys")
        ], performerID: owner, reviewerID: peer, now: now)
        let itemID = state.runs[0].items[0].id
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: owner,
            fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: runID, itemID: itemID, actorID: owner, now: now)
        try state.acceptSend(runID: runID, itemID: itemID, actorID: owner,
                             expectedVersion: version, now: now)
        return (state, runID)
    }

    func testUndecidedEvidenceCancelCannotInventApprovedOrRequestedArchiveDecision() async throws {
        let (source, runID) = try undecidedEvidence()
        let first = view(source, revision: 1)
        let actual = try canceled(first, runID: runID)
        try first.validate(for: owner)
        try actual.validate(for: owner)
        for verdict in [ReviewVerdict.approved, .requestedAnother] {
            var archives = actual.state.archives
            archives[0].items[0].decisions = [ReviewDecision(actorID: peer,
                submissionVersion: 1, verdict: verdict,
                note: verdict == .approved ? nil : "Invented note", decidedAt: now)]
            let altered = view(SecondLookState(routines: actual.state.routines,
                runs: actual.state.runs, archives: archives), revision: actual.revision)
            try altered.validate(for: owner)
            let client = CancellationEffectClient(current: altered, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope(), client: client)
            await expectInvalid(coordinator, references: [first])
            XCTAssertNil(coordinator.snapshot)
        }
    }

    func testActualUndecidedAndReviewedSyntheticCancellationAndReviewThenCancelGapRemainValid() async throws {
        let (source, runID) = try undecidedEvidence()
        let first = view(source, revision: 1)
        let undecidedCancel = try canceled(first, runID: runID)
        try await expectPublished(from: first, to: undecidedCancel, actor: owner)
        try await expectPublished(from: first, to: undecidedCancel, actor: peer)

        var reviewed = source
        try reviewed.requestAnother(runID: runID, itemID: source.runs[0].items[0].id,
            actorID: peer, expectedVersion: 1, note: "Another angle", now: now)
        let afterReview = view(reviewed, revision: 2)
        let reviewedCancel = try canceled(afterReview, runID: runID)
        try await expectPublished(from: afterReview, to: reviewedCancel, actor: owner)
        try await expectPublished(from: first, to: reviewedCancel, actor: owner)

        try reviewed.withdraw(runID: runID, itemID: source.runs[0].items[0].id,
                              actorID: owner, expectedVersion: 1, now: now)
        let afterWithdrawal = view(reviewed, revision: 3)
        let withdrawnCancel = try canceled(afterWithdrawal, runID: runID)
        try await expectPublished(from: afterWithdrawal, to: withdrawnCancel, actor: owner)
        try await expectPublished(from: first, to: withdrawnCancel, actor: owner)
    }
    #endif

    func testActualTextOnlyCancelAndPriorSettingsThenCancelGapRemainValid() async throws {
        let (source, runID) = try standard()
        let first = view(source, revision: 1)
        let direct = try canceled(first, runID: runID)
        try await expectPublished(from: first, to: direct, actor: owner)
        try await expectPublished(from: first, to: direct, actor: peer)
        var adjusted = source
        try adjusted.updateRunSettings(runID: runID, actorID: owner,
            settings: RunSettings(reminders: ReminderPreferences(remindPerformer: true)))
        let afterSettings = view(adjusted, revision: 2)
        let laterCancel = try canceled(afterSettings, runID: runID)
        try await expectPublished(from: afterSettings, to: laterCancel, actor: owner)
        try await expectPublished(from: first, to: laterCancel, actor: owner)
    }

    private func expectPublished(from earlier: SharedSnapshot, to later: SharedSnapshot,
                                 actor: UUID) async throws {
        try earlier.validate(for: actor)
        try later.validate(for: actor)
        let client = CancellationEffectClient(current: later, actorID: actor, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(actor), client: client)
        let published = try await coordinator.refresh(validatingAgainst: [earlier])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, later)
    }
}
