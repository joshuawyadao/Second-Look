import Foundation
import XCTest
import SecondLookCore

final class RoleIntegrityTests: XCTestCase {
    private let performer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let reviewer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testStandardRunCannotAssignPerformerAsReviewerAtCreation() throws {
        var state = SecondLookState()
        XCTAssertThrowsError(try state.startOneOff(title: "Keys", items: [RoutineItem(title: "Carry keys")],
                                                   performerID: performer, reviewerID: performer, now: now))
        XCTAssertTrue(state.runs.isEmpty)
    }

    func testLoadedStandardRunRejectsSelfReviewerAcrossAllBoundaries() throws {
        var original = SecondLookState()
        _ = try original.startOneOff(title: "Keys", items: [RoutineItem(title: "Carry keys")],
                                     performerID: performer, reviewerID: reviewer, now: now)
        var run = original.runs[0]
        run.reviewerID = performer
        let malformed = SecondLookState(runs: [run])
        XCTAssertThrowsError(try malformed.validateForLoad()) {
            XCTAssertEqual($0 as? SecondLookError, .corruptDocument)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONStateStore(url: directory.appendingPathComponent("state.json"))
        try store.save(malformed)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? SecondLookError, .corruptDocument)
        }
        XCTAssertThrowsError(try SharedSnapshot(spaceID: UUID(), revision: 1,
                                                members: [performer, reviewer], state: malformed)
            .validate(for: performer)) {
            XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
        }
    }

    func testStandardRunsWithNoReviewerOrDistinctReviewerRemainValid() throws {
        for reviewerID in [nil, reviewer] as [UUID?] {
            var state = SecondLookState()
            _ = try state.startOneOff(title: "Keys", items: [RoutineItem(title: "Carry keys")],
                                      performerID: performer, reviewerID: reviewerID, now: now)
            try state.validateForLoad()
            try SharedSnapshot(spaceID: UUID(), revision: 1,
                               members: [performer, reviewer], state: state).validate(for: performer)
        }
    }
}
