import Foundation
import XCTest
import SecondLookCore

final class OpenRunIntegrityTests: XCTestCase {
    private let performer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let reviewer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func partiallyCheckedStandardRun() throws -> SecondLookState {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Departure", items: [
            RoutineItem(title: "Keys"), RoutineItem(title: "Door"),
        ], performerID: performer, reviewerID: nil, now: now)
        try state.setStandardChecked(runID: runID, itemID: state.runs[0].items[0].id,
                                     checked: true, actorID: performer, now: now)
        XCTAssertTrue(state.runs[0].isOpen)
        XCTAssertFalse(state.runs[0].isSatisfied)
        return state
    }

    private func reviewedHighPriorityRun() throws -> SecondLookState {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Departure", items: [
            RoutineItem(title: "Door"), RoutineItem(title: "Stove", priority: .high),
        ], performerID: performer, reviewerID: reviewer, now: now)
        let highID = state.runs[0].items[1].id
        try state.prepareDraft(runID: runID, itemID: highID, actorID: performer,
                               fixtureID: "synthetic-first", source: .simulatedCamera, now: now)
        let first = try state.beginSend(runID: runID, itemID: highID, actorID: performer, now: now)
        try state.acceptSend(runID: runID, itemID: highID, actorID: performer,
                             expectedVersion: first, now: now)
        try state.requestAnother(runID: runID, itemID: highID, actorID: reviewer,
                                 expectedVersion: first, note: "Another view", now: now)
        try state.prepareDraft(runID: runID, itemID: highID, actorID: performer,
                               fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
        let second = try state.beginSend(runID: runID, itemID: highID, actorID: performer, now: now)
        try state.acceptSend(runID: runID, itemID: highID, actorID: performer,
                             expectedVersion: second, now: now)
        try state.approve(runID: runID, itemID: highID, actorID: reviewer,
                          expectedVersion: second, now: now)
        XCTAssertTrue(state.runs[0].isOpen, "The standard item is still unchecked")
        XCTAssertFalse(state.runs[0].isSatisfied)
        XCTAssertEqual(state.runs[0].items[1].priorDecisions.count, 1)
        return state
    }

    private func replacingRun(_ original: SecondLookState,
                              change: (inout ChecklistRun) -> Void) -> SecondLookState {
        var run = original.runs[0]
        change(&run)
        return SecondLookState(routines: original.routines, runs: [run], archives: original.archives)
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
        XCTAssertThrowsError(try SharedSnapshot(spaceID: UUID(), revision: 1,
                                                members: [performer, reviewer], state: state)
            .validate(for: performer), file: file, line: line) {
            XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    private func assertAccepted(_ state: SecondLookState, file: StaticString = #filePath,
                                line: UInt = #line) throws {
        try state.validateForLoad()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONStateStore(url: directory.appendingPathComponent("state.json"))
        try store.save(state)
        XCTAssertEqual(try store.load(), state, file: file, line: line)
        let connected = SharedSnapshot(spaceID: UUID(), revision: 1,
                                       members: [performer, reviewer], state: state)
        #if DEBUG
        try connected.validate(for: performer)
        #else
        if state.runs.contains(where: { $0.items.contains(where: { $0.submission != nil }) }) {
            XCTAssertThrowsError(try connected.validate(for: performer), file: file, line: line) {
                XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse, file: file, line: line)
            }
        } else {
            try connected.validate(for: performer)
        }
        #endif
    }

    func testRejectsSatisfiedStandardRunLeftOpen() throws {
        let open = try partiallyCheckedStandardRun()
        let malformed = replacingRun(open) { $0.items[1].checkedAt = now }
        XCTAssertTrue(malformed.runs[0].isOpen)
        XCTAssertTrue(malformed.runs[0].isSatisfied)
        try assertRejected(malformed)
    }

    func testRejectsApprovedHighPriorityRunLeftOpenAfterStandardCheck() throws {
        let open = try reviewedHighPriorityRun()
        let malformed = replacingRun(open) { $0.items[0].checkedAt = now }
        XCTAssertTrue(malformed.runs[0].isOpen)
        XCTAssertTrue(malformed.runs[0].isSatisfied)
        try assertRejected(malformed)
    }

    func testRejectsSatisfiedCanceledRunEvenWhenArchiveMirrorsEveryCheck() throws {
        var canceled = try partiallyCheckedStandardRun()
        try canceled.cancel(runID: canceled.runs[0].id, actorID: performer, now: now)
        XCTAssertEqual(canceled.runs[0].outcome, .canceled)
        XCTAssertFalse(canceled.runs[0].isSatisfied)
        try assertAccepted(canceled)

        var run = canceled.runs[0]
        var archive = canceled.archives[0]
        run.items[1].checkedAt = now
        archive.items[1].checkedAt = now
        let malformed = SecondLookState(routines: canceled.routines, runs: [run], archives: [archive])
        XCTAssertEqual(malformed.runs[0].outcome, .canceled)
        XCTAssertTrue(malformed.runs[0].isSatisfied)
        try assertRejected(malformed)
    }

    func testValidUnsatisfiedOpenAndClosedHistoryStillLoads() throws {
        let partialStandards = try partiallyCheckedStandardRun()
        let approvedHighWithUncheckedStandard = try reviewedHighPriorityRun()
        var completed = approvedHighWithUncheckedStandard
        let completedRun = completed.runs[0]
        try completed.setStandardChecked(runID: completedRun.id, itemID: completedRun.items[0].id,
                                         checked: true, actorID: performer, now: now)
        XCTAssertEqual(completed.runs[0].outcome, .completed)
        XCTAssertEqual(completed.archives[0].items[1].decisions.count, 2)
        var canceled = approvedHighWithUncheckedStandard
        try canceled.cancel(runID: canceled.runs[0].id, actorID: performer, now: now)
        XCTAssertEqual(canceled.runs[0].outcome, .canceled)
        for state in [partialStandards, approvedHighWithUncheckedStandard, completed, canceled] {
            try assertAccepted(state)
        }
    }
}
