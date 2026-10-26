import XCTest
@testable import SecondLookCore

final class SharedPollingPolicyTests: XCTestCase {
    func testUnchangedCappedAndChangedReset() {
        var policy = SharedPollingPolicy()
        XCTAssertEqual(policy.nextDelay, 5)
        for expected: TimeInterval in [10, 15, 20, 25, 30, 30] {
            policy.record(.unchanged)
            XCTAssertEqual(policy.nextDelay, expected)
        }
        policy.record(.changed)
        XCTAssertEqual(policy.nextDelay, 5)
        policy.record(.unchanged)
        XCTAssertEqual(policy.nextDelay, 10)
    }

    func testFailuresBackOffAndSuccessClearsStreak() {
        var policy = SharedPollingPolicy()
        for expected: TimeInterval in [5, 10, 20, 40, 80, 120, 120] {
            policy.record(.transientFailure)
            XCTAssertEqual(policy.nextDelay, expected)
        }
        policy.record(.changed)
        policy.record(.transientFailure)
        XCTAssertEqual(policy.nextDelay, 5)
        policy.record(.unchanged)
        policy.record(.transientFailure)
        XCTAssertEqual(policy.nextDelay, 5)
        policy.reset()
        XCTAssertEqual(policy.nextDelay, 5)
    }
}
