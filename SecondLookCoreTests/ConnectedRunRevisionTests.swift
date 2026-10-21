import Foundation
import XCTest
import SecondLookCore

final class ConnectedRunRevisionTests: XCTestCase {
    private let performer = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let reviewer = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(revision: Int, high: Bool = false) throws -> SharedSnapshot {
        var state = SecondLookState()
        let id = try state.startOneOff(title: "Synthetic revision boundary", items: [
            RoutineItem(title: "Door", priority: high ? .high : .standard)
        ], performerID: performer, reviewerID: high ? reviewer : nil, now: now)
        if high {
            let item = state.runs[0].items[0].id
            try state.prepareDraft(runID: id, itemID: item, actorID: performer,
                fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
            let version = try state.beginSend(runID: id, itemID: item, actorID: performer, now: now)
            try state.acceptSend(runID: id, itemID: item, actorID: performer,
                                 expectedVersion: version, now: now)
        }
        var run = state.runs[0]
        run.revision = revision
        return SharedSnapshot(spaceID: UUID(), revision: 1, members: [performer, reviewer],
                              state: SecondLookState(runs: [run]))
    }

    private func command(_ snapshot: SharedSnapshot, high: Bool = false) -> SharedCommandEnvelope {
        let run = snapshot.state.runs[0]
        return SharedCommandEnvelope(spaceID: snapshot.spaceID, commandID: UUID(),
            expectedSpaceRevision: snapshot.revision,
            command: high ? .approve(runID: run.id, itemID: run.items[0].id,
                expectedVersion: 1, expectedRunRevision: run.revision) :
                .setStandardChecked(runID: run.id, itemID: run.items[0].id,
                    checked: true, expectedRunRevision: run.revision))
    }

    func testUnsafeOpenRevisionsFailValidationBeforeAutomaticClosure() throws {
        for counter in [Int.max - 2, Int.max - 1, Int.max] {
            let original = try snapshot(revision: counter)
            let restored = try SharedWireCodec.decode(SharedSnapshot.self,
                                                      from: SharedWireCodec.encode(original))
            for value in [original, restored] {
                do {
                    try value.validate(for: performer)
                    XCTFail("Open connected runs must reserve both closure increments and a valid result")
                } catch {
                    XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
                    // Only enter the processor after proving the unsafe input is rejected,
                    // so the pre-fix regression reports assertions rather than trapping.
                    XCTAssertThrowsError(try SharedCommandProcessor.apply(command(value), to: value,
                        actorID: performer, now: now)) {
                        XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
                    }
                    XCTAssertTrue(value.state.runs[0].isOpen)
                    XCTAssertEqual(value.state.runs[0].revision, counter)
                }
            }
        }
    }

    func testLastSafeStandardAndHighCommandsProduceValidTerminalSnapshots() throws {
        for high in [false, true] {
            let original = try snapshot(revision: Int.max - 3, high: high)
            #if !DEBUG
            if high {
                try original.state.validateForLoad()
                XCTAssertThrowsError(try original.validate(for: performer)) {
                    XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
                }
                XCTAssertThrowsError(try SharedCommandProcessor.apply(command(original, high: true),
                    to: original, actorID: reviewer, now: now)) {
                    XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
                }
                continue
            }
            #endif
            try original.validate(for: performer)
            let result = try SharedCommandProcessor.apply(command(original, high: high), to: original,
                actorID: high ? reviewer : performer, now: now)
            XCTAssertEqual(result.snapshot.state.runs[0].revision, Int.max - 1)
            XCTAssertEqual(result.snapshot.state.runs[0].outcome, .completed)
            XCTAssertEqual(result.snapshot.state.archives.count, 1)
            XCTAssertNoThrow(try result.snapshot.validate(for: performer))
            XCTAssertTrue(original.state.runs[0].isOpen)
            XCTAssertEqual(original.state.runs[0].revision, Int.max - 3)
            XCTAssertThrowsError(try SharedCommandProcessor.apply(command(result.snapshot),
                to: result.snapshot, actorID: performer, now: now)) {
                XCTAssertEqual($0 as? SharedStateFailure, .domain(.closed))
            }
        }
    }
}
