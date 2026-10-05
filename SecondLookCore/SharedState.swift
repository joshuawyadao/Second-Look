import Foundation

/// One server-authored view of a private space. The service must still enforce authorization
/// and commit revisions atomically; decoding this value is not an authorization decision.
public struct SharedSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var spaceID: UUID
    public var revision: Int
    public var members: [UUID]
    public var state: SecondLookState

    public init(schemaVersion: Int = 1, spaceID: UUID, revision: Int,
                members: [UUID], state: SecondLookState) {
        self.schemaVersion = schemaVersion
        self.spaceID = spaceID
        self.revision = revision
        self.members = members
        self.state = state
    }

    public func validate(for accountID: UUID) throws {
        guard schemaVersion == 1, revision >= 0,
              (1...2).contains(members.count), Set(members).count == members.count,
              members.contains(accountID) else { throw SharedStateFailure.invalidResponse }
        do { try state.validateForLoad() }
        catch { throw SharedStateFailure.invalidResponse }
        guard state.routines.allSatisfy({ (1..<Int.max).contains($0.definitionVersion) }),
              state.runs.allSatisfy({ (1..<Int.max).contains($0.revision) }) else {
            throw SharedStateFailure.invalidResponse
        }
        let memberSet = Set(members)
        for run in state.runs {
            guard memberSet.contains(run.performerID),
                  run.reviewerID.map(memberSet.contains) ?? true else {
                throw SharedStateFailure.invalidResponse
            }
            for item in run.items {
                guard item.preview == nil,
                      item.submission.map({ ![.localDraft, .sending, .uploadFailed].contains($0.status) }) ?? true else {
                    throw SharedStateFailure.invalidResponse
                }
            }
        }
        for archive in state.archives {
            guard memberSet.contains(archive.performerID),
                  archive.reviewerID.map(memberSet.contains) ?? true else {
                throw SharedStateFailure.invalidResponse
            }
        }
    }
}

public struct SharedAccountScope: Equatable, Sendable {
    public let backend: String
    public let accountID: UUID
    public let spaceID: UUID

    public init(backend: String, accountID: UUID, spaceID: UUID) {
        self.backend = backend
        self.accountID = accountID
        self.spaceID = spaceID
    }
}

/// This deliberately has no actor, wall clock, arbitrary-state, fixture, or cleanup command.
/// The authenticated service supplies the actor and commit time.
public enum SharedCommand: Codable, Equatable, Sendable {
    case saveRoutine(definition: Routine, expectedDefinitionVersion: Int?)
    case deleteRoutine(routineID: UUID, expectedDefinitionVersion: Int)
    case startRun(routineID: UUID, expectedDefinitionVersion: Int)
    case startOneOff(title: String, items: [RoutineItem], settings: RunSettings)
    case repeatRun(runID: UUID, expectedRunRevision: Int)
    case saveRunAsRoutine(runID: UUID, expectedRunRevision: Int, title: String?)
    case setStandardChecked(runID: UUID, itemID: UUID, checked: Bool, expectedRunRevision: Int)
    case updateRunSettings(runID: UUID, settings: RunSettings, expectedRunRevision: Int)
    case cancel(runID: UUID, expectedRunRevision: Int)
    case approve(runID: UUID, itemID: UUID, expectedVersion: Int, expectedRunRevision: Int)
    case requestAnother(runID: UUID, itemID: UUID, expectedVersion: Int, note: String, expectedRunRevision: Int)
    case withdraw(runID: UUID, itemID: UUID, expectedVersion: Int, expectedRunRevision: Int)
}

public struct SharedCommandEnvelope: Codable, Equatable, Sendable {
    public let spaceID: UUID
    public let commandID: UUID
    public let expectedSpaceRevision: Int
    public let command: SharedCommand

    public init(spaceID: UUID, commandID: UUID, expectedSpaceRevision: Int, command: SharedCommand) {
        self.spaceID = spaceID
        self.commandID = commandID
        self.expectedSpaceRevision = expectedSpaceRevision
        self.command = command
    }
}

public struct SharedCommandResult: Codable, Equatable, Sendable {
    public let snapshot: SharedSnapshot
    public let createdID: UUID?

    public init(snapshot: SharedSnapshot, createdID: UUID? = nil) {
        self.snapshot = snapshot
        self.createdID = createdID
    }
}

public enum SharedStateFailure: Error, Equatable, Sendable {
    case unauthenticated, forbidden, notPaired, invalidInvite, pairingUnavailable
    case staleState, scopeMismatch, sessionChanged, invalidResponse, serviceUnavailable
    case domain(SecondLookError)
}

/// Adapters bind account credentials outside Core. A production service must perform an
/// atomic compare-and-swap and store command receipts so retries have one logical effect.
public protocol SharedStateClient: Sendable {
    func fetch(spaceID: UUID) async throws -> SharedSnapshot
    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult
}

/// Wire timestamps use milliseconds since 1970, with deterministic JSON key ordering.
/// Both service and client must use this codec so dates round-trip at the same precision.
public enum SharedWireCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}

public enum SharedCommandProcessor {
    public static func apply(_ envelope: SharedCommandEnvelope, to snapshot: SharedSnapshot,
                             actorID: UUID, now: Date) throws -> SharedCommandResult {
        guard envelope.spaceID == snapshot.spaceID else { throw SharedStateFailure.scopeMismatch }
        guard snapshot.members.contains(actorID) else { throw SharedStateFailure.forbidden }
        try snapshot.validate(for: actorID)
        guard envelope.expectedSpaceRevision == snapshot.revision else { throw SharedStateFailure.staleState }
        guard snapshot.revision < Int.max else { throw SharedStateFailure.invalidResponse }
        var state = snapshot.state
        var createdID: UUID?
        let reviewerID = snapshot.members.first { $0 != actorID }

        do {
            switch envelope.command {
            case let .saveRoutine(definition, expectedVersion):
                let old = state.routines.first { $0.id == definition.id }
                guard old?.definitionVersion == expectedVersion else { throw SharedStateFailure.staleState }
                var normalized = definition
                normalized.definitionVersion = old?.definitionVersion ?? 1
                try state.saveRoutine(normalized)
            case let .deleteRoutine(routineID, expectedVersion):
                try requireRoutine(routineID, version: expectedVersion, in: state)
                try state.deleteRoutine(id: routineID)
            case let .startRun(routineID, expectedVersion):
                try requireRoutine(routineID, version: expectedVersion, in: state)
                createdID = try state.startRun(routineID: routineID, performerID: actorID,
                                               reviewerID: reviewerID, now: now)
            case let .startOneOff(title, items, settings):
                createdID = try state.startOneOff(title: title, items: items, settings: settings,
                                                  performerID: actorID, reviewerID: reviewerID, now: now)
            case let .repeatRun(runID, expectedRevision):
                try requireRun(runID, revision: expectedRevision, in: state)
                createdID = try state.repeatRun(runID: runID, performerID: actorID,
                                                reviewerID: reviewerID, now: now)
            case let .saveRunAsRoutine(runID, expectedRevision, title):
                try requireRun(runID, revision: expectedRevision, in: state)
                createdID = try state.saveRunAsRoutine(runID: runID, title: title)
            case let .setStandardChecked(runID, itemID, checked, expectedRevision):
                try requireRun(runID, revision: expectedRevision, in: state)
                try state.setStandardChecked(runID: runID, itemID: itemID, checked: checked,
                                             actorID: actorID, now: now)
            case let .updateRunSettings(runID, settings, expectedRevision):
                try requireRun(runID, revision: expectedRevision, in: state)
                try state.updateRunSettings(runID: runID, actorID: actorID, settings: settings)
            case let .cancel(runID, expectedRevision):
                try requireRun(runID, revision: expectedRevision, in: state)
                try state.cancel(runID: runID, actorID: actorID, now: now)
            case let .approve(runID, itemID, expectedVersion, expectedRevision):
                try requireRun(runID, revision: expectedRevision, in: state)
                try state.approve(runID: runID, itemID: itemID, actorID: actorID,
                                  expectedVersion: expectedVersion, now: now)
            case let .requestAnother(runID, itemID, expectedVersion, note, expectedRevision):
                try requireRun(runID, revision: expectedRevision, in: state)
                try state.requestAnother(runID: runID, itemID: itemID, actorID: actorID,
                                         expectedVersion: expectedVersion, note: note, now: now)
            case let .withdraw(runID, itemID, expectedVersion, expectedRevision):
                try requireRun(runID, revision: expectedRevision, in: state)
                try state.withdraw(runID: runID, itemID: itemID, actorID: actorID,
                                   expectedVersion: expectedVersion, now: now)
            }
        } catch let failure as SharedStateFailure {
            throw failure
        } catch let error as SecondLookError {
            throw SharedStateFailure.domain(error)
        }
        let next = SharedSnapshot(spaceID: snapshot.spaceID, revision: snapshot.revision + 1,
                                  members: snapshot.members, state: state)
        try next.validate(for: actorID)
        return SharedCommandResult(snapshot: next, createdID: createdID)
    }

    private static func requireRoutine(_ id: UUID, version: Int, in state: SecondLookState) throws {
        guard let routine = state.routines.first(where: { $0.id == id }) else {
            throw SharedStateFailure.domain(.notFound)
        }
        guard routine.definitionVersion == version else { throw SharedStateFailure.staleState }
    }

    private static func requireRun(_ id: UUID, revision: Int, in state: SecondLookState) throws {
        guard let run = state.runs.first(where: { $0.id == id }) else {
            throw SharedStateFailure.domain(.notFound)
        }
        guard run.revision == revision else { throw SharedStateFailure.staleState }
    }
}
