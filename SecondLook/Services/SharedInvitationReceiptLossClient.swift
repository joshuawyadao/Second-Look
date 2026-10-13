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
    private var scopeLossCommandID: UUID?
    private var scopeLossInjected = false

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
        if envelope.commandID == scopeLossCommandID && !scopeLossInjected {
            scopeLossInjected = true
            // Debug localhost acceptance only: the real command committed, but
            // the decoded response is replaced with a coded membership loss.
            throw SharedStateFailure.notPaired
        }
        return result
    }

    func committedCreatedID() -> UUID? { committedID }

    func armScopeLoss(afterCommittedCommandID commandID: UUID) {
        scopeLossCommandID = commandID
    }
}
#endif
