import Foundation

/// Reversible limits for the connected JSONB aggregate only. Local demo documents are not
/// subject to these ceilings. Closed runs and their text archives are never evicted here.
enum SharedStateLimits {
    static let titleBytes = 256
    static let instructionsBytes = 1_024
    static let noteBytes = 2_048
    static let itemsPerList = 64
    static let routines = 128
    static let runs = 512
    static let archives = 512
    static let decisionsPerItem = 64
    static let aggregateBytes = 2 * 1_024 * 1_024

    static func validateInput(_ command: SharedCommand) throws {
        switch command {
        case let .saveRoutine(definition, _):
            guard validTitle(definition.title), validDefinitionItems(definition.items) else {
                throw SharedStateFailure.domain(.invalidDefinition)
            }
        case let .startOneOff(title, items, _):
            guard validTitle(title), validDefinitionItems(items) else {
                throw SharedStateFailure.domain(.invalidDefinition)
            }
        case let .saveRunAsRoutine(_, _, title):
            guard title.map(validTitle) ?? true else {
                throw SharedStateFailure.domain(.invalidDefinition)
            }
        case let .requestAnother(_, _, _, note, _):
            guard note.utf8.count <= noteBytes else {
                throw SharedStateFailure.domain(.invalidDefinition)
            }
        default:
            break
        }
    }

    /// An oversized provider or phone snapshot is an invalid stored response, never a
    /// user command failure. This check does not rewrite or discard old history.
    static func validateStored(_ state: SecondLookState) throws {
        guard fieldsAndCollectionsFit(state),
              let bytes = try? SharedWireCodec.encode(state).count,
              bytes <= aggregateBytes else {
            throw SharedStateFailure.invalidResponse
        }
    }

    /// Run after a command has produced its candidate state and before its atomic commit.
    /// Project every open run into a text archive in ONE clone and serialize only once.
    /// Reserving that space lets existing runs close at capacity, without deleting history.
    static func validateProposed(_ state: SecondLookState, now: Date) throws {
        guard fieldsAndCollectionsFit(state),
              let currentBytes = try? SharedWireCodec.encode(state).count,
              currentBytes <= aggregateBytes else {
            throw SharedStateFailure.capacityExceeded
        }

        // A review request must leave one slot for the replacement's final decision.
        // An awaiting submission must likewise remain approvable. Existing withdrawn
        // evidence with a full history is still removable/closable; it cannot grow.
        for run in state.runs where run.isOpen {
            for item in run.items where item.priority == .high {
                guard let submission = item.submission,
                      submission.status == .waitingForReview || submission.status == .needsAnotherLook else {
                    continue
                }
                let used = item.priorDecisions.count + (submission.decision == nil ? 0 : 1)
                guard used < decisionsPerItem else { throw SharedStateFailure.capacityExceeded }
            }
        }

        let openRuns = state.runs.filter(\.isOpen)
        var projected = state
        for run in openRuns {
            do { try projected.cancel(runID: run.id, actorID: run.performerID, now: now) }
            catch { throw SharedStateFailure.invalidResponse }
        }
        // A final standard check writes its timestamp twice (run and archive). A high
        // item can add its final decision to both. These per-item margins cover those
        // ordinary terminal changes without promising room for unlimited new reviews.
        let completionHeadroom = openRuns.reduce(0) { subtotal, run in
            subtotal + run.items.reduce(0) { amount, item in
                switch item.priority {
                case .standard: return amount + (item.checkedAt == nil ? 64 : 0)
                case .high: return amount + (item.submission?.status == .approved ? 0 : 512)
                }
            }
        }
        guard fieldsAndCollectionsFit(projected),
              let projectedBytes = try? SharedWireCodec.encode(projected).count,
              projectedBytes <= aggregateBytes - completionHeadroom else {
            throw SharedStateFailure.capacityExceeded
        }
    }

    private static func validTitle(_ value: String) -> Bool {
        value.utf8.count <= titleBytes
    }

    private static func validInstructions(_ value: String) -> Bool {
        value.utf8.count <= instructionsBytes
    }

    private static func validDecision(_ decision: ReviewDecision) -> Bool {
        decision.note.map { $0.utf8.count <= noteBytes } ?? true
    }

    private static func validDefinitionItems(_ items: [RoutineItem]) -> Bool {
        items.count <= itemsPerList && items.allSatisfy {
            validTitle($0.title) && validInstructions($0.photoInstructions)
        }
    }

    private static func fieldsAndCollectionsFit(_ state: SecondLookState) -> Bool {
        guard state.routines.count <= routines, state.runs.count <= runs,
              state.archives.count <= archives else { return false }
        for routine in state.routines {
            guard validTitle(routine.title), validDefinitionItems(routine.items) else { return false }
        }
        for run in state.runs {
            guard validTitle(run.title), run.items.count <= itemsPerList else { return false }
            for item in run.items {
                guard validTitle(item.title), validInstructions(item.photoInstructions),
                      item.priorDecisions.count + (item.submission?.decision == nil ? 0 : 1) <= decisionsPerItem,
                      item.priorDecisions.allSatisfy(validDecision),
                      item.submission?.decision.map(validDecision) ?? true else { return false }
            }
        }
        for archive in state.archives {
            guard validTitle(archive.title), archive.items.count <= itemsPerList else { return false }
            for item in archive.items {
                guard validTitle(item.title), item.decisions.count <= decisionsPerItem,
                      item.decisions.allSatisfy(validDecision) else { return false }
            }
        }
        return true
    }
}
