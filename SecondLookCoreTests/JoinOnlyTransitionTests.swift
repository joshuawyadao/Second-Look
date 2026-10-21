import Foundation
import XCTest
@testable import SecondLookCore

private actor JoinOnlyClient: SharedStateClient {
    private var current: SharedSnapshot
    init(current: SharedSnapshot) { self.current = current }
    func setCurrent(_ snapshot: SharedSnapshot) { current = snapshot }
    func fetch(spaceID: UUID) async throws -> SharedSnapshot { current }
    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        throw SharedStateFailure.serviceUnavailable
    }
}

@MainActor
final class JoinOnlyTransitionTests: XCTestCase {
    private let owner = UUID(uuidString: "A7000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "A7000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "A7000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func scope(_ actor: UUID? = nil) -> SharedAccountScope {
        SharedAccountScope(backend: "join-only-test", accountID: actor ?? owner, spaceID: space)
    }
    private func view(_ state: SecondLookState, revision: Int,
                      members: [UUID]) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision, members: members, state: state)
    }
    private func fixture() throws -> (SecondLookState, UUID) {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Existing checklist", items: [
            RoutineItem(title: "First"), RoutineItem(title: "Second")
        ], performerID: owner, reviewerID: nil, now: now)
        return (state, runID)
    }
    private func expectInvalid(_ coordinator: SharedStateCoordinator,
                               references: [SharedSnapshot] = [],
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await coordinator.refresh(validatingAgainst: references)
            XCTFail("One adjacent join changed the aggregate state", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    func testUnseededOwnerReferenceRejectsJoinCombinedWithCheckSettingsOrCancel() async throws {
        let (source, runID) = try fixture()
        let first = view(source, revision: 1, members: [owner])
        try first.validate(for: owner)
        let changed: [SecondLookState] = try [
            { var s = source; try s.setStandardChecked(runID: runID,
                itemID: s.runs[0].items[0].id, checked: true, actorID: owner, now: now); return s }(),
            { var s = source; try s.updateRunSettings(runID: runID, actorID: owner,
                settings: RunSettings(reminders: ReminderPreferences(remindPerformer: true))); return s }(),
            { var s = source; try s.cancel(runID: runID, actorID: owner, now: now); return s }(),
        ]
        for state in changed {
            let candidate = view(state, revision: 2, members: [owner, peer])
            try candidate.validate(for: owner)
            try candidate.validate(for: peer)
            let client = JoinOnlyClient(current: candidate)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope(), client: client)
            await expectInvalid(coordinator, references: [first])
            XCTAssertNil(coordinator.snapshot)
        }
    }

    func testChronologicalReferencesAndSeededPublicationRejectMixedJoin() async throws {
        let (source, runID) = try fixture()
        let first = view(source, revision: 1, members: [owner])
        var checked = source
        try checked.setStandardChecked(runID: runID, itemID: source.runs[0].items[0].id,
                                       checked: true, actorID: owner, now: now)
        let middle = view(checked, revision: 2, members: [owner, peer])
        let latest = view(checked, revision: 3, members: [owner, peer])
        try middle.validate(for: owner)
        let client = JoinOnlyClient(current: latest)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(), client: client)
        await expectInvalid(coordinator, references: [middle, first])
        XCTAssertNil(coordinator.snapshot)
        await client.setCurrent(first)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        await client.setCurrent(middle)
        await expectInvalid(coordinator)
        XCTAssertEqual(coordinator.snapshot, first)
    }

    func testGenuineJoinShapeSameMemberWriteAndLargerGapRemainValid() async throws {
        let (source, runID) = try fixture()
        let first = view(source, revision: 1, members: [owner])
        // SQL join adds only the peer; the aggregate is byte-for-byte the same.
        let joined = view(source, revision: 2, members: [owner, peer])
        try await expectPublished(from: first, to: joined, actor: owner)
        let peerClient = JoinOnlyClient(current: joined)
        let peerCoordinator = SharedStateCoordinator()
        peerCoordinator.beginSession(scope: scope(peer), client: peerClient)
        let discovered = try await peerCoordinator.refresh()
        XCTAssertTrue(discovered)
        XCTAssertEqual(peerCoordinator.snapshot, joined)

        var checked = source
        try checked.setStandardChecked(runID: runID, itemID: source.runs[0].items[0].id,
                                       checked: true, actorID: owner, now: now)
        let afterJoinWrite = view(checked, revision: 3, members: [owner, peer])
        try await expectPublished(from: joined, to: afterJoinWrite, actor: owner)
        try await expectPublished(from: first, to: afterJoinWrite, actor: owner)
        let beforeJoinWrite = view(checked, revision: 2, members: [owner])
        try await expectPublished(from: first, to: beforeJoinWrite, actor: owner)
    }

    private func expectPublished(from earlier: SharedSnapshot, to later: SharedSnapshot,
                                 actor: UUID) async throws {
        try earlier.validate(for: actor)
        try later.validate(for: actor)
        let client = JoinOnlyClient(current: later)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope(actor), client: client)
        let published = try await coordinator.refresh(validatingAgainst: [earlier])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, later)
    }
}
