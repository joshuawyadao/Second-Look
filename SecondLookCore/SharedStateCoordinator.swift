import Foundation

/// Holds only the active account's in-memory state. A new session always refetches it.
@MainActor
public final class SharedStateCoordinator {
    public private(set) var snapshot: SharedSnapshot?
    public private(set) var scope: SharedAccountScope?
    public private(set) var generation: UInt64 = 0
    private var client: (any SharedStateClient)?
    /// A command with an unknown outcome must keep its full original request for receipt lookup.
    /// This is session memory only; durable offline intent belongs to a later milestone.
    private var unconfirmedCommands: [SharedCommandEnvelope] = []

    public init() {}

    public func beginSession(scope: SharedAccountScope, client: any SharedStateClient) {
        generation &+= 1
        snapshot = nil
        unconfirmedCommands = []
        self.scope = scope
        self.client = client
    }

    public func endSession() {
        generation &+= 1
        snapshot = nil
        unconfirmedCommands = []
        scope = nil
        client = nil
    }

    @discardableResult
    public func refresh() async throws -> Bool {
        guard let scope, let client else { throw SharedStateFailure.unauthenticated }
        let capturedGeneration = generation
        do {
            let incoming = try await client.fetch(spaceID: scope.spaceID)
            try requireCurrent(scope: scope, generation: capturedGeneration)
            try validate(incoming, for: scope)
            return try publish(incoming)
        } catch {
            try handle(error, scope: scope, generation: capturedGeneration)
            throw error
        }
    }

    public func hasUnconfirmedCommand(_ command: SharedCommand) -> Bool {
        unconfirmedCommands.contains { $0.command == command }
    }

    @discardableResult
    public func execute(_ command: SharedCommand, commandID: UUID? = nil) async throws -> UUID? {
        guard let scope, let client else { throw SharedStateFailure.unauthenticated }
        guard let snapshot else { throw SharedStateFailure.notPaired }
        let capturedGeneration = generation
        let envelope: SharedCommandEnvelope
        if let commandID, let pending = unconfirmedCommands.first(where: { $0.commandID == commandID }) {
            guard pending.command == command, pending.spaceID == scope.spaceID else {
                throw SharedStateFailure.invalidResponse
            }
            envelope = pending
        } else if commandID == nil, let pending = unconfirmedCommands.first(where: { $0.command == command }) {
            envelope = pending
        } else {
            envelope = SharedCommandEnvelope(spaceID: scope.spaceID, commandID: commandID ?? UUID(),
                                             expectedSpaceRevision: snapshot.revision, command: command)
            // Register before awaiting the client so simultaneous default retries share this ID.
            unconfirmedCommands.append(envelope)
        }
        do {
            let result = try await client.execute(envelope)
            try requireCurrent(scope: scope, generation: capturedGeneration)
            try validate(result.snapshot, for: scope)
            guard result.snapshot.revision > envelope.expectedSpaceRevision else {
                throw SharedStateFailure.invalidResponse
            }
            // A concurrent refresh may already have published a newer view. The receipt is still
            // confirmed and carries the original created ID; never replace the newer snapshot.
            _ = try publish(result.snapshot)
            unconfirmedCommands.removeAll { $0.commandID == envelope.commandID }
            return result.createdID
        } catch {
            try requireCurrent(scope: scope, generation: capturedGeneration)
            if isDefiniteRejection(error) {
                unconfirmedCommands.removeAll { $0.commandID == envelope.commandID }
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

    /// A lagging fetch cannot reopen an item that a newer response already closed.
    private func publish(_ incoming: SharedSnapshot) throws -> Bool {
        if let snapshot {
            if incoming.revision < snapshot.revision { return false }
            if incoming.revision == snapshot.revision {
                guard incoming == snapshot else { throw SharedStateFailure.invalidResponse }
                return false
            }
        }
        snapshot = incoming
        return true
    }

    private func handle(_ error: Error, scope: SharedAccountScope, generation: UInt64) throws {
        try requireCurrent(scope: scope, generation: generation)
        if let failure = error as? SharedStateFailure,
           failure == .unauthenticated || failure == .forbidden {
            snapshot = nil
            unconfirmedCommands = []
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
