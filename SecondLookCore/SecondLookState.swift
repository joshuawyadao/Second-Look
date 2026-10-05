import Foundation

public struct SecondLookState: Codable, Equatable, Sendable {
    public private(set) var routines: [Routine]
    public private(set) var runs: [ChecklistRun]
    public private(set) var archives: [TextArchive]

    public init(routines: [Routine] = [], runs: [ChecklistRun] = [], archives: [TextArchive] = []) {
        self.routines = routines
        self.runs = runs
        self.archives = archives
    }

    public mutating func saveRoutine(_ routine: Routine) throws {
        try Self.validate(title: routine.title, items: routine.items)
        try Self.validate(settings: routine.settings)
        if let index = routines.firstIndex(where: { $0.id == routine.id }) {
            var updated = routine
            updated.definitionVersion = routines[index].definitionVersion + 1
            routines[index] = updated
        } else {
            routines.append(routine)
        }
    }

    public mutating func deleteRoutine(id: UUID) throws {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { throw SecondLookError.notFound }
        routines.remove(at: index)
    }

    @discardableResult
    public mutating func startRun(routineID: UUID, performerID: UUID, reviewerID: UUID?, now: Date = Date()) throws -> UUID {
        guard let routine = routines.first(where: { $0.id == routineID }) else { throw SecondLookError.notFound }
        return try start(title: routine.title, items: routine.items, settings: routine.settings,
                         routineID: routine.id, routineVersion: routine.definitionVersion,
                         performerID: performerID, reviewerID: reviewerID, now: now)
    }

    @discardableResult
    public mutating func startOneOff(title: String, items: [RoutineItem], settings: RunSettings = .init(),
                                     performerID: UUID, reviewerID: UUID?, now: Date = Date()) throws -> UUID {
        try start(title: title, items: items, settings: settings, routineID: nil, routineVersion: nil,
                  performerID: performerID, reviewerID: reviewerID, now: now)
    }

    @discardableResult
    public mutating func repeatRun(runID: UUID, performerID: UUID, reviewerID: UUID?, now: Date = Date()) throws -> UUID {
        guard let old = runs.first(where: { $0.id == runID }) else { throw SecondLookError.notFound }
        guard !old.isOpen else { throw SecondLookError.invalidTransition }
        let definitions = old.items.map { RoutineItem(title: $0.title, priority: $0.priority, photoInstructions: $0.photoInstructions) }
        return try start(title: old.title, items: definitions, settings: old.settings, routineID: old.routineID,
                         routineVersion: old.routineVersion, performerID: performerID, reviewerID: reviewerID, now: now)
    }

    @discardableResult
    public mutating func saveRunAsRoutine(runID: UUID, title: String? = nil) throws -> UUID {
        guard let run = runs.first(where: { $0.id == runID }) else { throw SecondLookError.notFound }
        let routine = Routine(title: title ?? run.title,
                              items: run.items.map { RoutineItem(title: $0.title, priority: $0.priority, photoInstructions: $0.photoInstructions) },
                              settings: run.settings)
        try saveRoutine(routine)
        return routine.id
    }

    public mutating func setStandardChecked(runID: UUID, itemID: UUID, checked: Bool,
                                            actorID: UUID, now: Date = Date()) throws {
        try updateItem(runID: runID, itemID: itemID, actorID: actorID, role: .performer, now: now) { item, _ in
            guard item.priority == .standard else { throw SecondLookError.wrongItemType }
            item.checkedAt = checked ? now : nil
        }
    }

    /// Updates local preferences only. Reminder delivery and photo expiry are later milestones.
    public mutating func updateRunSettings(runID: UUID, actorID: UUID, settings: RunSettings) throws {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { throw SecondLookError.notFound }
        guard runs[index].isOpen else { throw SecondLookError.closed }
        guard runs[index].performerID == actorID else { throw SecondLookError.unauthorized }
        try Self.validate(settings: settings)
        runs[index].settings = settings
        runs[index].revision += 1
    }

    /// A preview has no effect on current evidence or approval until beginSend.
    public mutating func prepareDraft(runID: UUID, itemID: UUID, actorID: UUID, fixtureID: String,
                                      source: EvidenceSource, now: Date = Date()) throws {
        guard !fixtureID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !fixtureID.contains("/"), !fixtureID.contains(":") else { throw SecondLookError.invalidDefinition }
        try updateItem(runID: runID, itemID: itemID, actorID: actorID, role: .performer, now: now) { item, _ in
            guard item.priority == .high else { throw SecondLookError.wrongItemType }
            item.preview = PhotoSubmission(version: item.lastVersion + 1, fixtureID: fixtureID, source: source,
                                           status: .localDraft, preparedAt: now, acceptedAt: nil, decision: nil)
        }
    }

    public mutating func discardDraft(runID: UUID, itemID: UUID, actorID: UUID, now: Date = Date()) throws {
        try updateItem(runID: runID, itemID: itemID, actorID: actorID, role: .performer, now: now) { item, _ in
            guard item.priority == .high, item.preview != nil else { throw SecondLookError.invalidTransition }
            item.preview = nil
        }
    }

    @discardableResult
    public mutating func beginSend(runID: UUID, itemID: UUID, actorID: UUID, now: Date = Date()) throws -> Int {
        var version = 0
        try updateItem(runID: runID, itemID: itemID, actorID: actorID, role: .performer, now: now) { item, _ in
            guard item.priority == .high, var preview = item.preview else { throw SecondLookError.invalidTransition }
            if let decision = item.submission?.decision { item.priorDecisions.append(decision) }
            preview.status = .sending
            item.submission = preview
            item.preview = nil
            item.lastVersion = preview.version
            version = preview.version
        }
        return version
    }

    public mutating func failSend(runID: UUID, itemID: UUID, actorID: UUID, expectedVersion: Int, now: Date = Date()) throws {
        try changeSubmission(runID: runID, itemID: itemID, actorID: actorID, role: .performer,
                             expectedVersion: expectedVersion, now: now) { submission in
            guard submission.status == .sending else { throw SecondLookError.invalidTransition }
            submission.status = .uploadFailed
        }
    }

    public mutating func retrySend(runID: UUID, itemID: UUID, actorID: UUID, expectedVersion: Int, now: Date = Date()) throws {
        try changeSubmission(runID: runID, itemID: itemID, actorID: actorID, role: .performer,
                             expectedVersion: expectedVersion, now: now) { submission in
            guard submission.status == .uploadFailed else { throw SecondLookError.invalidTransition }
            submission.status = .sending
        }
    }

    public mutating func acceptSend(runID: UUID, itemID: UUID, actorID: UUID, expectedVersion: Int, now: Date = Date()) throws {
        try changeSubmission(runID: runID, itemID: itemID, actorID: actorID, role: .performer,
                             expectedVersion: expectedVersion, now: now) { submission in
            guard submission.status == .sending else { throw SecondLookError.invalidTransition }
            submission.status = .waitingForReview
            submission.acceptedAt = now
        }
    }

    public mutating func approve(runID: UUID, itemID: UUID, actorID: UUID, expectedVersion: Int, now: Date = Date()) throws {
        try changeSubmission(runID: runID, itemID: itemID, actorID: actorID, role: .reviewer,
                             expectedVersion: expectedVersion, now: now) { submission in
            guard submission.status == .waitingForReview else { throw SecondLookError.invalidTransition }
            submission.status = .approved
            submission.decision = ReviewDecision(actorID: actorID, submissionVersion: expectedVersion,
                                                 verdict: .approved, note: nil, decidedAt: now)
        }
    }

    public mutating func requestAnother(runID: UUID, itemID: UUID, actorID: UUID, expectedVersion: Int,
                                        note: String, now: Date = Date()) throws {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SecondLookError.noteRequired }
        try changeSubmission(runID: runID, itemID: itemID, actorID: actorID, role: .reviewer,
                             expectedVersion: expectedVersion, now: now) { submission in
            guard submission.status == .waitingForReview else { throw SecondLookError.invalidTransition }
            submission.status = .needsAnotherLook
            submission.decision = ReviewDecision(actorID: actorID, submissionVersion: expectedVersion,
                                                 verdict: .requestedAnother, note: trimmed, decidedAt: now)
        }
    }

    public mutating func withdraw(runID: UUID, itemID: UUID, actorID: UUID,
                                 expectedVersion: Int, now: Date = Date()) throws {
        try updateItem(runID: runID, itemID: itemID, actorID: actorID, role: .performer, now: now) { item, _ in
            guard item.priority == .high, let current = item.submission else { throw SecondLookError.invalidTransition }
            guard current.version == expectedVersion else { throw SecondLookError.staleVersion }
            if let decision = current.decision { item.priorDecisions.append(decision) }
            item.submission = nil
        }
    }

    public mutating func cancel(runID: UUID, actorID: UUID, now: Date = Date()) throws {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { throw SecondLookError.notFound }
        guard runs[index].isOpen else { throw SecondLookError.closed }
        guard runs[index].performerID == actorID else { throw SecondLookError.unauthorized }
        close(index: index, outcome: .canceled, now: now)
    }

    /// This confirms only a simulated cleanup acknowledgment, never real file deletion.
    public mutating func confirmSimulatedCleanup(runID: UUID) throws {
        guard let runIndex = runs.firstIndex(where: { $0.id == runID }),
              let archiveIndex = archives.firstIndex(where: { $0.id == runID }) else { throw SecondLookError.notFound }
        guard !runs[runIndex].isOpen else { throw SecondLookError.invalidTransition }
        guard runs[runIndex].cleanupStatus == .pending else { throw SecondLookError.invalidTransition }
        runs[runIndex].cleanupStatus = .simulatedConfirmed
        archives[archiveIndex].cleanupStatus = .simulatedConfirmed
    }

    private mutating func start(title: String, items: [RoutineItem], settings: RunSettings,
                                routineID: UUID?, routineVersion: Int?, performerID: UUID,
                                reviewerID: UUID?, now: Date) throws -> UUID {
        try Self.validate(title: title, items: items)
        try Self.validate(settings: settings)
        if items.contains(where: { $0.priority == .high }) {
            guard let reviewerID, reviewerID != performerID else { throw SecondLookError.reviewerRequired }
        }
        let run = ChecklistRun(id: UUID(), routineID: routineID, routineVersion: routineVersion,
                               title: title, items: items.map(RunItem.init(definition:)), settings: settings,
                               performerID: performerID, reviewerID: reviewerID, startedAt: now,
                               outcome: nil, closedAt: nil, revision: 1, cleanupStatus: nil)
        runs.append(run)
        return run.id
    }

    private static func validate(title: String, items: [RoutineItem]) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !items.isEmpty,
              items.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(items.map(\.id)).count == items.count else { throw SecondLookError.invalidDefinition }
    }

    static func validate(settings: RunSettings) throws {
        let durations = [settings.reminders.firstDelaySeconds,
                         settings.reminders.repeatSeconds,
                         settings.unreviewedTimeoutSeconds].compactMap { $0 }
        guard durations.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw SecondLookError.invalidDefinition
        }
        if let hours = settings.reminders.quietHours {
            guard (0..<1_440).contains(hours.startMinute),
                  (0..<1_440).contains(hours.endMinute) else {
                throw SecondLookError.invalidDefinition
            }
        }
    }

    /// Rejects structurally inconsistent local documents before they become editable state.
    public func validateForLoad() throws {
        guard Set(routines.map(\.id)).count == routines.count,
              Set(runs.map(\.id)).count == runs.count,
              Set(archives.map(\.id)).count == archives.count else {
            throw SecondLookError.corruptDocument
        }
        for routine in routines {
            do {
                try Self.validate(title: routine.title, items: routine.items)
                try Self.validate(settings: routine.settings)
            } catch { throw SecondLookError.corruptDocument }
        }
        for run in runs {
            guard !run.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !run.items.isEmpty,
                  Set(run.items.map(\.id)).count == run.items.count,
                  run.items.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw SecondLookError.corruptDocument
            }
            do { try Self.validate(settings: run.settings) }
            catch { throw SecondLookError.corruptDocument }
            if run.items.contains(where: { $0.priority == .high }) {
                guard let reviewerID = run.reviewerID, reviewerID != run.performerID else {
                    throw SecondLookError.corruptDocument
                }
            }
            for item in run.items {
                try Self.validateRestoredEvidence(item, reviewerID: run.reviewerID)
            }
            let archive = archives.first(where: { $0.id == run.id })
            if run.isOpen {
                guard run.closedAt == nil, run.cleanupStatus == nil, archive == nil else {
                    throw SecondLookError.corruptDocument
                }
            } else {
                guard let archive, let outcome = run.outcome, let closedAt = run.closedAt,
                      archive.outcome == outcome, archive.closedAt == closedAt,
                      archive.cleanupStatus == run.cleanupStatus,
                      run.items.allSatisfy({ $0.submission == nil && $0.preview == nil }) else {
                    throw SecondLookError.corruptDocument
                }
            }
        }
        guard archives.allSatisfy({ archive in runs.contains { $0.id == archive.id && !$0.isOpen } }) else {
            throw SecondLookError.corruptDocument
        }
    }

    private static func validateRestoredEvidence(_ item: RunItem, reviewerID: UUID?) throws {
        guard item.lastVersion >= 0 else { throw SecondLookError.corruptDocument }
        if item.priority == .standard {
            guard item.submission == nil, item.preview == nil else { throw SecondLookError.corruptDocument }
            return
        }
        if let submission = item.submission {
            guard submission.version > 0, submission.version == item.lastVersion else {
                throw SecondLookError.corruptDocument
            }
            switch submission.status {
            case .localDraft:
                // Unsent work belongs to preview and cannot satisfy current evidence.
                throw SecondLookError.corruptDocument
            case .sending, .uploadFailed:
                guard submission.acceptedAt == nil, submission.decision == nil else {
                    throw SecondLookError.corruptDocument
                }
            case .waitingForReview:
                guard submission.acceptedAt != nil, submission.decision == nil else {
                    throw SecondLookError.corruptDocument
                }
            case .approved, .needsAnotherLook:
                guard submission.acceptedAt != nil, let reviewerID,
                      let decision = submission.decision,
                      decision.actorID == reviewerID,
                      decision.submissionVersion == submission.version else {
                    throw SecondLookError.corruptDocument
                }
                if submission.status == .approved {
                    guard decision.verdict == .approved else { throw SecondLookError.corruptDocument }
                } else {
                    guard decision.verdict == .requestedAnother,
                          let note = decision.note,
                          !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw SecondLookError.corruptDocument
                    }
                }
            }
        }
        if let preview = item.preview {
            guard preview.version > 0, preview.version - 1 == item.lastVersion,
                  preview.status == .localDraft, preview.acceptedAt == nil, preview.decision == nil else {
                throw SecondLookError.corruptDocument
            }
        }
    }

    private enum Role { case performer, reviewer }
    private mutating func updateItem(runID: UUID, itemID: UUID, actorID: UUID, role: Role, now: Date,
                                     change: (inout RunItem, ChecklistRun) throws -> Void) throws {
        guard let runIndex = runs.firstIndex(where: { $0.id == runID }) else { throw SecondLookError.notFound }
        let run = runs[runIndex]
        guard run.isOpen else { throw SecondLookError.closed }
        guard (role == .performer ? run.performerID : run.reviewerID) == actorID else { throw SecondLookError.unauthorized }
        guard let itemIndex = run.items.firstIndex(where: { $0.id == itemID }) else { throw SecondLookError.notFound }
        var item = run.items[itemIndex]
        try change(&item, run)
        runs[runIndex].items[itemIndex] = item
        runs[runIndex].revision += 1
        if runs[runIndex].isSatisfied { close(index: runIndex, outcome: .completed, now: now) }
    }

    private mutating func changeSubmission(runID: UUID, itemID: UUID, actorID: UUID, role: Role,
                                           expectedVersion: Int, now: Date,
                                           change: (inout PhotoSubmission) throws -> Void) throws {
        try updateItem(runID: runID, itemID: itemID, actorID: actorID, role: role, now: now) { item, _ in
            guard item.priority == .high else { throw SecondLookError.wrongItemType }
            guard var submission = item.submission else { throw SecondLookError.invalidTransition }
            guard submission.version == expectedVersion else { throw SecondLookError.staleVersion }
            try change(&submission)
            item.submission = submission
        }
    }

    private mutating func close(index: Int, outcome: RunOutcome, now: Date) {
        var run = runs[index]
        let cleanupStatus: CleanupStatus = run.items.contains { $0.submission != nil || $0.preview != nil } ? .pending : .notNeeded
        run.outcome = outcome
        run.closedAt = now
        run.cleanupStatus = cleanupStatus
        run.revision += 1
        let historyItems = run.items.map { item in
            ArchiveItem(title: item.title, priority: item.priority, checkedAt: item.checkedAt,
                        decisions: item.priorDecisions + (item.submission?.decision.map { [$0] } ?? []))
        }
        archives.append(TextArchive(id: run.id, title: run.title, routineID: run.routineID,
                                    performerID: run.performerID, reviewerID: run.reviewerID,
                                    startedAt: run.startedAt, closedAt: now, outcome: outcome,
                                    items: historyItems, cleanupStatus: cleanupStatus))
        // Local demonstration tokens are removed at closure. There are no real media files to delete.
        for itemIndex in run.items.indices {
            run.items[itemIndex].submission = nil
            run.items[itemIndex].preview = nil
        }
        runs[index] = run
    }
}
