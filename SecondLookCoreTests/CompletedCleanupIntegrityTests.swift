import Foundation
import XCTest
import SecondLookCore

final class CompletedCleanupIntegrityTests: XCTestCase {
    private let performer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let reviewer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func completedHighPriorityRun() throws -> SecondLookState {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Stove", items: [RoutineItem(title: "Check stove", priority: .high)],
                                          performerID: performer, reviewerID: reviewer, now: now)
        let itemID = state.runs[0].items[0].id
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: performer,
                               fixtureID: "synthetic-only", source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: runID, itemID: itemID, actorID: performer, now: now)
        try state.acceptSend(runID: runID, itemID: itemID, actorID: performer,
                             expectedVersion: version, now: now)
        try state.approve(runID: runID, itemID: itemID, actorID: reviewer,
                          expectedVersion: version, now: now)
        XCTAssertEqual(state.runs[0].outcome, .completed)
        XCTAssertEqual(state.runs[0].cleanupStatus, .pending)
        return state
    }

    private func assertRejected(_ state: SecondLookState) throws {
        XCTAssertThrowsError(try state.validateForLoad()) {
            XCTAssertEqual($0 as? SecondLookError, .corruptDocument)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONStateStore(url: directory.appendingPathComponent("state.json"))
        try store.save(state)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? SecondLookError, .corruptDocument)
        }
        XCTAssertThrowsError(try SharedSnapshot(spaceID: UUID(), revision: 1,
                                                members: [performer, reviewer], state: state)
            .validate(for: performer)) {
            XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
        }
    }

    private func assertAccepted(_ state: SecondLookState) throws {
        try state.validateForLoad()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONStateStore(url: directory.appendingPathComponent("state.json"))
        try store.save(state)
        XCTAssertEqual(try store.load(), state)
        try SharedSnapshot(spaceID: UUID(), revision: 1,
                           members: [performer, reviewer], state: state).validate(for: performer)
    }

    func testCompletedHighPriorityRunCannotClaimNoCleanupInRunAndArchive() throws {
        let completed = try completedHighPriorityRun()
        var run = completed.runs[0]
        var archive = completed.archives[0]
        run.cleanupStatus = .notNeeded
        archive.cleanupStatus = .notNeeded
        try assertRejected(SecondLookState(runs: [run], archives: [archive]))
    }

    func testCompletedHighPriorityCleanupPendingAndConfirmedRemainValid() throws {
        var state = try completedHighPriorityRun()
        try assertAccepted(state)
        try state.confirmSimulatedCleanup(runID: state.runs[0].id)
        XCTAssertEqual(state.runs[0].cleanupStatus, .simulatedConfirmed)
        try assertAccepted(state)
    }

    func testCompletedStandardAndCanceledUnsubmittedHighNeedNoCleanup() throws {
        var standard = SecondLookState()
        let standardID = try standard.startOneOff(title: "Keys", items: [RoutineItem(title: "Carry keys")],
                                                  performerID: performer, reviewerID: nil, now: now)
        try standard.setStandardChecked(runID: standardID, itemID: standard.runs[0].items[0].id,
                                        checked: true, actorID: performer, now: now)
        XCTAssertEqual(standard.runs[0].cleanupStatus, .notNeeded)
        try assertAccepted(standard)

        var canceled = SecondLookState()
        let canceledID = try canceled.startOneOff(title: "Stove", items: [RoutineItem(title: "Check stove", priority: .high)],
                                                  performerID: performer, reviewerID: reviewer, now: now)
        try canceled.cancel(runID: canceledID, actorID: performer, now: now)
        XCTAssertEqual(canceled.runs[0].cleanupStatus, .notNeeded)
        try assertAccepted(canceled)
    }
}
