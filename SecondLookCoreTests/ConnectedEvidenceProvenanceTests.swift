import Foundation
import XCTest
import SecondLookCore

final class ConnectedEvidenceProvenanceTests: XCTestCase {
    private let performer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let reviewer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let connectedFixture = "M2-SYNTHETIC-NO-REAL-PHOTO"

    private func acceptedState(verdict: ReviewVerdict? = nil) throws -> SecondLookState {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Departure", items: [
            RoutineItem(title: "Keys"), RoutineItem(title: "Stove", priority: .high),
        ], performerID: performer, reviewerID: reviewer, now: now)
        let itemID = state.runs[0].items[1].id
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: performer,
                               fixtureID: connectedFixture, source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: runID, itemID: itemID, actorID: performer, now: now)
        try state.acceptSend(runID: runID, itemID: itemID, actorID: performer,
                             expectedVersion: version, now: now)
        switch verdict {
        case .approved:
            try state.approve(runID: runID, itemID: itemID, actorID: reviewer,
                              expectedVersion: version, now: now)
        case .requestedAnother:
            try state.requestAnother(runID: runID, itemID: itemID, actorID: reviewer,
                                     expectedVersion: version, note: "One more", now: now)
        case nil: break
        }
        XCTAssertTrue(state.runs[0].isOpen, "The unchecked standard item keeps current evidence visible")
        return state
    }

    private func assertLocalAcceptedButConnectedRejected(_ state: SecondLookState,
                                                          file: StaticString = #filePath,
                                                          line: UInt = #line) throws {
        try state.validateForLoad()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONStateStore(url: directory.appendingPathComponent("state.json"))
        try store.save(state)
        XCTAssertEqual(try store.load(), state, file: file, line: line)
        XCTAssertThrowsError(try SharedSnapshot(spaceID: UUID(), revision: 1,
                                                members: [performer, reviewer], state: state)
            .validate(for: performer), file: file, line: line) {
            XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    func testConnectedSnapshotsAcceptOnlyExactSyntheticEvidenceMetadata() throws {
        for verdict in [nil, .approved, .requestedAnother] as [ReviewVerdict?] {
            let valid = try acceptedState(verdict: verdict)
            try valid.validateForLoad()
            try SharedSnapshot(spaceID: UUID(), revision: 1,
                               members: [performer, reviewer], state: valid).validate(for: performer)

            var changedFixture = valid.runs[0]
            changedFixture.items[1].submission?.fixtureID = "different-synthetic-token"
            try assertLocalAcceptedButConnectedRejected(SecondLookState(runs: [changedFixture]))

            var changedSource = valid.runs[0]
            changedSource.items[1].submission?.source = .simulatedLibrary
            try assertLocalAcceptedButConnectedRejected(SecondLookState(runs: [changedSource]))
        }
    }
}
