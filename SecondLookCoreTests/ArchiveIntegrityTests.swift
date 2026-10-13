import Foundation
import XCTest
import SecondLookCore

final class ArchiveIntegrityTests: XCTestCase {
    private let performer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let reviewer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let outsider = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func completedMixedState() throws -> SecondLookState {
        var state = SecondLookState()
        let routine = Routine(title: "Departure", items: [
            RoutineItem(title: "Lock door"),
            RoutineItem(title: "Check stove", priority: .high, photoInstructions: "Synthetic only"),
        ])
        try state.saveRoutine(routine)
        let runID = try state.startRun(routineID: routine.id, performerID: performer,
                                       reviewerID: reviewer, now: now)
        let standardID = state.runs[0].items[0].id
        let highID = state.runs[0].items[1].id
        try state.setStandardChecked(runID: runID, itemID: standardID, checked: true,
                                     actorID: performer, now: now.addingTimeInterval(1))
        try state.prepareDraft(runID: runID, itemID: highID, actorID: performer,
                               fixtureID: "synthetic-one", source: .simulatedCamera, now: now)
        let first = try state.beginSend(runID: runID, itemID: highID, actorID: performer, now: now)
        try state.acceptSend(runID: runID, itemID: highID, actorID: performer,
                             expectedVersion: first, now: now)
        try state.requestAnother(runID: runID, itemID: highID, actorID: reviewer,
                                 expectedVersion: first, note: "Try again", now: now)
        try state.prepareDraft(runID: runID, itemID: highID, actorID: performer,
                               fixtureID: "synthetic-two", source: .simulatedCamera, now: now)
        let second = try state.beginSend(runID: runID, itemID: highID, actorID: performer, now: now)
        try state.acceptSend(runID: runID, itemID: highID, actorID: performer,
                             expectedVersion: second, now: now)
        try state.approve(runID: runID, itemID: highID, actorID: reviewer,
                          expectedVersion: second, now: now.addingTimeInterval(2))
        return state
    }

    private func canceledState(reviewed: Bool = false) throws -> SecondLookState {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Canceled", items: [
            RoutineItem(title: "Photo step", priority: .high),
        ], performerID: performer, reviewerID: reviewer, now: now)
        let itemID = state.runs[0].items[0].id
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: performer,
                               fixtureID: "synthetic-only", source: .simulatedLibrary, now: now)
        let version = try state.beginSend(runID: runID, itemID: itemID, actorID: performer, now: now)
        try state.acceptSend(runID: runID, itemID: itemID, actorID: performer,
                             expectedVersion: version, now: now)
        if reviewed {
            try state.requestAnother(runID: runID, itemID: itemID, actorID: reviewer,
                                     expectedVersion: version, note: "Need another view", now: now)
        }
        try state.cancel(runID: runID, actorID: performer, now: now.addingTimeInterval(3))
        return state
    }

    private func canceledNeverSubmittedState() throws -> SecondLookState {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Canceled before evidence", items: [
            RoutineItem(title: "Photo step", priority: .high),
        ], performerID: performer, reviewerID: reviewer, now: now)
        try state.cancel(runID: runID, actorID: performer, now: now.addingTimeInterval(1))
        return state
    }

    private func canceledUncheckedStandardState() throws -> SecondLookState {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Canceled before check", items: [
            RoutineItem(title: "Standard step"),
        ], performerID: performer, reviewerID: nil, now: now)
        try state.cancel(runID: runID, actorID: performer, now: now.addingTimeInterval(1))
        return state
    }

    private func mutatedArchive(_ original: SecondLookState,
                                _ change: (inout TextArchive) -> Void) -> SecondLookState {
        var archive = original.archives[0]
        change(&archive)
        return SecondLookState(routines: original.routines, runs: original.runs, archives: [archive])
    }

    private func assertRejected(_ state: SecondLookState, file: StaticString = #filePath,
                                line: UInt = #line) throws {
        XCTAssertThrowsError(try state.validateForLoad(), file: file, line: line) {
            XCTAssertEqual($0 as? SecondLookError, .corruptDocument, file: file, line: line)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONStateStore(url: directory.appendingPathComponent("state.json"))
        try store.save(state)
        XCTAssertThrowsError(try store.load(), file: file, line: line) {
            XCTAssertEqual($0 as? SecondLookError, .corruptDocument, file: file, line: line)
        }
        let snapshot = SharedSnapshot(spaceID: UUID(), revision: 1,
                                      members: [performer, reviewer], state: state)
        XCTAssertThrowsError(try snapshot.validate(for: performer), file: file, line: line) {
            XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    func testRejectsChangedArchiveAttributionAndTextFields() throws {
        let original = try completedMixedState()
        let changes: [(inout TextArchive) -> Void] = [
            { $0.title = "Different title" },
            { $0.routineID = UUID() },
            { $0.performerID = self.outsider },
            { $0.reviewerID = self.outsider },
            { $0.reviewerID = nil },
            { $0.startedAt = self.now.addingTimeInterval(9) },
            { $0.items.removeLast() },
            { $0.items.reverse() },
            { $0.items[0].title = "Different step" },
            { $0.items[0].priority = .high },
            { $0.items[0].checkedAt = nil },
        ]
        for change in changes { try assertRejected(mutatedArchive(original, change)) }
    }

    func testRejectsChangedDecisionHistoryAndWrongActors() throws {
        let original = try completedMixedState()
        let changes: [(inout TextArchive) -> Void] = [
            { $0.items[1].decisions.removeFirst() },
            { $0.items[1].decisions.removeLast() },
            { $0.items[1].decisions[0].note = "Changed note" },
            { $0.items[1].decisions[0].actorID = self.performer },
            { $0.items[1].decisions[1].actorID = self.outsider },
            { $0.items[1].decisions[1].verdict = .requestedAnother },
            { $0.items[0].decisions = $0.items[1].decisions },
        ]
        for change in changes { try assertRejected(mutatedArchive(original, change)) }
    }

    func testRejectsFinalDecisionForNeverSubmittedItem() throws {
        let original = try canceledNeverSubmittedState()
        var inventedDecision = try canceledState(reviewed: true).archives[0].items[0].decisions[0]
        inventedDecision.submissionVersion = 0
        try assertRejected(mutatedArchive(original) { $0.items[0].decisions = [inventedDecision] })
    }

    func testRejectsFinalDecisionWithInvalidVerdictNote() throws {
        let requested = try canceledState(reviewed: true)
        try assertRejected(mutatedArchive(requested) { $0.items[0].decisions[0].note = nil })
        try assertRejected(mutatedArchive(requested) { $0.items[0].decisions[0].note = "  \n  " })

        let approved = try completedMixedState()
        try assertRejected(mutatedArchive(approved) { $0.items[1].decisions[1].note = "Unexpected note" })
    }

    func testRejectsCompletedRunWithMatchingUncheckedStandardArchive() throws {
        let completed = try completedMixedState()
        var run = completed.runs[0]
        var archive = completed.archives[0]
        run.items[0].checkedAt = nil
        archive.items[0].checkedAt = nil
        let malformed = SecondLookState(routines: completed.routines, runs: [run], archives: [archive])
        try assertRejected(malformed)
    }

    func testValidTerminalArchivesRestoreAndCleanupAcknowledgmentPersists() throws {
        var completed = try completedMixedState()
        var canceled = try canceledState()
        let canceledAfterReview = try canceledState(reviewed: true)
        let canceledBeforeEvidence = try canceledNeverSubmittedState()
        let canceledUncheckedStandard = try canceledUncheckedStandardState()
        var standardOnly = SecondLookState()
        let standardRunID = try standardOnly.startOneOff(title: "Simple", items: [RoutineItem(title: "Door")],
                                                         performerID: performer, reviewerID: nil, now: now)
        try standardOnly.setStandardChecked(runID: standardRunID, itemID: standardOnly.runs[0].items[0].id,
                                            checked: true, actorID: performer, now: now)
        XCTAssertEqual(completed.archives[0].items[1].decisions.map(\.submissionVersion), [1, 2])
        XCTAssertTrue(canceled.archives[0].items[0].decisions.isEmpty)
        XCTAssertEqual(canceledAfterReview.archives[0].items[0].decisions.map(\.verdict), [.requestedAnother])
        XCTAssertEqual(canceledBeforeEvidence.runs[0].items[0].lastVersion, 0)
        XCTAssertTrue(canceledBeforeEvidence.archives[0].items[0].decisions.isEmpty)
        XCTAssertNil(canceledUncheckedStandard.archives[0].items[0].checkedAt)
        XCTAssertTrue(standardOnly.archives[0].items[0].decisions.isEmpty)
        for state in [completed, canceled, canceledAfterReview, canceledBeforeEvidence,
                      canceledUncheckedStandard, standardOnly] {
            try state.validateForLoad()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = JSONStateStore(url: directory.appendingPathComponent("state.json"))
            try store.save(state)
            XCTAssertEqual(try store.load(), state)
            try SharedSnapshot(spaceID: UUID(), revision: 1,
                               members: [performer, reviewer], state: state).validate(for: performer)
        }
        try completed.confirmSimulatedCleanup(runID: completed.runs[0].id)
        try canceled.confirmSimulatedCleanup(runID: canceled.runs[0].id)
        for state in [completed, canceled] {
            XCTAssertEqual(state.runs[0].cleanupStatus, .simulatedConfirmed)
            XCTAssertEqual(state.archives[0].cleanupStatus, .simulatedConfirmed)
            try state.validateForLoad()
        }
    }
}
