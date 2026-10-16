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

    private func assertAccepted(_ state: SecondLookState, connected: Bool = true) throws {
        try state.validateForLoad()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONStateStore(url: directory.appendingPathComponent("state.json"))
        try store.save(state)
        XCTAssertEqual(try store.load(), state)
        let snapshot = SharedSnapshot(spaceID: UUID(), revision: 1,
                                      members: [performer, reviewer], state: state)
        if connected {
            try snapshot.validate(for: performer)
        } else {
            let restored = try SharedWireCodec.decode(SharedSnapshot.self,
                                                      from: SharedWireCodec.encode(snapshot))
            for value in [snapshot, restored] {
                XCTAssertThrowsError(try value.validate(for: performer)) {
                    XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
                }
            }
        }
    }

    func testCompletedHighPriorityRunCannotClaimNoCleanupInRunAndArchive() throws {
        let completed = try completedHighPriorityRun()
        var run = completed.runs[0]
        var archive = completed.archives[0]
        run.cleanupStatus = .notNeeded
        archive.cleanupStatus = .notNeeded
        try assertRejected(SecondLookState(runs: [run], archives: [archive]))
    }

    func testCompletedCleanupAcknowledgmentRemainsLocalOnly() throws {
        var state = try completedHighPriorityRun()
        try assertAccepted(state)
        try state.confirmSimulatedCleanup(runID: state.runs[0].id)
        XCTAssertEqual(state.runs[0].cleanupStatus, .simulatedConfirmed)
        try assertAccepted(state, connected: false)
    }

    func testCanceledEvidenceCleanupAcknowledgmentRemainsLocalOnly() throws {
        var state = SecondLookState()
        let run = try state.startOneOff(title: "Stove", items: [
            RoutineItem(title: "Check stove", priority: .high)
        ], performerID: performer, reviewerID: reviewer, now: now)
        let item = state.runs[0].items[0].id
        try state.prepareDraft(runID: run, itemID: item, actorID: performer,
            fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: run, itemID: item, actorID: performer, now: now)
        try state.acceptSend(runID: run, itemID: item, actorID: performer,
                             expectedVersion: version, now: now)
        try state.cancel(runID: run, actorID: performer, now: now)
        XCTAssertEqual(state.runs[0].cleanupStatus, .pending)
        try assertAccepted(state)
        try state.confirmSimulatedCleanup(runID: run)
        try assertAccepted(state, connected: false)
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

    func testClosedStandardOnlyRunsRejectInventedCleanupStates() throws {
        var completed = SecondLookState()
        let completedID = try completed.startOneOff(title: "Keys", items: [RoutineItem(title: "Carry keys")],
                                                    performerID: performer, reviewerID: nil, now: now)
        try completed.setStandardChecked(runID: completedID, itemID: completed.runs[0].items[0].id,
                                         checked: true, actorID: performer, now: now)
        var canceled = SecondLookState()
        let canceledID = try canceled.startOneOff(title: "Door", items: [RoutineItem(title: "Lock door")],
                                                  performerID: performer, reviewerID: nil, now: now)
        try canceled.cancel(runID: canceledID, actorID: performer, now: now)
        for original in [completed, canceled] {
            XCTAssertEqual(original.runs[0].cleanupStatus, .notNeeded)
            try assertAccepted(original)
            for status in [CleanupStatus.pending, .simulatedConfirmed] {
                var run = original.runs[0]
                var archive = original.archives[0]
                run.cleanupStatus = status
                archive.cleanupStatus = status
                try assertRejected(SecondLookState(runs: [run], archives: [archive]))
            }
        }
    }
}
