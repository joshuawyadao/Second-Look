import Foundation
import XCTest
import SecondLookCore

final class ConnectedSubmissionCounterTests: XCTestCase {
    private let performer = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let reviewer = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func snapshot(counter: Int, priority: ItemPriority = .high) throws -> SharedSnapshot {
        var state = SecondLookState()
        _ = try state.startOneOff(title: "Synthetic counter", items: [
            RoutineItem(title: "Door", priority: priority),
        ], performerID: performer, reviewerID: priority == .high ? reviewer : nil,
            now: Date(timeIntervalSince1970: 1_700_000_000))
        var run = state.runs[0]
        run.items[0].lastVersion = counter
        return SharedSnapshot(spaceID: UUID(), revision: 1, members: [performer, reviewer],
            state: SecondLookState(runs: [run]))
    }

    func testRejectsOverflowingOpenSubmissionCounterBeforeDraftIncrement() throws {
        let malformed = try snapshot(counter: .max)
        XCTAssertNil(malformed.state.runs[0].items[0].submission)
        XCTAssertTrue(malformed.state.runs[0].isOpen)
        XCTAssertThrowsError(try malformed.validate(for: performer)) {
            XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
        }
    }

    func testWireLoadedSubmissionCounterIsAlsoBoundedForEveryItem() throws {
        for priority in [ItemPriority.high, .standard] {
            let encoded = try SharedWireCodec.encode(snapshot(counter: .max, priority: priority))
            let restored = try SharedWireCodec.decode(SharedSnapshot.self, from: encoded)
            XCTAssertThrowsError(try restored.validate(for: performer)) {
                XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
            }
        }
    }

    func testFiniteCounterRetainsRoomForNextDraftVersion() throws {
        for counter in [0, 1, Int.max - 1] {
            let valid = try snapshot(counter: counter)
            XCTAssertNoThrow(try valid.validate(for: performer))
            var state = valid.state
            try state.prepareDraft(runID: state.runs[0].id, itemID: state.runs[0].items[0].id,
                actorID: performer, fixtureID: "synthetic-counter", source: .simulatedCamera,
                now: Date(timeIntervalSince1970: 1_700_000_001))
            XCTAssertEqual(state.runs[0].items[0].preview?.version, counter + 1)
        }
    }
}
