import Foundation
import XCTest
@testable import SecondLookCore

private actor SingleRunEffectClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private let now: Date
    private var mixNextReply = false
    private var receipts: [UUID: SharedCommandResult] = [:]

    init(current: SharedSnapshot, actorID: UUID, now: Date) {
        self.current = current
        self.actorID = actorID
        self.now = now
    }
    func setCurrent(_ snapshot: SharedSnapshot) { current = snapshot }
    func mixNext() { mixNextReply = true }
    func fetch(spaceID: UUID) async throws -> SharedSnapshot { current }
    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        if let receipt = receipts[envelope.commandID] { return receipt }
        let original = current
        let result = try SharedCommandProcessor.apply(envelope, to: original,
                                                      actorID: actorID, now: now)
        current = result.snapshot
        receipts[envelope.commandID] = result
        if mixNextReply {
            mixNextReply = false
            var state = original.state
            guard case let .setStandardChecked(runID, itemID, checked, _) = envelope.command else {
                return result
            }
            try state.setStandardChecked(runID: runID, itemID: itemID,
                checked: checked, actorID: actorID, now: now)
            let otherID = original.state.runs.first { $0.id == runID }!.items[1].id
            try state.setStandardChecked(runID: runID, itemID: otherID,
                checked: true, actorID: actorID, now: now)
            return SharedCommandResult(snapshot: SharedSnapshot(spaceID: original.spaceID,
                revision: result.snapshot.revision, members: original.members, state: state),
                createdID: nil)
        }
        return result
    }
}

@MainActor
final class SingleRunEffectTransitionTests: XCTestCase {
    private let owner = UUID(uuidString: "A9000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "A9000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "A9000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func scope(_ actor: UUID? = nil) -> SharedAccountScope {
        SharedAccountScope(backend: "single-run-effect-test", accountID: actor ?? owner,
                           spaceID: space)
    }
    private func view(_ state: SecondLookState, revision: Int,
                      members: [UUID]? = nil) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision,
                       members: members ?? [owner, peer], state: state)
    }
    private func fixture() throws -> (SecondLookState, UUID, UUID) {
        var state = SecondLookState()
        let firstID = try state.startOneOff(title: "First", items: [
            RoutineItem(title: "Door"), RoutineItem(title: "Keys")
        ], performerID: owner, reviewerID: peer, now: now)
        let secondID = try state.startOneOff(title: "Second", items: [
            RoutineItem(title: "Bag")
        ], performerID: owner, reviewerID: peer, now: now)
        return (state, firstID, secondID)
    }
    private func processed(_ first: SharedSnapshot, command: SharedCommand,
                           actor: UUID? = nil, at time: Date? = nil) throws -> SharedSnapshot {
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: first.revision, command: command)
        return try SharedCommandProcessor.apply(envelope, to: first,
            actorID: actor ?? owner, now: time ?? now).snapshot
    }
    private func expectInvalid(_ coordinator: SharedStateCoordinator,
                               references: [SharedSnapshot] = [],
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await coordinator.refresh(validatingAgainst: references)
            XCTFail("One shared revision accepted an impossible run effect", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    func testUnseededAndSeededRejectTwoRunsTwoChecksSettingsPlusCheckAndWrongRunRevision() async throws {
        let (source, firstID, secondID) = try fixture()
        let first = view(source, revision: 1)
        let mixed: [SecondLookState] = try [
            { var s = source; try s.setStandardChecked(runID: firstID,
                itemID: source.runs[0].items[0].id, checked: true, actorID: owner, now: now)
                try s.setStandardChecked(runID: secondID,
                    itemID: source.runs[1].items[0].id, checked: true, actorID: owner, now: now)
                return s }(),
            { var s = source; for item in source.runs[0].items {
                try s.setStandardChecked(runID: firstID, itemID: item.id,
                    checked: true, actorID: owner, now: now)
              }; return s }(),
            { var s = source; try s.updateRunSettings(runID: firstID, actorID: owner,
                settings: RunSettings(reminders: ReminderPreferences(remindPerformer: true)))
                try s.setStandardChecked(runID: firstID,
                    itemID: source.runs[0].items[0].id, checked: true, actorID: owner, now: now)
                return s }(),
            { var s = source; try s.setStandardChecked(runID: firstID,
                itemID: source.runs[0].items[0].id, checked: true, actorID: owner, now: now)
                var runs = s.runs; runs[0].revision = source.runs[0].revision + 2
                return SecondLookState(routines: s.routines, runs: runs, archives: s.archives) }(),
        ]
        for state in mixed {
            let candidate = view(state, revision: 2)
            try candidate.validate(for: owner)
            let client = SingleRunEffectClient(current: candidate, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope(), client: client)
            await expectInvalid(coordinator, references: [first])
            XCTAssertNil(coordinator.snapshot)
        }
        let client = SingleRunEffectClient(current: first, actorID: owner, now: now)
        let seeded = SharedStateCoordinator()
        seeded.beginSession(scope: scope(), client: client)
        let published = try await seeded.refresh()
        XCTAssertTrue(published)
        await client.setCurrent(view(mixed[1], revision: 2))
        await expectInvalid(seeded)
        XCTAssertEqual(seeded.snapshot, first)
    }

    func testChronologicalReferencesCannotHideTwoChangesAndPairedNoEffectCannotAdvance() async throws {
        let (source, firstID, secondID) = try fixture()
        let first = view(source, revision: 1)
        var mixed = source
        try mixed.setStandardChecked(runID: firstID,
            itemID: source.runs[0].items[0].id, checked: true, actorID: owner, now: now)
        try mixed.updateRunSettings(runID: secondID, actorID: owner,
            settings: RunSettings(reminders: ReminderPreferences(remindPerformer: true)))
        let middle = view(mixed, revision: 2)
        let later = view(mixed, revision: 3)
        try middle.validate(for: owner)
        let client = SingleRunEffectClient(current: later, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(), client: client)
        await expectInvalid(coordinator, references: [middle, first])

        let noEffect = view(source, revision: 2)
        let silent = SingleRunEffectClient(current: noEffect, actorID: owner, now: now)
        let silentCoordinator = SharedStateCoordinator()
        silentCoordinator.beginSession(scope: scope(), client: silent)
        await expectInvalid(silentCoordinator, references: [first])
    }

    func testCommandReplyRejectsTwoChecksAndGenuineExactRetryRecovers() async throws {
        let (source, firstID, _) = try fixture()
        let first = view(source, revision: 1)
        let client = SingleRunEffectClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(), client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let command: SharedCommand = .setStandardChecked(runID: firstID,
            itemID: source.runs[0].items[0].id, checked: true,
            expectedRunRevision: source.runs[0].revision)
        let commandID = UUID()
        await client.mixNext()
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("Two checks in one response were published")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertEqual(coordinator.snapshot, first)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        _ = try await coordinator.execute(command, commandID: commandID)
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: commandID))
    }

    func testActualCommandsAutomaticCompletionOwnerRenewalAndTwoStepGapRemainValid() async throws {
        let (source, firstID, secondID) = try fixture()
        let first = view(source, revision: 1)
        let checked = try processed(first, command: .setStandardChecked(runID: firstID,
            itemID: source.runs[0].items[0].id, checked: true,
            expectedRunRevision: source.runs[0].revision))
        try await expectPublished(first, checked)
        let completed = try processed(checked, command: .setStandardChecked(runID: firstID,
            itemID: source.runs[0].items[1].id, checked: true,
            expectedRunRevision: checked.state.runs[0].revision))
        XCTAssertEqual(completed.state.runs[0].outcome, .completed)
        try await expectPublished(checked, completed)
        try await expectPublished(first, completed)

        let settings = try processed(first, command: .updateRunSettings(runID: secondID,
            settings: RunSettings(reminders: ReminderPreferences(remindPerformer: true)),
            expectedRunRevision: source.runs[1].revision))
        try await expectPublished(first, settings)
        let undone = try processed(settings, command: .setStandardChecked(runID: firstID,
            itemID: source.runs[0].items[0].id, checked: false,
            expectedRunRevision: settings.state.runs[0].revision))
        try await expectPublished(settings, undone)
        let canceled = try processed(first, command: .cancel(runID: firstID,
            expectedRunRevision: source.runs[0].revision))
        try await expectPublished(first, canceled)

        let oneOwner = view(SecondLookState(), revision: 1, members: [owner])
        let renewed = view(SecondLookState(), revision: 2, members: [owner])
        try await expectPublished(oneOwner, renewed)
    }

    #if DEBUG
    func testDebugSyntheticThreeStepReplacementAtOneRevisionRemainsValid() async throws {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Synthetic evidence", items: [
            RoutineItem(title: "Seal", priority: .high), RoutineItem(title: "Keys")
        ], performerID: owner, reviewerID: peer, now: now)
        let itemID = state.runs[0].items[0].id
        let first = view(state, revision: 1)
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: owner,
            fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: runID, itemID: itemID, actorID: owner, now: now)
        try state.acceptSend(runID: runID, itemID: itemID, actorID: owner,
            expectedVersion: version, now: now)
        let accepted = view(state, revision: 2)
        try await expectPublished(first, accepted)
        try state.requestAnother(runID: runID, itemID: itemID, actorID: peer,
            expectedVersion: version, note: "Another angle", now: now)
        let requested = view(state, revision: 3)
        try await expectPublished(accepted, requested)
        let withdrawn = try processed(requested, command: .withdraw(runID: runID,
            itemID: itemID, expectedVersion: version,
            expectedRunRevision: requested.state.runs[0].revision))
        try await expectPublished(requested, withdrawn)
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: owner,
            fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
        let replacementVersion = try state.beginSend(runID: runID, itemID: itemID,
            actorID: owner, now: now)
        try state.acceptSend(runID: runID, itemID: itemID, actorID: owner,
            expectedVersion: replacementVersion, now: now)
        let replaced = view(state, revision: 4)
        try await expectPublished(requested, replaced)

        let approved = try processed(replaced, command: .approve(runID: runID, itemID: itemID,
            expectedVersion: replacementVersion,
            expectedRunRevision: replaced.state.runs[0].revision), actor: peer)
        try await expectPublished(replaced, approved)
    }
    #endif

    private func expectPublished(_ earlier: SharedSnapshot, _ later: SharedSnapshot) async throws {
        try earlier.validate(for: owner)
        try later.validate(for: owner)
        let client = SingleRunEffectClient(current: later, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(), client: client)
        let published = try await coordinator.refresh(validatingAgainst: [earlier])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, later)
    }
}
