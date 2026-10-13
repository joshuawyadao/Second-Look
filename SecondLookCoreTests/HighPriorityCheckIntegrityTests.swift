import Foundation
import XCTest
import SecondLookCore

final class HighPriorityCheckIntegrityTests: XCTestCase {
    private let performer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let reviewer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func highPriorityRun() throws -> SecondLookState {
        var state = SecondLookState()
        _ = try state.startOneOff(title: "Stove", items: [RoutineItem(title: "Check stove", priority: .high)],
                                  performerID: performer, reviewerID: reviewer, now: now)
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

    func testRejectsCheckedAtOnOpenHighPriorityItem() throws {
        let original = try highPriorityRun()
        var run = original.runs[0]
        run.items[0].checkedAt = now
        try assertRejected(SecondLookState(runs: [run]))
    }

    func testRejectsCheckedAtOnClosedHighPriorityItemEvenWhenArchiveMatches() throws {
        var original = try highPriorityRun()
        try original.cancel(runID: original.runs[0].id, actorID: performer, now: now)
        var run = original.runs[0]
        var archive = original.archives[0]
        run.items[0].checkedAt = now
        archive.items[0].checkedAt = now
        try assertRejected(SecondLookState(runs: [run], archives: [archive]))
    }

    func testHighPriorityEvidenceAndStandardChecksKeepTheirSeparateFields() throws {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Departure", items: [
            RoutineItem(title: "Keys"), RoutineItem(title: "Stove", priority: .high),
        ], performerID: performer, reviewerID: reviewer, now: now)
        try state.setStandardChecked(runID: runID, itemID: state.runs[0].items[0].id,
                                     checked: true, actorID: performer, now: now)
        XCTAssertNotNil(state.runs[0].items[0].checkedAt)
        XCTAssertNil(state.runs[0].items[1].checkedAt)
        try state.validateForLoad()
    }
}
