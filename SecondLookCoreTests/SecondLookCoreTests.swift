import Foundation
import XCTest
import SecondLookCore

final class SecondLookCoreTests: XCTestCase {
    private let performer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let reviewer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000.125)

    private func mixed() -> Routine {
        Routine(title: "Sample", items: [
            RoutineItem(title: "Step one"),
            RoutineItem(title: "Evidence", priority: .high, photoInstructions: "Synthetic fixture"),
        ])
    }

    private func runItem(_ state: SecondLookState, _ runID: UUID, index: Int) -> RunItem {
        state.runs.first { $0.id == runID }!.items[index]
    }

    private func submit(_ state: inout SecondLookState, runID: UUID, itemID: UUID, fixture: String = "fixture-a") throws -> Int {
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: performer,
                               fixtureID: fixture, source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: runID, itemID: itemID, actorID: performer, now: now)
        try state.acceptSend(runID: runID, itemID: itemID, actorID: performer, expectedVersion: version, now: now)
        return version
    }

    func testEmptyAndReviewerRulesAndDefaults() throws {
        var state = SecondLookState()
        XCTAssertThrowsError(try state.startOneOff(title: "Empty", items: [], performerID: performer, reviewerID: nil)) {
            XCTAssertEqual($0 as? SecondLookError, .invalidDefinition)
        }
        let routine = mixed()
        try state.saveRoutine(routine)
        XCTAssertThrowsError(try state.startRun(routineID: routine.id, performerID: performer, reviewerID: nil)) {
            XCTAssertEqual($0 as? SecondLookError, .reviewerRequired)
        }
        XCTAssertThrowsError(try state.startRun(routineID: routine.id, performerID: performer, reviewerID: performer)) {
            XCTAssertEqual($0 as? SecondLookError, .reviewerRequired)
        }
        let id = try state.startRun(routineID: routine.id, performerID: performer, reviewerID: reviewer, now: now)
        XCTAssertNil(state.runs.first { $0.id == id }!.settings.unreviewedTimeoutSeconds)
        XCTAssertEqual(state.runs.first { $0.id == id }!.settings.reminders, ReminderPreferences())
    }

    func testSettingsRejectInvalidDurationsAndQuietHoursWithoutMutation() throws {
        var state = SecondLookState()
        let items = [RoutineItem(title: "Check")]
        for invalid in [0.0, -1.0, .nan, .infinity, -.infinity] {
            let settings = RunSettings(reminders: ReminderPreferences(firstDelaySeconds: invalid))
            XCTAssertThrowsError(try state.saveRoutine(Routine(title: "Bad", items: items, settings: settings))) {
                XCTAssertEqual($0 as? SecondLookError, .invalidDefinition)
            }
            XCTAssertThrowsError(try state.startOneOff(title: "Bad", items: items, settings: settings,
                                                       performerID: performer, reviewerID: nil, now: now)) {
                XCTAssertEqual($0 as? SecondLookError, .invalidDefinition)
            }
        }
        for settings in [
            RunSettings(reminders: ReminderPreferences(repeatSeconds: -2)),
            RunSettings(unreviewedTimeoutSeconds: 0),
            RunSettings(reminders: ReminderPreferences(quietHours: QuietHours(startMinute: -1, endMinute: 50))),
            RunSettings(reminders: ReminderPreferences(quietHours: QuietHours(startMinute: 0, endMinute: 1_440))),
        ] {
            XCTAssertThrowsError(try state.saveRoutine(Routine(title: "Bad", items: items, settings: settings))) {
                XCTAssertEqual($0 as? SecondLookError, .invalidDefinition)
            }
        }
        XCTAssertTrue(state.routines.isEmpty)
        XCTAssertTrue(state.runs.isEmpty)

        let valid = RunSettings(reminders: ReminderPreferences(firstDelaySeconds: 1, repeatSeconds: 60,
                                                               quietHours: QuietHours(startMinute: 0, endMinute: 1_439)),
                                unreviewedTimeoutSeconds: 120)
        let routine = Routine(title: "Good", items: items, settings: valid)
        try state.saveRoutine(routine)
        let id = try state.startRun(routineID: routine.id, performerID: performer, reviewerID: nil, now: now)
        XCTAssertEqual(state.runs[0].settings, valid)
        let badUpdate = RunSettings(reminders: ReminderPreferences(repeatSeconds: .infinity))
        XCTAssertThrowsError(try state.updateRunSettings(runID: id, actorID: performer, settings: badUpdate)) {
            XCTAssertEqual($0 as? SecondLookError, .invalidDefinition)
        }
        XCTAssertEqual(state.runs[0].settings, valid)
        try state.updateRunSettings(runID: id, actorID: performer, settings: RunSettings())
        XCTAssertNil(state.runs[0].settings.unreviewedTimeoutSeconds)

        // A malformed imported routine cannot bypass validation at run start.
        var imported = SecondLookState(routines: [Routine(title: "Imported", items: items,
                                                         settings: RunSettings(unreviewedTimeoutSeconds: -.infinity))])
        XCTAssertThrowsError(try imported.startRun(routineID: imported.routines[0].id,
                                                   performerID: performer, reviewerID: nil, now: now)) {
            XCTAssertEqual($0 as? SecondLookError, .invalidDefinition)
        }
    }

    func testAllStandardAutoCompletionAndTextOnlyArchive() throws {
        var state = SecondLookState()
        let id = try state.startOneOff(title: "Simple", items: [RoutineItem(title: "Done")],
                                       performerID: performer, reviewerID: nil, now: now)
        let item = runItem(state, id, index: 0)
        try state.setStandardChecked(runID: id, itemID: item.id, checked: true, actorID: performer, now: now)
        XCTAssertEqual(state.runs[0].outcome, .completed)
        XCTAssertEqual(state.archives[0].cleanupStatus, .notNeeded)
        XCTAssertEqual(state.archives[0].items[0].checkedAt, now)
        XCTAssertThrowsError(try state.setStandardChecked(runID: id, itemID: item.id, checked: false, actorID: performer)) {
            XCTAssertEqual($0 as? SecondLookError, .closed)
        }
        XCTAssertThrowsError(try state.confirmSimulatedCleanup(runID: id)) {
            XCTAssertEqual($0 as? SecondLookError, .invalidTransition)
        }
    }

    func testMixedApprovalRequiresStandardAndDistinctReviewer() throws {
        var state = SecondLookState()
        let id = try state.startOneOff(title: "Mixed", items: mixed().items, performerID: performer, reviewerID: reviewer, now: now)
        let high = runItem(state, id, index: 1).id
        let standard = runItem(state, id, index: 0).id
        let version = try submit(&state, runID: id, itemID: high)
        XCTAssertThrowsError(try state.approve(runID: id, itemID: high, actorID: performer, expectedVersion: version)) {
            XCTAssertEqual($0 as? SecondLookError, .unauthorized)
        }
        try state.approve(runID: id, itemID: high, actorID: reviewer, expectedVersion: version, now: now)
        XCTAssertTrue(state.runs[0].isOpen)
        try state.setStandardChecked(runID: id, itemID: standard, checked: true, actorID: performer, now: now)
        XCTAssertEqual(state.runs[0].outcome, .completed)
        XCTAssertNil(state.runs[0].items[1].submission)
        XCTAssertEqual(state.archives[0].cleanupStatus, .pending)
        XCTAssertEqual(state.archives[0].items[1].decisions[0].submissionVersion, version)
        XCTAssertFalse(String(data: try JSONEncoder().encode(state.archives), encoding: .utf8)!.contains("fixture-a"))
        try state.confirmSimulatedCleanup(runID: id)
        XCTAssertEqual(state.archives[0].cleanupStatus, .simulatedConfirmed)
    }

    func testPreviewCancelPreservesApprovalAndReplacementRejectsOldVersion() throws {
        var state = SecondLookState()
        let id = try state.startOneOff(title: "High", items: [RoutineItem(title: "Photo", priority: .high)],
                                       performerID: performer, reviewerID: reviewer, now: now)
        let item = runItem(state, id, index: 0).id
        let first = try submit(&state, runID: id, itemID: item)
        // Keep this run open by asking for another photo instead of approving its sole item.
        try state.requestAnother(runID: id, itemID: item, actorID: reviewer, expectedVersion: first,
                                 note: "Please show more", now: now)
        try state.prepareDraft(runID: id, itemID: item, actorID: performer, fixtureID: "fixture-b",
                               source: .simulatedLibrary, now: now)
        XCTAssertEqual(runItem(state, id, index: 0).submission?.status, .needsAnotherLook)
        try state.discardDraft(runID: id, itemID: item, actorID: performer, now: now)
        XCTAssertEqual(runItem(state, id, index: 0).submission?.version, first)
        try state.prepareDraft(runID: id, itemID: item, actorID: performer, fixtureID: "fixture-c",
                               source: .simulatedCamera, now: now)
        let second = try state.beginSend(runID: id, itemID: item, actorID: performer, now: now)
        XCTAssertEqual(second, first + 1)
        XCTAssertThrowsError(try state.approve(runID: id, itemID: item, actorID: reviewer, expectedVersion: first)) {
            XCTAssertEqual($0 as? SecondLookError, .staleVersion)
        }
        try state.acceptSend(runID: id, itemID: item, actorID: performer, expectedVersion: second, now: now)
        XCTAssertNil(runItem(state, id, index: 0).submission?.decision)
    }

    func testApprovedEvidenceSurvivesCanceledPreviewAndCommittedReplacementInvalidatesIt() throws {
        var state = SecondLookState()
        let id = try state.startOneOff(title: "Mixed", items: mixed().items,
                                       performerID: performer, reviewerID: reviewer, now: now)
        let high = runItem(state, id, index: 1).id
        let first = try submit(&state, runID: id, itemID: high)
        try state.approve(runID: id, itemID: high, actorID: reviewer, expectedVersion: first, now: now)
        XCTAssertTrue(state.runs[0].isOpen) // the standard item remains unchecked
        try state.prepareDraft(runID: id, itemID: high, actorID: performer, fixtureID: "fixture-b",
                               source: .simulatedLibrary, now: now)
        XCTAssertEqual(runItem(state, id, index: 1).submission?.status, .approved)
        try state.discardDraft(runID: id, itemID: high, actorID: performer, now: now)
        XCTAssertTrue(runItem(state, id, index: 1).isSatisfied)
        try state.prepareDraft(runID: id, itemID: high, actorID: performer, fixtureID: "fixture-c",
                               source: .simulatedCamera, now: now)
        let second = try state.beginSend(runID: id, itemID: high, actorID: performer, now: now)
        XCTAssertFalse(runItem(state, id, index: 1).isSatisfied)
        XCTAssertEqual(runItem(state, id, index: 1).priorDecisions[0].submissionVersion, first)
        XCTAssertThrowsError(try state.approve(runID: id, itemID: high, actorID: reviewer, expectedVersion: first)) {
            XCTAssertEqual($0 as? SecondLookError, .staleVersion)
        }
        XCTAssertEqual(second, first + 1)
    }

    func testRequestedChangeNeedsNoteAndRetryRetainsVersion() throws {
        var state = SecondLookState()
        let id = try state.startOneOff(title: "High", items: [RoutineItem(title: "Photo", priority: .high)],
                                       performerID: performer, reviewerID: reviewer, now: now)
        let item = runItem(state, id, index: 0).id
        try state.prepareDraft(runID: id, itemID: item, actorID: performer, fixtureID: "fixture-a",
                               source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: id, itemID: item, actorID: performer, now: now)
        try state.failSend(runID: id, itemID: item, actorID: performer, expectedVersion: version, now: now)
        XCTAssertEqual(runItem(state, id, index: 0).submission?.status, .uploadFailed)
        try state.retrySend(runID: id, itemID: item, actorID: performer, expectedVersion: version, now: now)
        try state.acceptSend(runID: id, itemID: item, actorID: performer, expectedVersion: version, now: now)
        XCTAssertThrowsError(try state.requestAnother(runID: id, itemID: item, actorID: reviewer,
                                                     expectedVersion: version, note: "  ")) {
            XCTAssertEqual($0 as? SecondLookError, .noteRequired)
        }
        try state.requestAnother(runID: id, itemID: item, actorID: reviewer,
                                 expectedVersion: version, note: "  More detail  ", now: now)
        XCTAssertEqual(runItem(state, id, index: 0).submission?.decision?.note, "More detail")
        XCTAssertThrowsError(try state.approve(runID: id, itemID: item, actorID: reviewer, expectedVersion: version)) {
            XCTAssertEqual($0 as? SecondLookError, .invalidTransition)
        }
    }

    func testMultipleRunsAndTemplateSnapshotAndStructureCopy() throws {
        var state = SecondLookState()
        var routine = mixed()
        try state.saveRoutine(routine)
        let first = try state.startRun(routineID: routine.id, performerID: performer, reviewerID: reviewer, now: now)
        routine.items[0].title = "Changed"
        try state.saveRoutine(routine)
        let second = try state.startRun(routineID: routine.id, performerID: performer, reviewerID: reviewer, now: now)
        XCTAssertEqual(state.runs.first { $0.id == first }!.items[0].title, "Step one")
        XCTAssertEqual(state.runs.first { $0.id == second }!.items[0].title, "Changed")
        XCTAssertEqual(state.runs.first { $0.id == first }!.routineVersion, 1)
        XCTAssertEqual(state.runs.first { $0.id == second }!.routineVersion, 2)
        let copied = try state.saveRunAsRoutine(runID: first)
        XCTAssertEqual(state.routines.first { $0.id == copied }!.items[0].title, "Step one")
        try state.deleteRoutine(id: routine.id)
        XCTAssertEqual(state.runs.count, 2)
        XCTAssertNotEqual(state.runs[0].items[0].id, state.runs[1].items[0].id)
    }

    func testCancellationWinsAndNoResurrection() throws {
        var state = SecondLookState()
        let id = try state.startOneOff(title: "High", items: [RoutineItem(title: "Photo", priority: .high)],
                                       performerID: performer, reviewerID: reviewer, now: now)
        let item = runItem(state, id, index: 0).id
        let version = try submit(&state, runID: id, itemID: item)
        try state.cancel(runID: id, actorID: performer, now: now)
        XCTAssertEqual(state.runs[0].outcome, .canceled)
        XCTAssertNil(state.runs[0].items[0].submission)
        XCTAssertThrowsError(try state.approve(runID: id, itemID: item, actorID: reviewer, expectedVersion: version)) {
            XCTAssertEqual($0 as? SecondLookError, .closed)
        }
        XCTAssertThrowsError(try state.cancel(runID: id, actorID: performer)) {
            XCTAssertEqual($0 as? SecondLookError, .closed)
        }
        let repeated = try state.repeatRun(runID: id, performerID: performer, reviewerID: reviewer, now: now)
        XCTAssertNil(runItem(state, repeated, index: 0).submission)
        XCTAssertTrue(state.runs.first { $0.id == repeated }!.isOpen)
    }

    @MainActor func testPersistenceRelaunchCorruptionVersionAndFailedTransaction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let store = JSONStateStore(url: url)
        let repository = try LocalStateRepository(store: store)
        let id = try repository.transact { state in
            try state.startOneOff(title: "Saved", items: [RoutineItem(title: "Check")],
                                  performerID: performer, reviewerID: nil, now: now)
        }
        XCTAssertEqual(try JSONStateStore(url: url).load().runs[0].id, id)
        XCTAssertEqual(try store.load().runs[0].startedAt, now)
        XCTAssertEqual(try LocalStateRepository(store: store).state.runs[0].id, id)
        XCTAssertThrowsError(try repository.transact { state in
            try state.cancel(runID: id, actorID: performer, now: now)
            throw SecondLookError.invalidTransition
        })
        XCTAssertTrue(repository.state.runs[0].isOpen)
        XCTAssertTrue(try store.load().runs[0].isOpen)
        try Data("{bad".utf8).write(to: url)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? SecondLookError, .corruptDocument) }
        XCTAssertThrowsError(try LocalStateRepository(store: store))
        try Data("{\"schemaVersion\":999,\"state\":{}}".utf8).write(to: url)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? SecondLookError, .unsupportedDocumentVersion(999)) }
    }

    @MainActor func testDiskSaveFailureDoesNotPublishMutation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockingFile = directory.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingFile)
        let store = JSONStateStore(url: blockingFile.appendingPathComponent("state.json"))
        let repository = try LocalStateRepository(store: store)
        XCTAssertThrowsError(try repository.transact { state in
            try state.startOneOff(title: "Unsaved", items: [RoutineItem(title: "Check")],
                                  performerID: performer, reviewerID: nil, now: now)
        })
        XCTAssertTrue(repository.state.runs.isEmpty)
        XCTAssertTrue(try store.load().runs.isEmpty)
    }

    func testSemanticallyInvalidJSONIsRejectedOnLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONStateStore(url: directory.appendingPathComponent("state.json"))
        var state = SecondLookState()
        let id = try state.startOneOff(title: "High", items: [RoutineItem(title: "Photo", priority: .high)],
                                       performerID: performer, reviewerID: reviewer, now: now)
        let run = state.runs.first { $0.id == id }!
        try store.save(SecondLookState(runs: [run, run]))
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? SecondLookError, .corruptDocument) }

        try store.save(state)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        var encodedState = try XCTUnwrap(document["state"] as? [String: Any])
        var runs = try XCTUnwrap(encodedState["runs"] as? [[String: Any]])
        runs[0]["reviewerID"] = runs[0]["performerID"]
        encodedState["runs"] = runs
        document["state"] = encodedState
        try JSONSerialization.data(withJSONObject: document).write(to: store.url)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? SecondLookError, .corruptDocument) }
    }

    func testRelaunchRestoresCheckmarksAndApprovedEvidenceWithPreview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONStateStore(url: directory.appendingPathComponent("state.json"))
        var state = SecondLookState()
        let id = try state.startOneOff(title: "Mixed", items: [
            RoutineItem(title: "Checked"), RoutineItem(title: "Unchecked"),
            RoutineItem(title: "Evidence", priority: .high),
        ], performerID: performer, reviewerID: reviewer, now: now)
        let checkedID = runItem(state, id, index: 0).id
        let highID = runItem(state, id, index: 2).id
        try state.setStandardChecked(runID: id, itemID: checkedID, checked: true, actorID: performer, now: now)
        let version = try submit(&state, runID: id, itemID: highID)
        try state.approve(runID: id, itemID: highID, actorID: reviewer, expectedVersion: version, now: now)
        try state.prepareDraft(runID: id, itemID: highID, actorID: performer, fixtureID: "fixture-new",
                               source: .simulatedLibrary, now: now)
        try store.save(state)
        let restored = try store.load()
        XCTAssertEqual(restored, state)
        XCTAssertEqual(runItem(restored, id, index: 0).checkedAt, now)
        XCTAssertNil(runItem(restored, id, index: 1).checkedAt)
        XCTAssertEqual(runItem(restored, id, index: 2).submission?.status, .approved)
        XCTAssertEqual(runItem(restored, id, index: 2).preview?.status, .localDraft)
        XCTAssertTrue(restored.runs[0].isOpen)
    }

    func testRelaunchRestoresFailedAndSendingVersionsForRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONStateStore(url: directory.appendingPathComponent("state.json"))
        var state = SecondLookState()
        let id = try state.startOneOff(title: "High", items: [RoutineItem(title: "Evidence", priority: .high)],
                                       performerID: performer, reviewerID: reviewer, now: now)
        let item = runItem(state, id, index: 0).id
        try state.prepareDraft(runID: id, itemID: item, actorID: performer, fixtureID: "fixture-a",
                               source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: id, itemID: item, actorID: performer, now: now)
        try state.failSend(runID: id, itemID: item, actorID: performer, expectedVersion: version, now: now)
        try store.save(state)
        var restored = try store.load()
        XCTAssertEqual(runItem(restored, id, index: 0).submission?.status, .uploadFailed)
        try restored.retrySend(runID: id, itemID: item, actorID: performer, expectedVersion: version, now: now)
        try store.save(restored)
        restored = try store.load()
        XCTAssertEqual(runItem(restored, id, index: 0).submission?.status, .sending)
        XCTAssertEqual(runItem(restored, id, index: 0).submission?.version, version)
        try restored.acceptSend(runID: id, itemID: item, actorID: performer, expectedVersion: version, now: now)
        XCTAssertEqual(runItem(restored, id, index: 0).submission?.status, .waitingForReview)
    }

    func testFinalApprovalWinsBeforeLateCancellationAndArchiveRelaunchStaysTextOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONStateStore(url: directory.appendingPathComponent("state.json"))
        var state = SecondLookState()
        let id = try state.startOneOff(title: "High", items: [RoutineItem(title: "Evidence", priority: .high)],
                                       performerID: performer, reviewerID: reviewer, now: now)
        let item = runItem(state, id, index: 0).id
        let version = try submit(&state, runID: id, itemID: item)
        try state.approve(runID: id, itemID: item, actorID: reviewer, expectedVersion: version, now: now)
        XCTAssertThrowsError(try state.cancel(runID: id, actorID: performer, now: now)) {
            XCTAssertEqual($0 as? SecondLookError, .closed)
        }
        XCTAssertEqual(state.archives.count, 1)
        XCTAssertEqual(state.archives[0].outcome, .completed)
        XCTAssertEqual(state.archives[0].cleanupStatus, .pending)
        XCTAssertNil(state.runs[0].items[0].submission)
        try store.save(state)
        let restored = try store.load()
        XCTAssertEqual(restored.archives.count, 1)
        XCTAssertEqual(restored.archives[0].items[0].decisions[0].verdict, .approved)
        XCTAssertFalse(String(data: try Data(contentsOf: store.url), encoding: .utf8)!.contains("fixture-a"))
    }
}
