#if SECONDLOOK_DEMO
import Foundation
import SecondLookCore

/// Explicit Debug acceptance against an already paired private service. Every new record uses
/// invented text; the runner never edits, deletes, or resets records that were already present.
enum SharedCommandAcceptanceChecks {
    enum StepID: String, CaseIterable, Sendable {
        case pairedSpace, acceptedSave, identicalRetry, changedBodyCollision
        case staleSpace, staleRoutine, conflictingWrites, snapshotIsolation
        case terminalRace, closedMutation, textArchive, performerReviewDenied
    }

    struct Step: Sendable {
        let id: StepID
        let passed: Bool
    }

    struct Report: Sendable {
        let steps: [Step]
        var allPassed: Bool { steps.count == StepID.allCases.count && steps.allSatisfy(\.passed) }
        var firstFailedStepID: StepID? { steps.first(where: { !$0.passed })?.id }
    }

    private struct CheckFailed: Error {}

    static func run(client: SharedHTTPClient, accountID: UUID) async -> Report {
        var passed = Set<StepID>()
        func require(_ condition: Bool, _ step: StepID) throws {
            guard condition else { throw CheckFailed() }
            passed.insert(step)
        }
        func snapshot() async throws -> SharedSnapshot {
            try Task.checkCancellation()
            let value = try await client.currentSpace()
            try value.validate(for: accountID)
            return value
        }
        func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
            try Task.checkCancellation()
            let result = try await client.execute(envelope)
            try result.snapshot.validate(for: accountID)
            return result
        }
        func envelope(_ current: SharedSnapshot, _ command: SharedCommand,
                      id: UUID = UUID()) -> SharedCommandEnvelope {
            SharedCommandEnvelope(spaceID: current.spaceID, commandID: id,
                                  expectedSpaceRevision: current.revision, command: command)
        }
        func rejects(_ expected: SharedStateFailure,
                     _ command: SharedCommandEnvelope) async throws -> Bool {
            try Task.checkCancellation()
            do { _ = try await execute(command); return false }
            catch is CancellationError { throw CancellationError() }
            catch let actual as SharedStateFailure { return actual == expected }
            catch { return false }
        }
        func attempt(_ command: SharedCommandEnvelope) async -> Result<SharedCommandResult, Error> {
            do { return .success(try await execute(command)) }
            catch { return .failure(error) }
        }

        do {
            let initial = try await snapshot()
            try require(initial.members.count == 2 && initial.members.contains(accountID), .pairedSpace)
            let originalRoutines = initial.state.routines
            let originalRuns = initial.state.runs
            let originalArchives = initial.state.archives
            let marker = UUID().uuidString.prefix(8)
            let routine = Routine(title: "Acceptance routine \(marker)", items: [
                RoutineItem(title: "Acceptance first step"),
                RoutineItem(title: "Acceptance second step")
            ])
            let save = envelope(initial, .saveRoutine(definition: routine, expectedDefinitionVersion: nil))
            let saved = try await execute(save)
            let afterSave = try await snapshot()
            try require(saved.snapshot.revision == initial.revision + 1 &&
                        afterSave.state.routines.filter({ $0.id == routine.id }).count == 1 &&
                        afterSave.revision == saved.snapshot.revision, .acceptedSave)

            let replay = try await execute(save)
            let afterReplay = try await snapshot()
            try require(replay.snapshot.revision == saved.snapshot.revision &&
                        afterReplay.revision == afterSave.revision &&
                        afterReplay.state.routines.filter({ $0.id == routine.id }).count == 1,
                        .identicalRetry)

            var changedBody = routine
            changedBody.title += " altered"
            let colliding = SharedCommandEnvelope(spaceID: save.spaceID, commandID: save.commandID,
                expectedSpaceRevision: save.expectedSpaceRevision,
                command: .saveRoutine(definition: changedBody, expectedDefinitionVersion: nil))
            let collisionDenied = try await rejects(.staleState, colliding)
            let afterCollision = try await snapshot()
            try require(collisionDenied && afterCollision == afterReplay, .changedBodyCollision)

            let stale = envelope(initial, .startRun(routineID: routine.id,
                                                     expectedDefinitionVersion: routine.definitionVersion))
            let staleDenied = try await rejects(.staleState, stale)
            let afterStale = try await snapshot()
            try require(staleDenied && afterStale == afterCollision, .staleSpace)

            let started = try await execute(envelope(afterCollision,
                .startRun(routineID: routine.id, expectedDefinitionVersion: routine.definitionVersion)))
            guard let runID = started.createdID,
                  let run = started.snapshot.state.runs.first(where: { $0.id == runID }),
                  run.items.count == 2 else { throw CheckFailed() }

            var edited = routine
            edited.title += " revised"
            edited.items[0].title += " revised"
            let edit = try await execute(envelope(started.snapshot,
                .saveRoutine(definition: edited, expectedDefinitionVersion: routine.definitionVersion)))
            let afterEdit = try await snapshot()
            let oldVersionDenied = try await rejects(.staleState, envelope(afterEdit,
                .saveRoutine(definition: edited, expectedDefinitionVersion: routine.definitionVersion)))
            let afterStaleRoutine = try await snapshot()
            try require(oldVersionDenied && afterStaleRoutine == afterEdit, .staleRoutine)
            let editedRoutine = afterEdit.state.routines.first(where: { $0.id == routine.id })
            let isolatedRun = afterEdit.state.runs.first(where: { $0.id == runID })
            try require(edit.snapshot.revision == afterEdit.revision &&
                        editedRoutine?.definitionVersion == routine.definitionVersion + 1 &&
                        isolatedRun?.routineVersion == routine.definitionVersion &&
                        isolatedRun?.title == routine.title &&
                        isolatedRun?.items.map(\.title) == routine.items.map(\.title),
                        .snapshotIsolation)

            let first = envelope(afterEdit, .setStandardChecked(runID: runID,
                itemID: run.items[0].id, checked: true, expectedRunRevision: run.revision))
            let second = envelope(afterEdit, .setStandardChecked(runID: runID,
                itemID: run.items[1].id, checked: true, expectedRunRevision: run.revision))
            try Task.checkCancellation()
            async let firstResult = attempt(first)
            async let secondResult = attempt(second)
            let results = await (firstResult, secondResult)
            try Task.checkCancellation()
            let acceptedCount = [results.0, results.1].filter { if case .success = $0 { return true }; return false }.count
            let staleCount = [results.0, results.1].filter {
                if case let .failure(error) = $0 { return (error as? SharedStateFailure) == .staleState }
                return false
            }.count
            let afterConflict = try await snapshot()
            let conflictedRun = afterConflict.state.runs.first(where: { $0.id == runID })
            try require(acceptedCount == 1 && staleCount == 1 &&
                        afterConflict.revision == afterEdit.revision + 1 &&
                        conflictedRun?.revision == run.revision + 1 &&
                        conflictedRun?.isOpen == true &&
                        conflictedRun?.items.filter({ $0.checkedAt != nil }).count == 1,
                        .conflictingWrites)

            let raceStart = try await execute(envelope(afterConflict, .startOneOff(
                title: "Acceptance terminal race \(marker)",
                items: [RoutineItem(title: "Acceptance final check")], settings: .init())))
            guard let raceID = raceStart.createdID,
                  let raceRun = raceStart.snapshot.state.runs.first(where: { $0.id == raceID }),
                  let raceItem = raceRun.items.first else { throw CheckFailed() }
            let finalCheck = envelope(raceStart.snapshot, .setStandardChecked(runID: raceID,
                itemID: raceItem.id, checked: true, expectedRunRevision: raceRun.revision))
            let cancel = envelope(raceStart.snapshot, .cancel(runID: raceID,
                                                             expectedRunRevision: raceRun.revision))
            try Task.checkCancellation()
            async let checkedResult = attempt(finalCheck)
            async let canceledResult = attempt(cancel)
            let raceResults = await (checkedResult, canceledResult)
            try Task.checkCancellation()
            let winners = [raceResults.0, raceResults.1].filter { if case .success = $0 { return true }; return false }.count
            let losers = [raceResults.0, raceResults.1].filter {
                if case let .failure(error) = $0 { return (error as? SharedStateFailure) == .staleState }
                return false
            }.count
            let afterRace = try await snapshot()
            let closed = afterRace.state.runs.first(where: { $0.id == raceID })
            let archived = afterRace.state.archives.filter { $0.id == raceID }
            try require(winners == 1 && losers == 1 &&
                        afterRace.revision == raceStart.snapshot.revision + 1 &&
                        closed?.isOpen == false && archived.count == 1 &&
                        archived.first?.outcome == closed?.outcome, .terminalRace)

            guard let closed else { throw CheckFailed() }
            let closedDenied = try await rejects(.domain(.closed), envelope(afterRace,
                .setStandardChecked(runID: raceID, itemID: raceItem.id, checked: false,
                                    expectedRunRevision: closed.revision)))
            let afterClosedAttempt = try await snapshot()
            try require(closedDenied && afterClosedAttempt == afterRace, .closedMutation)
            try require(archived.first?.items.count == 1 &&
                        archived.first?.items.first?.title == "Acceptance final check" &&
                        afterRace.state.archives.filter({ $0.id == raceID }).count == 1 &&
                        afterRace.state.runs.first(where: { $0.id == raceID })?.items.allSatisfy({
                            $0.submission == nil && $0.preview == nil
                        }) == true, .textArchive)

            let highStart = try await execute(envelope(afterClosedAttempt, .startOneOff(
                title: "Acceptance reviewer denial \(marker)",
                items: [RoutineItem(title: "Acceptance required review", priority: .high)],
                settings: .init())))
            guard let highID = highStart.createdID,
                  let highRun = highStart.snapshot.state.runs.first(where: { $0.id == highID }),
                  let highItem = highRun.items.first,
                  highRun.performerID == accountID, highRun.reviewerID != accountID,
                  highItem.submission == nil else { throw CheckFailed() }
            let selfReviewDenied = try await rejects(.domain(.unauthorized), envelope(highStart.snapshot,
                .approve(runID: highID, itemID: highItem.id, expectedVersion: 1,
                         expectedRunRevision: highRun.revision)))
            let afterSelfReview = try await snapshot()
            let canceledHigh = try await execute(envelope(afterSelfReview,
                .cancel(runID: highID, expectedRunRevision: highRun.revision)))
            let afterHighCancel = try await snapshot()
            try require(selfReviewDenied && afterSelfReview == highStart.snapshot &&
                        canceledHigh.snapshot.state.runs.first(where: { $0.id == highID })?.outcome == .canceled &&
                        afterHighCancel.state.archives.filter({ $0.id == highID }).count == 1,
                        .performerReviewDenied)

            // A final fetch proves pre-existing records remained untouched by the acceptance run.
            passed.remove(.pairedSpace)
            try require(originalRoutines.allSatisfy(afterHighCancel.state.routines.contains) &&
                        originalRuns.allSatisfy(afterHighCancel.state.runs.contains) &&
                        originalArchives.allSatisfy(afterHighCancel.state.archives.contains),
                        .pairedSpace)
        } catch {
            // A rejected or interrupted stage leaves later fixed IDs false. Never surface provider
            // errors, account data, snapshots, tokens, or request contents in the report.
        }
        return Report(steps: StepID.allCases.map { Step(id: $0, passed: passed.contains($0)) })
    }
}
#endif
