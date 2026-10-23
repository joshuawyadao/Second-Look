import Foundation
import XCTest
@testable import SecondLookCore

final class ReleaseEvidenceAdmissionTests: XCTestCase {
    private let performer = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    private let reviewer = UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "40000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func currentSubmission(_ status: SubmissionStatus) throws -> SharedSnapshot {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Invented departure", items: [
            RoutineItem(title: "Keys"), RoutineItem(title: "Door", priority: .high)
        ], performerID: performer, reviewerID: reviewer, now: now)
        let itemID = state.runs[0].items[1].id
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: performer,
                               fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO",
                               source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: runID, itemID: itemID, actorID: performer, now: now)
        try state.acceptSend(runID: runID, itemID: itemID, actorID: performer,
                             expectedVersion: version, now: now)
        switch status {
        case .waitingForReview:
            break
        case .needsAnotherLook:
            try state.requestAnother(runID: runID, itemID: itemID, actorID: reviewer,
                                     expectedVersion: version, note: "Invented detail", now: now)
        case .approved:
            try state.approve(runID: runID, itemID: itemID, actorID: reviewer,
                              expectedVersion: version, now: now)
        default:
            XCTFail("Unsupported test status")
        }
        XCTAssertTrue(state.runs[0].isOpen)
        XCTAssertEqual(state.runs[0].items[1].submission?.status, status)
        return SharedSnapshot(spaceID: space, revision: 1,
                              members: [performer, reviewer], state: state)
    }

    private func assertAdmission(_ snapshot: SharedSnapshot,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let wire = try SharedWireCodec.decode(SharedSnapshot.self,
                                              from: SharedWireCodec.encode(snapshot))
        XCTAssertEqual(wire, snapshot, file: file, line: line)
        let command = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: snapshot.revision,
            command: .saveRoutine(definition: Routine(title: "Invented list",
                items: [RoutineItem(title: "Wallet")]), expectedDefinitionVersion: nil))
        for candidate in [snapshot, wire] {
            #if DEBUG
            XCTAssertNoThrow(try candidate.validate(for: performer), file: file, line: line)
            XCTAssertNoThrow(try SharedCommandProcessor.apply(command, to: candidate,
                actorID: performer, now: now), file: file, line: line)
            #else
            XCTAssertThrowsError(try candidate.validate(for: performer), file: file, line: line) {
                XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse, file: file, line: line)
            }
            XCTAssertThrowsError(try SharedCommandProcessor.apply(command, to: candidate,
                actorID: performer, now: now), file: file, line: line) {
                XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse, file: file, line: line)
            }
            #endif
        }
    }

    func testCurrentSyntheticSubmissionsCannotCrossReleaseConnectedBoundary() throws {
        for status in [SubmissionStatus.waitingForReview, .needsAnotherLook, .approved] {
            try assertAdmission(currentSubmission(status))
        }
    }

    func testStandardOnlyAndTextOnlyClosedHistoryRemainConnectedValid() throws {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Invented standard list",
                                          items: [RoutineItem(title: "Keys")],
                                          performerID: performer, reviewerID: nil, now: now)
        let open = SharedSnapshot(spaceID: space, revision: 1,
                                  members: [performer, reviewer], state: state)
        XCTAssertNoThrow(try open.validate(for: performer))
        try state.setStandardChecked(runID: runID, itemID: state.runs[0].items[0].id,
                                     checked: true, actorID: performer, now: now)
        let closed = SharedSnapshot(spaceID: space, revision: 2,
                                    members: [performer, reviewer], state: state)
        XCTAssertEqual(closed.state.archives.count, 1)
        XCTAssertNoThrow(try closed.validate(for: performer))
        let decoded = try SharedWireCodec.decode(SharedSnapshot.self,
                                                 from: SharedWireCodec.encode(closed))
        XCTAssertNoThrow(try decoded.validate(for: reviewer))
    }
}
