import Foundation
import XCTest
import SecondLookCore

final class RunProvenanceTests: XCTestCase {
    private let performer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func routineBackedState() throws -> SecondLookState {
        var state = SecondLookState()
        let routine = Routine(title: "Departure", items: [RoutineItem(title: "Carry keys")])
        try state.saveRoutine(routine)
        _ = try state.startRun(routineID: routine.id, performerID: performer,
                               reviewerID: nil, now: now)
        return state
    }

    private func oneOffState() throws -> SecondLookState {
        var state = SecondLookState()
        _ = try state.startOneOff(title: "One-off", items: [RoutineItem(title: "Carry keys")],
                                  performerID: performer, reviewerID: nil, now: now)
        return state
    }

    private func changingFirstRun(_ original: SecondLookState,
                                  _ change: (inout ChecklistRun) -> Void) -> SecondLookState {
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
        let snapshot = SharedSnapshot(spaceID: UUID(), revision: 1,
                                      members: [performer], state: state)
        XCTAssertThrowsError(try snapshot.validate(for: performer), file: file, line: line) {
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
        try SharedSnapshot(spaceID: UUID(), revision: 1,
                           members: [performer], state: state).validate(for: performer)
    }

    func testRejectsRoutineBackedRunWithoutPositiveSourceVersion() throws {
        let original = try routineBackedState()
        XCTAssertEqual(original.runs[0].routineVersion, 1)
        for version in [nil, 0, -1] as [Int?] {
            try assertRejected(changingFirstRun(original) { $0.routineVersion = version })
        }
    }

    func testRejectsOneOffRunWithSourceVersion() throws {
        let original = try oneOffState()
        XCTAssertNil(original.runs[0].routineID)
        XCTAssertNil(original.runs[0].routineVersion)
        for version in [0, 1] {
            try assertRejected(changingFirstRun(original) { $0.routineVersion = version })
        }
    }

    func testEditedOrDeletedRoutineDoesNotChangeValidRunProvenance() throws {
        var state = try routineBackedState()
        let run = state.runs[0]
        var edited = state.routines[0]
        edited.title = "Updated departure"
        edited.items = [RoutineItem(title: "Updated step")]
        try state.saveRoutine(edited)
        XCTAssertEqual(state.routines[0].definitionVersion, 2)
        XCTAssertEqual(state.runs[0].routineID, run.routineID)
        XCTAssertEqual(state.runs[0].routineVersion, 1)
        XCTAssertEqual(state.runs[0].title, "Departure")
        XCTAssertEqual(state.runs[0].items[0].title, "Carry keys")
        try assertAccepted(state)

        try state.deleteRoutine(id: edited.id)
        XCTAssertTrue(state.routines.isEmpty)
        try assertAccepted(state)

        try state.setStandardChecked(runID: run.id, itemID: run.items[0].id,
                                     checked: true, actorID: performer, now: now.addingTimeInterval(1))
        XCTAssertEqual(state.archives.count, 1)
        try assertAccepted(state)
        let repeated = try state.repeatRun(runID: run.id, performerID: performer,
                                           reviewerID: nil, now: now.addingTimeInterval(2))
        XCTAssertEqual(state.runs.first(where: { $0.id == repeated })?.routineVersion, 1)
        try assertAccepted(state)
    }

    func testOneOffWithNoSourceRemainsValid() throws {
        try assertAccepted(oneOffState())
    }
}
