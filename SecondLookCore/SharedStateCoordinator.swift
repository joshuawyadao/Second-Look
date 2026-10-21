import Foundation

/// A server-confirmed command awaiting consumption by its originating presentation.
/// This receipt exists only in the active coordinator's session memory.
public struct ConfirmedCommandReceipt: Equatable, Sendable {
    public let commandID: UUID
    public let command: SharedCommand
    public let snapshotRevision: Int
    public let createdID: UUID?
}

/// Holds only the active account's in-memory state. A new session always refetches it.
@MainActor
public final class SharedStateCoordinator {
    public private(set) var snapshot: SharedSnapshot?
    public private(set) var scope: SharedAccountScope?
    public private(set) var generation: UInt64 = 0
    private var client: (any SharedStateClient)?
    private var suspendedScope: SharedAccountScope?
    /// A command with an unknown outcome must keep its full original request for receipt lookup.
    /// This is session memory only; durable offline intent belongs to a later milestone.
    private var unconfirmedCommands: [SharedCommandEnvelope] = []
    /// Keep the view from when each command was first sent. A later refresh may
    /// already contain its genuine creation before an exact receipt retry.
    private var originalObjectIDsByCommand: [UUID: Set<UUID>] = [:]
    private struct ConfirmedRecord {
        let scope: SharedAccountScope
        let receipt: ConfirmedCommandReceipt
    }
    private var confirmedCommands: [ConfirmedRecord] = []
    private struct AttemptKey: Hashable {
        let generation: UInt64
        let commandID: UUID
    }
    private var inFlightAttempts: [AttemptKey: Int] = [:]
    /// Only needed while a second identical response is still in flight.
    private var acknowledgedInFlight: [AttemptKey: ConfirmedCommandReceipt] = [:]
    /// A confirmed or otherwise verified view remains the minimum safe revision
    /// even after the presentation consumes its command receipt.
    private var revisionFloor = 0

    public init() {}

    public func beginSession(scope: SharedAccountScope, client: any SharedStateClient) {
        generation &+= 1
        snapshot = nil
        if (suspendedScope ?? self.scope) != scope {
            unconfirmedCommands = []
            originalObjectIDsByCommand = [:]
            confirmedCommands = []
            revisionFloor = 0
        }
        inFlightAttempts = [:]
        acknowledgedInFlight = [:]
        suspendedScope = nil
        self.scope = scope
        self.client = client
    }

    /// Hide protected state while retaining only requests already sent in this session.
    /// A later validated same-scope beginSession can recover their original receipts.
    public func suspendSession() {
        guard let scope else { return }
        generation &+= 1
        suspendedScope = scope
        snapshot = nil
        self.scope = nil
        client = nil
        inFlightAttempts = [:]
        acknowledgedInFlight = [:]
    }

    public func endSession() {
        generation &+= 1
        snapshot = nil
        unconfirmedCommands = []
        originalObjectIDsByCommand = [:]
        confirmedCommands = []
        inFlightAttempts = [:]
        acknowledgedInFlight = [:]
        revisionFloor = 0
        suspendedScope = nil
        scope = nil
        client = nil
    }

    @discardableResult
    /// Trusted membership/presentation views must agree before a fetched view is published.
    /// Callers without references retain the existing refresh behavior.
    public func refresh(validatingAgainst references: [SharedSnapshot] = []) async throws -> Bool {
        guard let scope, let client else { throw SharedStateFailure.unauthenticated }
        let capturedGeneration = generation
        do {
            let incoming = try await client.fetch(spaceID: scope.spaceID)
            try requireCurrent(scope: scope, generation: capturedGeneration)
            try validate(incoming, for: scope)
            var trustedByRevision: [Int: SharedSnapshot] = [:]
            for reference in references {
                guard reference.spaceID == scope.spaceID else {
                    throw SharedStateFailure.invalidResponse
                }
                try reference.validate(for: scope.accountID)
                if let earlier = trustedByRevision[reference.revision], earlier != reference {
                    throw SharedStateFailure.invalidResponse
                }
                trustedByRevision[reference.revision] = reference
            }
            let chronologicalReferences = trustedByRevision.values.sorted { $0.revision < $1.revision }
            for (earlier, later) in zip(chronologicalReferences, chronologicalReferences.dropFirst()) {
                guard preservesJoinedMembers(from: earlier, to: later),
                      preservesConnectedHistory(from: earlier, to: later) else {
                    throw SharedStateFailure.invalidResponse
                }
            }
            for reference in references {
                guard incoming.revision >= reference.revision else {
                    throw SharedStateFailure.staleState
                }
                guard incoming.revision != reference.revision || incoming == reference else {
                    throw SharedStateFailure.invalidResponse
                }
                if incoming.revision > reference.revision,
                   (!preservesJoinedMembers(from: reference, to: incoming) ||
                    !preservesConnectedHistory(from: reference, to: incoming)) {
                    throw SharedStateFailure.invalidResponse
                }
            }
            // A replica or stale response cannot establish a verified view older
            // than a receipt this session has already seen commit.
            guard snapshot != nil || incoming.revision >= revisionFloor else {
                throw SharedStateFailure.staleState
            }
            return try publish(incoming)
        } catch {
            try handle(error, scope: scope, generation: capturedGeneration)
            throw error
        }
    }

    public func hasUnconfirmedCommand(commandID: UUID) -> Bool {
        scope != nil && unconfirmedCommands.contains { $0.commandID == commandID }
    }

    public func hasConfirmedReceipt(commandID: UUID, command: SharedCommand) -> Bool {
        verifiedConfirmedRecord(commandID: commandID, command: command) != nil
    }

    /// Consume only after the caller has verified its own response epoch. A
    /// suspended or different-scope session cannot take a protected receipt.
    public func takeConfirmedReceipt(commandID: UUID, command: SharedCommand) -> ConfirmedCommandReceipt? {
        guard let index = confirmedCommands.firstIndex(where: {
            $0.receipt.commandID == commandID && $0.receipt.command == command
        }), let scope, let snapshot,
              confirmedCommands[index].scope == scope,
              snapshot.revision >= confirmedCommands[index].receipt.snapshotRevision else { return nil }
        let receipt = confirmedCommands.remove(at: index).receipt
        let key = AttemptKey(generation: generation, commandID: commandID)
        if inFlightAttempts[key, default: 0] > 0 { acknowledgedInFlight[key] = receipt }
        return receipt
    }

    @discardableResult
    public func execute(_ command: SharedCommand, commandID: UUID = UUID()) async throws -> UUID? {
        guard let scope, let client else { throw SharedStateFailure.unauthenticated }
        guard let snapshot else { throw SharedStateFailure.notPaired }
        if let existing = confirmedCommands.first(where: { $0.receipt.commandID == commandID }) {
            guard existing.scope == scope, existing.receipt.command == command else {
                throw SharedStateFailure.invalidResponse
            }
            guard snapshot.revision >= existing.receipt.snapshotRevision else {
                throw SharedStateFailure.staleState
            }
            // Do not consume here: the model may lose this continuation during
            // suspension and must explicitly acknowledge the result later.
            return existing.receipt.createdID
        }
        let capturedGeneration = generation
        let attemptKey = AttemptKey(generation: capturedGeneration, commandID: commandID)
        let envelope: SharedCommandEnvelope
        if let pending = unconfirmedCommands.first(where: { $0.commandID == commandID }) {
            guard pending.command == command, pending.spaceID == scope.spaceID else {
                throw SharedStateFailure.invalidResponse
            }
            envelope = pending
        } else {
            envelope = SharedCommandEnvelope(spaceID: scope.spaceID, commandID: commandID,
                                             expectedSpaceRevision: snapshot.revision, command: command)
            // Register before awaiting the client so an explicit overlapping retry shares this ID.
            originalObjectIDsByCommand[commandID] = Set(snapshot.state.runs.map(\.id))
                .union(snapshot.state.routines.map(\.id))
            unconfirmedCommands.append(envelope)
        }
        guard let originalObjectIDs = originalObjectIDsByCommand[commandID] else {
            throw SharedStateFailure.invalidResponse
        }
        inFlightAttempts[attemptKey, default: 0] += 1
        defer { finishAttempt(attemptKey) }
        do {
            let result = try await client.execute(envelope)
            try requireCurrent(scope: scope, generation: capturedGeneration)
            try validate(result.snapshot, for: scope)
            guard result.snapshot.revision > envelope.expectedSpaceRevision else {
                throw SharedStateFailure.invalidResponse
            }
            try validateCreatedID(result.createdID, for: command, in: result.snapshot,
                                  accountID: scope.accountID,
                                  expectedSpaceRevision: envelope.expectedSpaceRevision,
                                  originalObjectIDs: originalObjectIDs)
            let receipt = ConfirmedCommandReceipt(commandID: commandID, command: command,
                snapshotRevision: result.snapshot.revision, createdID: result.createdID)
            if let existing = confirmedCommands.first(where: { $0.receipt.commandID == commandID }) {
                guard existing.scope == scope, sameCommittedCommand(existing.receipt, receipt) else {
                    throw SharedStateFailure.invalidResponse
                }
            }
            if let acknowledged = acknowledgedInFlight[attemptKey],
               !sameCommittedCommand(acknowledged, receipt) {
                throw SharedStateFailure.invalidResponse
            }
            // A concurrent refresh may already have published a newer view. The receipt is still
            // confirmed and carries the original created ID; never replace the newer snapshot.
            _ = try publish(result.snapshot)
            if confirmedCommands.allSatisfy({ $0.receipt.commandID != commandID }) &&
                acknowledgedInFlight[attemptKey] == nil {
                confirmedCommands.append(ConfirmedRecord(scope: scope, receipt: receipt))
            }
            unconfirmedCommands.removeAll { $0.commandID == envelope.commandID }
            originalObjectIDsByCommand.removeValue(forKey: envelope.commandID)
            return result.createdID
        } catch {
            try requireCurrent(scope: scope, generation: capturedGeneration)
            if isDefiniteRejection(error) {
                unconfirmedCommands.removeAll { $0.commandID == envelope.commandID }
                originalObjectIDsByCommand.removeValue(forKey: envelope.commandID)
            }
            try handle(error, scope: scope, generation: capturedGeneration)
            throw error
        }
    }

    private func requireCurrent(scope: SharedAccountScope, generation: UInt64) throws {
        guard self.scope == scope, self.generation == generation else {
            throw SharedStateFailure.sessionChanged
        }
    }

    private func validate(_ incoming: SharedSnapshot, for scope: SharedAccountScope) throws {
        guard incoming.spaceID == scope.spaceID else { throw SharedStateFailure.scopeMismatch }
        try incoming.validate(for: scope.accountID)
    }

    private func validateCreatedID(_ createdID: UUID?, for command: SharedCommand,
                                   in snapshot: SharedSnapshot,
                                   accountID: UUID,
                                   expectedSpaceRevision: Int,
                                   originalObjectIDs: Set<UUID>) throws {
        switch command {
        case let .startRun(routineID, _):
            guard let createdID, !originalObjectIDs.contains(createdID),
                  let run = snapshot.state.runs.first(where: { $0.id == createdID }),
                  run.performerID == accountID, run.routineID == routineID else {
                throw SharedStateFailure.invalidResponse
            }
        case .startOneOff:
            guard let createdID, !originalObjectIDs.contains(createdID),
                  let run = snapshot.state.runs.first(where: { $0.id == createdID }),
                  run.performerID == accountID, run.routineID == nil else {
                throw SharedStateFailure.invalidResponse
            }
        case let .repeatRun(sourceID, _):
            guard let createdID, createdID != sourceID, !originalObjectIDs.contains(createdID),
                  let source = snapshot.state.runs.first(where: { $0.id == sourceID }),
                  let run = snapshot.state.runs.first(where: { $0.id == createdID }),
                  run.performerID == accountID, run.routineID == source.routineID else {
                throw SharedStateFailure.invalidResponse
            }
        case .saveRunAsRoutine:
            guard let createdID, !originalObjectIDs.contains(createdID) else {
                throw SharedStateFailure.invalidResponse
            }
            // An exact commit view must contain the new routine. A receipt replay
            // may carry a later current view after that routine was deleted.
            if snapshot.revision - expectedSpaceRevision == 1,
               !snapshot.state.routines.contains(where: { $0.id == createdID }) {
                throw SharedStateFailure.invalidResponse
            }
        default:
            guard createdID == nil else { throw SharedStateFailure.invalidResponse }
        }
    }

    private func finishAttempt(_ key: AttemptKey) {
        guard let count = inFlightAttempts[key] else { return }
        if count <= 1 {
            inFlightAttempts.removeValue(forKey: key)
            acknowledgedInFlight.removeValue(forKey: key)
        } else {
            inFlightAttempts[key] = count - 1
        }
    }

    /// A request-bound replay may include a newer current space view after a
    /// peer's write. Its original command and created ID must remain stable;
    /// the first receipt retains its own minimum verified revision.
    private func sameCommittedCommand(_ first: ConfirmedCommandReceipt,
                                      _ replay: ConfirmedCommandReceipt) -> Bool {
        first.commandID == replay.commandID && first.command == replay.command &&
        first.createdID == replay.createdID
    }

    private func verifiedConfirmedRecord(commandID: UUID,
                                         command: SharedCommand) -> ConfirmedRecord? {
        guard let scope, let snapshot else { return nil }
        return confirmedCommands.first {
            $0.scope == scope && $0.receipt.commandID == commandID &&
            $0.receipt.command == command && snapshot.revision >= $0.receipt.snapshotRevision
        }
    }

    /// A lagging fetch cannot reopen an item that a newer response already closed.
    private func publish(_ incoming: SharedSnapshot) throws -> Bool {
        if let snapshot {
            if incoming.revision < snapshot.revision { return false }
            if incoming.revision == snapshot.revision {
                guard incoming == snapshot else { throw SharedStateFailure.invalidResponse }
                return false
            }
            guard preservesJoinedMembers(from: snapshot, to: incoming),
                  preservesConnectedHistory(from: snapshot, to: incoming) else {
                throw SharedStateFailure.invalidResponse
            }
        }
        snapshot = incoming
        revisionFloor = max(revisionFloor, incoming.revision)
        return true
    }

    /// M2 can add the second participant once; it has no unpair or ownership transfer.
    private func preservesJoinedMembers(from earlier: SharedSnapshot,
                                        to later: SharedSnapshot) -> Bool {
        if later.members == earlier.members { return true }
        return earlier.members.count == 1 && later.members.count == 2 &&
            later.members[0] == earlier.members[0]
    }

    /// Connected M2 has no history deletion or cleanup acknowledgment. Open runs may
    /// progress or close, while a closed run and its text archive remain immutable.
    private func preservesConnectedHistory(from earlier: SharedSnapshot,
                                           to later: SharedSnapshot) -> Bool {
        // Only adjacent space revisions prove the routine stayed present. Across a
        // gap, it may have been deleted and recreated with the same ID at version 1.
        if later.revision > earlier.revision && later.revision - earlier.revision == 1 {
            let laterRoutines = Dictionary(uniqueKeysWithValues: later.state.routines.map { ($0.id, $0) })
            for routine in earlier.state.routines {
                guard let current = laterRoutines[routine.id] else { continue }
                guard current.definitionVersion >= routine.definitionVersion,
                      current.definitionVersion != routine.definitionVersion || current == routine else {
                    return false
                }
            }
        }
        let laterRuns = Dictionary(uniqueKeysWithValues: later.state.runs.map { ($0.id, $0) })
        if later.revision > earlier.revision && later.revision - earlier.revision == 1 {
            let knownIDs = Set(earlier.state.runs.map(\.id))
            let newRuns = later.state.runs.filter { !knownIDs.contains($0.id) }
            guard newRuns.count <= 1, newRuns.allSatisfy({ run in
                run.revision == 1 && run.outcome == nil && run.closedAt == nil &&
                run.cleanupStatus == nil && run.hadEvidenceAtClosure == nil &&
                run.items.allSatisfy { item in
                    item.checkedAt == nil && item.submission == nil && item.preview == nil &&
                    item.lastVersion == 0 && item.priorDecisions.isEmpty
                }
            }) else { return false }
            if let newRun = newRuns.first {
                guard later.members == earlier.members,
                      later.state.routines == earlier.state.routines,
                      later.state.runs == earlier.state.runs + [newRun],
                      later.state.archives == earlier.state.archives else { return false }
            }
        }
        let earlierArchives = Dictionary(uniqueKeysWithValues: earlier.state.archives.map { ($0.id, $0) })
        let laterArchives = Dictionary(uniqueKeysWithValues: later.state.archives.map { ($0.id, $0) })
        for run in earlier.state.runs {
            guard let current = laterRuns[run.id],
                  current.revision >= run.revision,
                  current.revision != run.revision || current == run,
                  current.performerID == run.performerID,
                  current.reviewerID == run.reviewerID,
                  current.title == run.title,
                  current.routineID == run.routineID,
                  current.routineVersion == run.routineVersion,
                  current.startedAt == run.startedAt,
                  current.items.count == run.items.count,
                  run.isOpen || current == run else { return false }
            for (index, pair) in zip(run.items, current.items).enumerated() {
                let (original, updated) = pair
                guard updated.id == original.id,
                      updated.title == original.title,
                      updated.priority == original.priority,
                      updated.photoInstructions == original.photoInstructions,
                      preservesEvidenceHistory(original: original, updated: updated,
                          earlierRun: run, laterRun: current, itemIndex: index,
                          earlierArchive: earlierArchives[run.id],
                          laterArchive: laterArchives[run.id]) else { return false }
            }
        }
        for archive in earlier.state.archives {
            guard laterArchives[archive.id] == archive else { return false }
        }
        return true
    }

    private func preservesEvidenceHistory(original: RunItem, updated: RunItem,
                                          earlierRun: ChecklistRun, laterRun: ChecklistRun,
                                          itemIndex: Int, earlierArchive: TextArchive?,
                                          laterArchive: TextArchive?) -> Bool {
        guard updated.lastVersion >= original.lastVersion else { return false }
        if original.submission == nil, let current = updated.submission,
           current.version <= original.lastVersion { return false }
        if let prior = original.submission, let current = updated.submission,
           prior.version == current.version {
            guard prior.fixtureID == current.fixtureID,
                  prior.source == current.source,
                  prior.preparedAt == current.preparedAt,
                  prior.acceptedAt == nil || prior.acceptedAt == current.acceptedAt else {
                return false
            }
        }

        let known: [ReviewDecision]
        if earlierRun.isOpen {
            known = original.priorDecisions + (original.submission?.decision.map { [$0] } ?? [])
        } else {
            guard let earlierArchive else { return false }
            known = earlierArchive.items[itemIndex].decisions
        }
        let incoming: [ReviewDecision]
        if laterRun.isOpen {
            incoming = updated.priorDecisions + (updated.submission?.decision.map { [$0] } ?? [])
        } else {
            guard let laterArchive else { return false }
            incoming = laterArchive.items[itemIndex].decisions
        }
        guard incoming.count >= known.count,
              Array(incoming.prefix(known.count)) == known else { return false }
        for decision in incoming.dropFirst(known.count) where decision.submissionVersion <= original.lastVersion {
            guard let current = original.submission,
                  current.version == decision.submissionVersion,
                  current.decision == nil else { return false }
        }
        return true
    }

    private func handle(_ error: Error, scope: SharedAccountScope, generation: UInt64) throws {
        try requireCurrent(scope: scope, generation: generation)
        if let failure = error as? SharedStateFailure,
           failure == .unauthenticated || failure == .forbidden ||
           failure == .notPaired || failure == .scopeMismatch {
            // Invalidate the response epoch as well as the visible state. A
            // second already-admitted reply must not republish after denial.
            endSession()
        }
    }

    private func isDefiniteRejection(_ error: Error) -> Bool {
        guard let failure = error as? SharedStateFailure else { return false }
        switch failure {
        case .serviceUnavailable, .invalidResponse, .scopeMismatch:
            return false
        case .unauthenticated, .forbidden, .notPaired, .invalidInvite, .pairingUnavailable,
             .staleState, .sessionChanged, .domain:
            return true
        }
    }
}
