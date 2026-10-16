import Foundation
import XCTest
import SecondLookCore

final class CanceledDecisionIntegrityTests: XCTestCase {
    private let performer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let reviewer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func approvedHighWithUncheckedStandard() throws -> SecondLookState {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Departure", items: [
            RoutineItem(title: "Keys"), RoutineItem(title: "Stove", priority: .high),
        ], performerID: performer, reviewerID: reviewer, now: now)
        let highID = state.runs[0].items[1].id
        try state.prepareDraft(runID: runID, itemID: highID, actorID: performer,
                               fixtureID: "synthetic-only", source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: runID, itemID: highID, actorID: performer, now: now)
        try state.acceptSend(runID: runID, itemID: highID, actorID: performer,
                             expectedVersion: version, now: now)
        try state.approve(runID: runID, itemID: highID, actorID: reviewer,
                          expectedVersion: version, now: now)
        XCTAssertTrue(state.runs[0].isOpen)
        return state
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

    func testRejectsCanceledMixedRunWithAllChecksAndFinalApproval() throws {
        var state = try approvedHighWithUncheckedStandard()
        try state.cancel(runID: state.runs[0].id, actorID: performer, now: now)
        var run = state.runs[0]
        var archive = state.archives[0]
        run.items[0].checkedAt = now
        archive.items[0].checkedAt = now
        let malformed = SecondLookState(runs: [run], archives: [archive])
        XCTAssertEqual(malformed.runs[0].outcome, .canceled)
        XCTAssertFalse(malformed.runs[0].isSatisfied, "Closure stripped the approved submission")
        XCTAssertEqual(malformed.archives[0].items[1].decisions.last?.verdict, .approved)
        try assertRejected(malformed)
    }

    func testRejectsCanceledHighOnlyRunWithFinalApproval() throws {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Stove", items: [RoutineItem(title: "Check stove", priority: .high)],
                                          performerID: performer, reviewerID: reviewer, now: now)
        let highID = state.runs[0].items[0].id
        try state.prepareDraft(runID: runID, itemID: highID, actorID: performer,
                               fixtureID: "synthetic-only", source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: runID, itemID: highID, actorID: performer, now: now)
        try state.acceptSend(runID: runID, itemID: highID, actorID: performer,
                             expectedVersion: version, now: now)
        try state.approve(runID: runID, itemID: highID, actorID: reviewer,
                          expectedVersion: version, now: now)
        XCTAssertEqual(state.runs[0].outcome, .completed)
        var run = state.runs[0]
        var archive = state.archives[0]
        run.outcome = .canceled
        archive.outcome = .canceled
        let malformed = SecondLookState(runs: [run], archives: [archive])
        XCTAssertFalse(malformed.runs[0].isSatisfied, "Closure stripped the approved submission")
        try assertRejected(malformed)
    }

    func testPriorWithdrawnApprovalDoesNotMakeCancellationSatisfied() throws {
        var state = try approvedHighWithUncheckedStandard()
        let runID = state.runs[0].id
        let highID = state.runs[0].items[1].id
        let version = state.runs[0].items[1].lastVersion
        try state.withdraw(runID: runID, itemID: highID, actorID: performer,
                           expectedVersion: version, now: now)
        try state.setStandardChecked(runID: runID, itemID: state.runs[0].items[0].id,
                                     checked: true, actorID: performer, now: now)
        try state.cancel(runID: runID, actorID: performer, now: now)
        XCTAssertEqual(state.archives[0].items[1].decisions.map(\.verdict), [.approved])
        XCTAssertEqual(state.runs[0].items[1].priorDecisions.count, 1)
        try assertAccepted(state)
    }

    func testFinalApprovalWithUncheckedStandardRemainsValidCanceledHistory() throws {
        var state = try approvedHighWithUncheckedStandard()
        try state.cancel(runID: state.runs[0].id, actorID: performer, now: now)
        XCTAssertNil(state.archives[0].items[0].checkedAt)
        XCTAssertEqual(state.archives[0].items[1].decisions.last?.verdict, .approved)
        try assertAccepted(state)
    }
}
