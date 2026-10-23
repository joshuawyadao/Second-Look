import XCTest
@testable import SecondLookCore

final class SharedAggregateCapacityTests: XCTestCase {
    private let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    private let peer = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    private let space = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(_ state: SecondLookState = .init(), revision: Int = 0) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision, members: [owner, peer], state: state)
    }

    private func apply(_ command: SharedCommand, to current: SharedSnapshot,
                       actor: UUID? = nil) throws -> SharedSnapshot {
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
                                             expectedSpaceRevision: current.revision, command: command)
        return try SharedCommandProcessor.apply(envelope, to: current,
                                                actorID: actor ?? owner, now: now).snapshot
    }

    func testConnectedTextUsesUTF8ByteLimits() throws {
        let boundary = Routine(title: String(repeating: "é", count: 128),
                               items: [RoutineItem(title: "A", photoInstructions: String(repeating: "é", count: 512))])
        _ = try apply(.saveRoutine(definition: boundary, expectedDefinitionVersion: nil), to: snapshot())

        let longTitle = Routine(title: String(repeating: "é", count: 129), items: [RoutineItem(title: "A")])
        XCTAssertThrowsError(try apply(.saveRoutine(definition: longTitle, expectedDefinitionVersion: nil), to: snapshot())) {
            XCTAssertEqual($0 as? SharedStateFailure, .domain(.invalidDefinition))
        }
        let longInstruction = Routine(title: "A", items: [RoutineItem(title: "B",
                                                photoInstructions: String(repeating: "é", count: 513))])
        XCTAssertThrowsError(try apply(.saveRoutine(definition: longInstruction, expectedDefinitionVersion: nil), to: snapshot())) {
            XCTAssertEqual($0 as? SharedStateFailure, .domain(.invalidDefinition))
        }
        XCTAssertThrowsError(try apply(.requestAnother(runID: UUID(), itemID: UUID(), expectedVersion: 1,
                                                      note: String(repeating: "é", count: 1_025),
                                                      expectedRunRevision: 1), to: snapshot())) {
            XCTAssertEqual($0 as? SharedStateFailure, .domain(.invalidDefinition))
        }
    }

    func testConnectedItemsAndRoutineCollectionsAreBounded() throws {
        let sixtyFour = (0..<64).map { RoutineItem(title: "Item \($0)") }
        _ = try apply(.saveRoutine(definition: Routine(title: "At limit", items: sixtyFour),
                                   expectedDefinitionVersion: nil), to: snapshot())
        let tooMany = sixtyFour + [RoutineItem(title: "One more")]
        XCTAssertThrowsError(try apply(.startOneOff(title: "Too many", items: tooMany, settings: .init()), to: snapshot())) {
            XCTAssertEqual($0 as? SharedStateFailure, .domain(.invalidDefinition))
        }
        let filled = SecondLookState(routines: (0..<128).map { Routine(title: "Routine \($0)",
                                              items: [RoutineItem(title: "A")]) })
        try snapshot(filled).validate(for: owner)
        XCTAssertThrowsError(try apply(.saveRoutine(definition: Routine(title: "Overflow",
                                              items: [RoutineItem(title: "A")]),
                                              expectedDefinitionVersion: nil), to: snapshot(filled))) {
            XCTAssertEqual($0 as? SharedStateFailure, .capacityExceeded)
        }
    }

    func testOversizedPersistedSnapshotIsRejectedAsInvalidResponse() throws {
        let oversizedField = SecondLookState(routines: [Routine(title: String(repeating: "é", count: 129),
                                                      items: [RoutineItem(title: "A")])])
        XCTAssertThrowsError(try snapshot(oversizedField).validate(for: owner)) {
            XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
        }

        let largeRoutines = (0..<40).map { index in
            Routine(title: "Large \(index)", items: (0..<64).map { item in
                RoutineItem(title: "Item \(item)", photoInstructions: String(repeating: "x", count: 1_024))
            })
        }
        XCTAssertThrowsError(try snapshot(SecondLookState(routines: largeRoutines)).validate(for: owner)) {
            XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
        }
    }

    func testLocalDemoStateIsNotSubjectToConnectedLimits() throws {
        var local = SecondLookState()
        let longTitle = String(repeating: "é", count: 129)
        let runID = try local.startOneOff(title: longTitle, items: [RoutineItem(title: "A")],
                                          performerID: owner, reviewerID: peer, now: now)
        XCTAssertEqual(local.runs.first { $0.id == runID }?.title, longTitle)
        try local.validateForLoad()
        XCTAssertThrowsError(try snapshot(local).validate(for: owner)) {
            XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
        }
    }

    func testPersistedRunCountIsBoundedEvenWhenEachRunIsSmall() throws {
        var state = SecondLookState()
        for index in 0..<513 {
            _ = try state.startOneOff(title: "Run \(index)", items: [RoutineItem(title: "A")],
                                      performerID: owner, reviewerID: peer, now: now)
        }
        try state.validateForLoad()
        XCTAssertThrowsError(try snapshot(state).validate(for: owner)) {
            XCTAssertEqual($0 as? SharedStateFailure, .invalidResponse)
        }
    }

    func testSmallValidCommandsEventuallyReachCapacityWithoutLosingHistoryOrStrandingClosure() throws {
        let items = (0..<64).map { RoutineItem(title: "Item \($0)",
                                                photoInstructions: String(repeating: "x", count: 1_024)) }
        let routine = Routine(title: "Large but valid", items: items)
        var current = try apply(.saveRoutine(definition: routine, expectedDefinitionVersion: nil), to: snapshot())
        var accepted = 0
        var capacityReached = false
        for _ in 0..<128 {
            do {
                current = try apply(.startRun(routineID: routine.id, expectedDefinitionVersion: 1), to: current)
                accepted += 1
            } catch {
                XCTAssertEqual(error as? SharedStateFailure, .capacityExceeded)
                capacityReached = true
                break
            }
        }
        XCTAssertTrue(capacityReached)
        XCTAssertGreaterThan(accepted, 0)
        XCTAssertLessThan(accepted, 128)
        XCTAssertEqual(current.state.runs.count, accepted)
        XCTAssertTrue(current.state.archives.isEmpty)

        let run = try XCTUnwrap(current.state.runs.first)
        let canceled = try apply(.cancel(runID: run.id, expectedRunRevision: run.revision), to: current)
        XCTAssertEqual(canceled.state.archives.count, 1)
        XCTAssertEqual(canceled.state.runs.first?.outcome, .canceled)
        try canceled.validate(for: owner)
    }

    func testLastStandardCheckCanArchiveAtReservedCapacity() throws {
        let items = (0..<64).map { RoutineItem(title: "Item \($0)",
                                                photoInstructions: String(repeating: "x", count: 1_024)) }
        let routine = Routine(title: "Standard", items: items)
        var current = try apply(.saveRoutine(definition: routine, expectedDefinitionVersion: nil), to: snapshot())
        var reached = false
        for _ in 0..<128 {
            do { current = try apply(.startRun(routineID: routine.id, expectedDefinitionVersion: 1), to: current) }
            catch {
                XCTAssertEqual(error as? SharedStateFailure, .capacityExceeded)
                reached = true
                break
            }
        }
        XCTAssertTrue(reached)
        let firstID = try XCTUnwrap(current.state.runs.first?.id)
        for itemID in current.state.runs[0].items.map(\.id) {
            let revision = try XCTUnwrap(current.state.runs.first { $0.id == firstID }?.revision)
            current = try apply(.setStandardChecked(runID: firstID, itemID: itemID,
                                                    checked: true, expectedRunRevision: revision), to: current)
        }
        XCTAssertEqual(current.state.archives.first?.id, firstID)
        XCTAssertEqual(current.state.runs.first?.outcome, .completed)
    }

    #if DEBUG
    func testReviewRequestReservesTheFinalDecisionSlotForApproval() throws {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Review", items: [RoutineItem(title: "Photo", priority: .high)],
                                          performerID: owner, reviewerID: peer, now: now)
        let itemID = try XCTUnwrap(state.runs.first?.items.first?.id)
        for attempt in 1...64 {
            try state.prepareDraft(runID: runID, itemID: itemID, actorID: owner,
                                   fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
            let version = try state.beginSend(runID: runID, itemID: itemID, actorID: owner, now: now)
            try state.acceptSend(runID: runID, itemID: itemID, actorID: owner,
                                 expectedVersion: version, now: now)
            if attempt < 64 {
                try state.requestAnother(runID: runID, itemID: itemID, actorID: peer,
                                         expectedVersion: version, note: "Try again", now: now)
            }
        }
        let original = snapshot(state)
        try original.validate(for: owner)
        let revision = try XCTUnwrap(original.state.runs.first?.revision)
        XCTAssertEqual(original.state.runs[0].items[0].priorDecisions.count, 63)
        XCTAssertThrowsError(try apply(.requestAnother(runID: runID, itemID: itemID,
                                                      expectedVersion: 64, note: "Again",
                                                      expectedRunRevision: revision),
                                       to: original, actor: peer)) {
            XCTAssertEqual($0 as? SharedStateFailure, .capacityExceeded)
        }
        let approved = try apply(.approve(runID: runID, itemID: itemID,
                                          expectedVersion: 64, expectedRunRevision: revision),
                                 to: original, actor: peer)
        XCTAssertEqual(approved.state.archives[0].items[0].decisions.count, 64)
        XCTAssertEqual(approved.state.runs[0].outcome, .completed)
    }
    #endif
}
