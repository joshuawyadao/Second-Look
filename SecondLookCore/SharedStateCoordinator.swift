import Foundation

/// Holds only the active account's in-memory state. A new session always refetches it.
@MainActor
public final class SharedStateCoordinator {
    public private(set) var snapshot: SharedSnapshot?
    public private(set) var scope: SharedAccountScope?
    public private(set) var generation: UInt64 = 0
    private var client: (any SharedStateClient)?

    public init() {}

    public func beginSession(scope: SharedAccountScope, client: any SharedStateClient) {
        generation &+= 1
        snapshot = nil
        self.scope = scope
        self.client = client
    }

    public func endSession() {
        generation &+= 1
        snapshot = nil
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

    @discardableResult
    public func execute(_ command: SharedCommand, commandID: UUID = UUID()) async throws -> UUID? {
        guard let scope, let client else { throw SharedStateFailure.unauthenticated }
        guard let snapshot else { throw SharedStateFailure.notPaired }
        let capturedGeneration = generation
        let envelope = SharedCommandEnvelope(spaceID: scope.spaceID, commandID: commandID,
                                             expectedSpaceRevision: snapshot.revision, command: command)
        do {
            let result = try await client.execute(envelope)
            try requireCurrent(scope: scope, generation: capturedGeneration)
            try validate(result.snapshot, for: scope)
            guard result.snapshot.revision > envelope.expectedSpaceRevision else {
                throw SharedStateFailure.invalidResponse
            }
            let published = try publish(result.snapshot)
            guard published || result.snapshot == self.snapshot else { throw SharedStateFailure.staleState }
            return result.createdID
        } catch {
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
        }
    }
}
