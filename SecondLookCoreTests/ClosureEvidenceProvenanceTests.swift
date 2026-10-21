import Foundation
import XCTest
import SecondLookCore

final class ClosureEvidenceProvenanceTests: XCTestCase {
    private let performer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let reviewer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func canceled(_ stage: SubmissionStatus) throws -> SecondLookState {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Synthetic review", items: [
            RoutineItem(title: "Review synthetic evidence", priority: .high)
        ], performerID: performer, reviewerID: reviewer, now: now)
        let itemID = state.runs[0].items[0].id
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: performer,
                               fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
        if stage != .localDraft {
            let version = try state.beginSend(runID: runID, itemID: itemID, actorID: performer, now: now)
            if stage == .uploadFailed {
                try state.failSend(runID: runID, itemID: itemID, actorID: performer,
                                   expectedVersion: version, now: now)
            } else if stage == .waitingForReview {
                try state.acceptSend(runID: runID, itemID: itemID, actorID: performer,
                                     expectedVersion: version, now: now)
            }
        }
        try state.cancel(runID: runID, actorID: performer, now: now)
        return state
    }

    private func unsubmitted() throws -> SecondLookState {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "No evidence", items: [
            RoutineItem(title: "Review synthetic evidence", priority: .high)
        ], performerID: performer, reviewerID: reviewer, now: now)
        try state.cancel(runID: runID, actorID: performer, now: now)
        return state
    }

    private func assertRejectedEverywhere(_ state: SecondLookState, file: StaticString = #filePath,
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
        let snapshot = SharedSnapshot(spaceID: UUID(), revision: 1,
                                      members: [performer, reviewer], state: state)
        let decoded = try SharedWireCodec.decode(SharedSnapshot.self, from: SharedWireCodec.encode(snapshot))
        for candidate in [snapshot, decoded] {
            XCTAssertThrowsError(try candidate.validate(for: performer), file: file, line: line) {
                XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse, file: file, line: line)
            }
        }
    }

    private func jsonObject(_ state: SecondLookState) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    }

    private func decodeObject(_ object: [String: Any]) throws -> SecondLookState {
        try JSONDecoder().decode(SecondLookState.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testCanceledUndecidedEvidenceRejectsMirroredNoCleanup() throws {
        for stage in [SubmissionStatus.localDraft, .sending, .uploadFailed, .waitingForReview] {
            let original = try canceled(stage)
            XCTAssertEqual(original.runs[0].cleanupStatus, .pending)
            XCTAssertTrue(original.archives[0].items[0].decisions.isEmpty)
            try original.validateForLoad()

            var run = original.runs[0]
            var archive = original.archives[0]
            run.cleanupStatus = .notNeeded
            archive.cleanupStatus = .notNeeded
            let changed = SecondLookState(runs: [run], archives: [archive])
            try assertRejectedEverywhere(changed)
        }
    }

    func testClosureFactSurvivesPendingAndLocalAcknowledgment() throws {
        var state = try canceled(.waitingForReview)
        XCTAssertEqual(state.runs[0].hadEvidenceAtClosure, true)
        try state.validateForLoad()
        try SharedSnapshot(spaceID: UUID(), revision: 1,
                           members: [performer, reviewer], state: state).validate(for: performer)
        try state.confirmSimulatedCleanup(runID: state.runs[0].id)
        XCTAssertEqual(state.runs[0].hadEvidenceAtClosure, true)
        XCTAssertEqual(state.runs[0].cleanupStatus, .simulatedConfirmed)
        try state.validateForLoad()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONStateStore(url: directory.appendingPathComponent("state.json"))
        try store.save(state)
        XCTAssertEqual(try store.load(), state)
    }

    func testUnsubmittedDiscardedAndWithdrawnEvidenceNeedNoCleanup() throws {
        var discarded = SecondLookState()
        let discardedID = try discarded.startOneOff(title: "Discard", items: [
            RoutineItem(title: "Review synthetic evidence", priority: .high)
        ], performerID: performer, reviewerID: reviewer, now: now)
        let discardedItem = discarded.runs[0].items[0].id
        try discarded.prepareDraft(runID: discardedID, itemID: discardedItem, actorID: performer,
                                   fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
        try discarded.discardDraft(runID: discardedID, itemID: discardedItem, actorID: performer, now: now)
        try discarded.cancel(runID: discardedID, actorID: performer, now: now)

        var withdrawn = SecondLookState()
        let withdrawnID = try withdrawn.startOneOff(title: "Withdraw", items: [
            RoutineItem(title: "Review synthetic evidence", priority: .high)
        ], performerID: performer, reviewerID: reviewer, now: now)
        let withdrawnItem = withdrawn.runs[0].items[0].id
        try withdrawn.prepareDraft(runID: withdrawnID, itemID: withdrawnItem, actorID: performer,
                                   fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
        let version = try withdrawn.beginSend(runID: withdrawnID, itemID: withdrawnItem,
                                              actorID: performer, now: now)
        try withdrawn.acceptSend(runID: withdrawnID, itemID: withdrawnItem, actorID: performer,
                                 expectedVersion: version, now: now)
        try withdrawn.withdraw(runID: withdrawnID, itemID: withdrawnItem, actorID: performer,
                               expectedVersion: version, now: now)
        try withdrawn.cancel(runID: withdrawnID, actorID: performer, now: now)

        for state in [try unsubmitted(), discarded, withdrawn] {
            XCTAssertEqual(state.runs[0].hadEvidenceAtClosure, false)
            XCTAssertEqual(state.runs[0].cleanupStatus, .notNeeded)
            try state.validateForLoad()
            try SharedSnapshot(spaceID: UUID(), revision: 1,
                               members: [performer, reviewer], state: state).validate(for: performer)
        }
    }

    func testStandardOnlyClosureIsFalseAndFinalDecisionRequiresTrue() throws {
        var standard = SecondLookState()
        let standardID = try standard.startOneOff(title: "Keys", items: [RoutineItem(title: "Carry keys")],
                                                  performerID: performer, reviewerID: nil, now: now)
        try standard.setStandardChecked(runID: standardID, itemID: standard.runs[0].items[0].id,
                                        checked: true, actorID: performer, now: now)
        XCTAssertEqual(standard.runs[0].outcome, .completed)
        XCTAssertEqual(standard.runs[0].hadEvidenceAtClosure, false)
        try standard.validateForLoad()

        var reviewed = SecondLookState()
        let reviewedID = try reviewed.startOneOff(title: "Synthetic departure", items: [
            RoutineItem(title: "Carry keys"),
            RoutineItem(title: "Review synthetic evidence", priority: .high)
        ], performerID: performer, reviewerID: reviewer, now: now)
        let itemID = reviewed.runs[0].items[1].id
        try reviewed.prepareDraft(runID: reviewedID, itemID: itemID, actorID: performer,
                                  fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
        let version = try reviewed.beginSend(runID: reviewedID, itemID: itemID, actorID: performer, now: now)
        try reviewed.acceptSend(runID: reviewedID, itemID: itemID, actorID: performer,
                                expectedVersion: version, now: now)
        try reviewed.requestAnother(runID: reviewedID, itemID: itemID, actorID: reviewer,
                                    expectedVersion: version, note: "Try another synthetic view", now: now)
        try reviewed.cancel(runID: reviewedID, actorID: performer, now: now)
        XCTAssertEqual(reviewed.runs[0].hadEvidenceAtClosure, true)
        XCTAssertEqual(reviewed.archives[0].items[1].decisions.last?.verdict, .requestedAnother)
        try reviewed.validateForLoad()
        var changed = reviewed.runs[0]
        changed.hadEvidenceAtClosure = false
        try assertRejectedEverywhere(SecondLookState(runs: [changed], archives: reviewed.archives))
    }

    func testContradictoryClosureFactAndOpenMarkerReject() throws {
        let pending = try canceled(.waitingForReview)
        var run = pending.runs[0]
        run.hadEvidenceAtClosure = false
        try assertRejectedEverywhere(SecondLookState(runs: [run], archives: pending.archives))

        let absent = try unsubmitted()
        run = absent.runs[0]
        run.hadEvidenceAtClosure = true
        try assertRejectedEverywhere(SecondLookState(runs: [run], archives: absent.archives))

        var open = SecondLookState()
        _ = try open.startOneOff(title: "Open", items: [RoutineItem(title: "Check")],
                                 performerID: performer, reviewerID: nil, now: now)
        run = open.runs[0]
        run.hadEvidenceAtClosure = false
        try assertRejectedEverywhere(SecondLookState(runs: [run]))
    }

    func testVersionedJSONRequiresClosedMarkerAndValidVersion() throws {
        let state = try canceled(.waitingForReview)
        let object = try jsonObject(state)
        XCTAssertEqual(object["closureProvenanceVersion"] as? Int, 1)
        let runs = try XCTUnwrap(object["runs"] as? [[String: Any]])
        XCTAssertEqual(runs[0]["hadEvidenceAtClosure"] as? Bool, true)
        let archives = try XCTUnwrap(object["archives"] as? [[String: Any]])
        XCTAssertNil(archives[0]["hadEvidenceAtClosure"])
        XCTAssertNil(archives[0]["fixtureID"])

        var open = SecondLookState()
        _ = try open.startOneOff(title: "Open", items: [RoutineItem(title: "Check")],
                                 performerID: performer, reviewerID: nil, now: now)
        let openObject = try jsonObject(open)
        XCTAssertEqual(openObject["closureProvenanceVersion"] as? Int, 1)
        let openRuns = try XCTUnwrap(openObject["runs"] as? [[String: Any]])
        XCTAssertNil(openRuns[0]["hadEvidenceAtClosure"])

        for badVersion: Any in [NSNull(), "1", true, 1.5, 2, -1] {
            var changed = object
            changed["closureProvenanceVersion"] = badVersion
            XCTAssertThrowsError(try decodeObject(changed))
        }
        for missingMarker: Any? in [nil, NSNull()] {
            var changed = object
            var changedRuns = runs
            changedRuns[0]["hadEvidenceAtClosure"] = missingMarker
            changed["runs"] = changedRuns
            let decoded = try decodeObject(changed)
            XCTAssertNil(decoded.runs[0].hadEvidenceAtClosure)
            try assertRejectedEverywhere(decoded)
        }
    }

    func testLegacyDocumentMigratesInMemoryAndNextSaveNormalizes() throws {
        for original in [try canceled(.waitingForReview), try unsubmitted()] {
            var legacy = try jsonObject(original)
            legacy.removeValue(forKey: "closureProvenanceVersion")
            var runs = try XCTUnwrap(legacy["runs"] as? [[String: Any]])
            runs[0].removeValue(forKey: "hadEvidenceAtClosure")
            legacy["runs"] = runs
            let legacyStateBytes = try JSONSerialization.data(withJSONObject: legacy)
            let decoded = try JSONDecoder().decode(SecondLookState.self, from: legacyStateBytes)
            XCTAssertEqual(decoded.runs[0].hadEvidenceAtClosure,
                           original.runs[0].cleanupStatus == .notNeeded ? false : true)
            try decoded.validateForLoad()

            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = JSONStateStore(url: directory.appendingPathComponent("state.json"))
            let legacyDocument = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
                                                                              "state": legacy])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try legacyDocument.write(to: store.url)
            XCTAssertEqual(try store.load(), decoded)
            XCTAssertEqual(try Data(contentsOf: store.url), legacyDocument)
            try store.save(decoded)
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
            let savedState = try XCTUnwrap(saved["state"] as? [String: Any])
            XCTAssertEqual(savedState["closureProvenanceVersion"] as? Int, 1)
            let savedRuns = try XCTUnwrap(savedState["runs"] as? [[String: Any]])
            XCTAssertEqual(savedRuns[0]["hadEvidenceAtClosure"] as? Bool,
                           original.runs[0].hadEvidenceAtClosure)

            let snapshot = SharedSnapshot(spaceID: UUID(), revision: 1,
                                          members: [performer, reviewer], state: original)
            var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: SharedWireCodec.encode(snapshot)) as? [String: Any])
            var wireState = try XCTUnwrap(wire["state"] as? [String: Any])
            wireState.removeValue(forKey: "closureProvenanceVersion")
            var wireRuns = try XCTUnwrap(wireState["runs"] as? [[String: Any]])
            wireRuns[0].removeValue(forKey: "hadEvidenceAtClosure")
            wireState["runs"] = wireRuns
            wire["state"] = wireState
            let legacyWire = try JSONSerialization.data(withJSONObject: wire)
            let decodedSnapshot = try SharedWireCodec.decode(SharedSnapshot.self, from: legacyWire)
            try decodedSnapshot.validate(for: performer)
        }
    }

    func testUnversionedMarkerEvenExplicitNullRejectsAndLegacyCorruptionStillValidates() throws {
        let original = try canceled(.waitingForReview)
        var legacy = try jsonObject(original)
        legacy.removeValue(forKey: "closureProvenanceVersion")
        var runs = try XCTUnwrap(legacy["runs"] as? [[String: Any]])
        for value: Any in [true, NSNull()] {
            runs[0]["hadEvidenceAtClosure"] = value
            legacy["runs"] = runs
            XCTAssertThrowsError(try decodeObject(legacy))
        }
        runs[0].removeValue(forKey: "hadEvidenceAtClosure")
        runs[0]["reviewerID"] = runs[0]["performerID"]
        legacy["runs"] = runs
        let decoded = try decodeObject(legacy)
        XCTAssertThrowsError(try decoded.validateForLoad()) {
            XCTAssertEqual($0 as? SecondLookError, .corruptDocument)
        }
    }
}
