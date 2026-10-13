#if SECONDLOOK_DEMO
import Foundation
import SecondLookCore

/// Local UI acceptance only. The real server commits the command; this adapter
/// discards one decoded reply so the app must recover the original receipt.
actor SharedInvitationReceiptLossClient: SharedStateClient {
    private let base: SharedHTTPClient
    private let targetCommandID: UUID
    private var lostReply = false
    private var committedID: UUID?

    init(base: SharedHTTPClient, targetCommandID: UUID) {
        self.base = base
        self.targetCommandID = targetCommandID
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        try await base.fetch(spaceID: spaceID)
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        let result = try await base.execute(envelope)
        if envelope.commandID == targetCommandID && !lostReply {
            lostReply = true
            committedID = result.createdID
            throw SharedStateFailure.serviceUnavailable
        }
        return result
    }

    func committedCreatedID() -> UUID? { committedID }
}
#endif
