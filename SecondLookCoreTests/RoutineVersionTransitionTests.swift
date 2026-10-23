import Foundation
import XCTest
@testable import SecondLookCore

private actor RoutineVersionClient: SharedStateClient {
    private var current: SharedSnapshot
    private let actorID: UUID
    private let now: Date
    private var override: SharedSnapshot?
    private var receipts: [UUID: SharedCommandResult] = [:]

    init(current: SharedSnapshot, actorID: UUID, now: Date) {
        self.current = current
        self.actorID = actorID
        self.now = now
    }
    func setCurrent(_ view: SharedSnapshot) { current = view }
    func overrideNextCommand(with view: SharedSnapshot) { override = view }
    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        guard current.spaceID == spaceID else { throw SharedStateFailure.scopeMismatch }
        return current
    }
    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        if let receipt = receipts[envelope.commandID] { return receipt }
        let result = try SharedCommandProcessor.apply(envelope, to: current,
                                                      actorID: actorID, now: now)
        current = result.snapshot
        receipts[envelope.commandID] = result
        if let override {
            self.override = nil
            return SharedCommandResult(snapshot: override, createdID: result.createdID)
        }
        return result
    }
}

@MainActor
final class RoutineVersionTransitionTests: XCTestCase {
    private let owner = UUID(uuidString: "A2000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "A2000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "A2000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var scope: SharedAccountScope {
        SharedAccountScope(backend: "routine-version-test", accountID: owner, spaceID: space)
    }

    private func fixture() throws -> (SecondLookState, UUID) {
        var state = SecondLookState()
        let routine = Routine(title: "Invented departure", items: [
            RoutineItem(title: "Keys"), RoutineItem(title: "Door", priority: .high,
                                                    photoInstructions: "Show the lock")
        ])
        try state.saveRoutine(routine)
        var edited = state.routines[0]
        edited.title = "Invented departure, revised"
        try state.saveRoutine(edited)
        return (state, routine.id)
    }

    private func view(_ state: SecondLookState, revision: Int) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision, members: [owner, peer], state: state)
    }

    private func changedRoutine(_ state: SecondLookState,
                                edit: (inout Routine) -> Void) -> SecondLookState {
        var routine = state.routines[0]
        edit(&routine)
        return SecondLookState(routines: [routine], runs: state.runs, archives: state.archives)
    }

    private func expectInvalid(_ coordinator: SharedStateCoordinator,
                               references: [SharedSnapshot] = [],
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await coordinator.refresh(validatingAgainst: references)
            XCTFail("A retained routine regressed or changed at the same definition version",
                    file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse, file: file, line: line)
        }
    }

    func testUnseededReferencesRejectLowerVersionAndEqualVersionDefinitionRewrites() async throws {
        let (state, _) = try fixture()
        let earlier = view(state, revision: 1)
        try earlier.validate(for: owner)
        let rewrites: [SecondLookState] = [
            changedRoutine(state) { $0.definitionVersion -= 1 },
            changedRoutine(state) { $0.title = "Invented replacement" },
            changedRoutine(state) { $0.items[1].priority = .standard },
            changedRoutine(state) { $0.items.swapAt(0, 1) },
            changedRoutine(state) { $0.settings = RunSettings(
                reminders: ReminderPreferences(remindPerformer: true)) },
        ]
        for changed in rewrites {
            let incoming = view(changed, revision: 2)
            try incoming.validate(for: owner)
            let client = RoutineVersionClient(current: incoming, actorID: owner, now: now)
            let coordinator = SharedStateCoordinator()
            coordinator.beginSession(scope: scope, client: client)
            await expectInvalid(coordinator, references: [earlier])
            XCTAssertNil(coordinator.snapshot)
        }
    }

    func testChronologicalReferencesCannotHideTemporaryEqualVersionRewrite() async throws {
        let (state, _) = try fixture()
        let first = view(state, revision: 1)
        let altered = view(changedRoutine(state) { $0.items[0].title = "Rewritten keys" }, revision: 2)
        let restored = view(state, revision: 3)
        try first.validate(for: owner)
        try altered.validate(for: owner)
        try restored.validate(for: owner)
        let client = RoutineVersionClient(current: restored, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        await expectInvalid(coordinator, references: [altered, first])
        XCTAssertNil(coordinator.snapshot)
    }

    func testSeededRefreshRejectsLowerDefinitionVersion() async throws {
        let (state, _) = try fixture()
        let first = view(state, revision: 1)
        let client = RoutineVersionClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let lower = view(changedRoutine(state) { $0.definitionVersion -= 1 }, revision: 2)
        try lower.validate(for: owner)
        await client.setCurrent(lower)
        await expectInvalid(coordinator)
        XCTAssertEqual(coordinator.snapshot, first)
    }

    func testCommandResponseCannotRewriteRoutineAndExactRetryRecovers() async throws {
        let (state, _) = try fixture()
        let first = view(state, revision: 0)
        let client = RoutineVersionClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)
        let command: SharedCommand = .saveRoutine(definition: Routine(title: "Independent",
            items: [RoutineItem(title: "Coat")]), expectedDefinitionVersion: nil)
        let commandID = UUID()
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: commandID,
                                             expectedSpaceRevision: 0, command: command)
        let genuine = try SharedCommandProcessor.apply(envelope, to: first,
                                                       actorID: owner, now: now)
        var rewritten = genuine.snapshot.state.routines
        rewritten[0].title = "Unversioned change"
        let altered = view(SecondLookState(routines: rewritten,
            runs: genuine.snapshot.state.runs, archives: genuine.snapshot.state.archives), revision: 1)
        try altered.validate(for: owner)
        await client.overrideNextCommand(with: altered)
        do {
            _ = try await coordinator.execute(command, commandID: commandID)
            XCTFail("A command response rewrote a retained routine at the same version")
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, .invalidResponse)
        }
        XCTAssertEqual(coordinator.snapshot, first)
        XCTAssertTrue(coordinator.hasUnconfirmedCommand(commandID: commandID))
        XCTAssertFalse(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
        _ = try await coordinator.execute(command, commandID: commandID)
        XCTAssertEqual(coordinator.snapshot, genuine.snapshot)
        XCTAssertFalse(coordinator.hasUnconfirmedCommand(commandID: commandID))
        XCTAssertTrue(coordinator.hasConfirmedReceipt(commandID: commandID, command: command))
    }

    func testProperlyVersionedCoreEditsSameContentDeletionAndNewRoutineStayValid() async throws {
        let (source, routineID) = try fixture()
        let first = view(source, revision: 1)
        let client = RoutineVersionClient(current: first, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let seeded = try await coordinator.refresh()
        XCTAssertTrue(seeded)

        var state = source
        var edited = state.routines[0]
        edited.title = "Next real edit"
        edited.items[1].priority = .standard
        edited.settings = RunSettings(reminders: ReminderPreferences(remindPerformer: true))
        try state.saveRoutine(edited)
        // Model the independent command behind the skipped revision, rather than
        // claiming an invisible paired write with no resulting version/object.
        _ = try state.startOneOff(title: "Independent invented run",
            items: [RoutineItem(title: "Coat")], performerID: owner, reviewerID: peer, now: now)
        let editedView = view(state, revision: 3)
        try editedView.validate(for: owner)
        await client.setCurrent(editedView)
        let publishedEdit = try await coordinator.refresh(validatingAgainst: [first])
        XCTAssertTrue(publishedEdit)
        XCTAssertEqual(editedView.state.routines[0].definitionVersion,
                       first.state.routines[0].definitionVersion + 1)

        try state.saveRoutine(state.routines[0]) // Same content still advances the version.
        let sameContent = view(state, revision: 4)
        await client.setCurrent(sameContent)
        let publishedSameContent = try await coordinator.refresh(validatingAgainst: [editedView])
        XCTAssertTrue(publishedSameContent)
        XCTAssertEqual(sameContent.state.routines[0].title, editedView.state.routines[0].title)

        try state.deleteRoutine(id: routineID)
        try state.saveRoutine(Routine(title: "New independent routine",
            items: [RoutineItem(title: "Lights")]))
        let replacement = view(state, revision: 6)
        try replacement.validate(for: owner)
        await client.setCurrent(replacement)
        let publishedReplacement = try await coordinator.refresh(validatingAgainst: [first, sameContent])
        XCTAssertTrue(publishedReplacement)
        XCTAssertFalse(replacement.state.routines.contains { $0.id == routineID })
        XCTAssertEqual(coordinator.snapshot, replacement)
    }

    func testActualDeleteThenRecreateSameRoutineIDAcrossTwoRevisionsRemainsValid() async throws {
        let (state, routineID) = try fixture()
        let first = view(state, revision: 1)
        let deletion = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 1, command: .deleteRoutine(routineID: routineID,
                expectedDefinitionVersion: state.routines[0].definitionVersion))
        let deleted = try SharedCommandProcessor.apply(deletion, to: first,
                                                       actorID: owner, now: now).snapshot
        XCTAssertFalse(deleted.state.routines.contains { $0.id == routineID })
        var recreatedDefinition = state.routines[0]
        recreatedDefinition.title = "Recreated after deletion"
        let recreation = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 2, command: .saveRoutine(definition: recreatedDefinition,
                                                              expectedDefinitionVersion: nil))
        let recreated = try SharedCommandProcessor.apply(recreation, to: deleted,
                                                         actorID: owner, now: now).snapshot
        try recreated.validate(for: owner)
        XCTAssertEqual(recreated.state.routines[0].id, routineID)
        XCTAssertEqual(recreated.state.routines[0].definitionVersion, 1)

        let client = RoutineVersionClient(current: recreated, actorID: owner, now: now)
        let coordinator = SharedStateCoordinator()
        coordinator.beginSession(scope: scope, client: client)
        let published = try await coordinator.refresh(validatingAgainst: [first, deleted])
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.snapshot, recreated)
    }
}
