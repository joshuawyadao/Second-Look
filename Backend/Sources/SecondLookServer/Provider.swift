import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SecondLookCore

protocol AccountVerifier: Sendable {
    func account(for bearer: String) async throws -> UUID
}

protocol SpaceStore: Sendable {
    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date) async throws -> SharedSnapshot
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot
    func receipt(actor: UUID, envelope: SharedCommandEnvelope, digest: String) async throws -> SharedCommandResult?
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String,
                result: SharedCommandResult) async throws -> SharedCommandResult
}

/// Verification contacts Auth with the bearer token. No JWT claim is trusted before this request.
struct SupabaseProvider: AccountVerifier, SpaceStore, Sendable {
    let configuration: ServerConfiguration
    let session: URLSession

    init(configuration: ServerConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func account(for bearer: String) async throws -> UUID {
        var request = URLRequest(url: configuration.providerURL.appendingPathComponent("auth/v1/user"))
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw SharedStateFailure.serviceUnavailable }
        guard http.statusCode == 200 else {
            if [401, 403].contains(http.statusCode) { throw SharedStateFailure.unauthenticated }
            throw SharedStateFailure.serviceUnavailable
        }
        guard let user = try? JSONDecoder().decode(VerifiedUser.self, from: data),
              configuration.allowedAccounts.contains(user.id) else { throw SharedStateFailure.forbidden }
        return user.id
    }

    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot {
        try await rpc("sl_read", parameters: Read(actor: actor, space: space))
    }

    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date) async throws -> SharedSnapshot {
        let state = try JSONSerialization.jsonObject(with: SharedWireCodec.encode(SecondLookState()))
        let parameters: [String: Any] = ["p_actor": actor.uuidString, "p_peer": peer.uuidString,
            "p_space": UUID().uuidString, "p_state": state, "p_invite_hash": inviteHash,
            "p_expires_at": ISO8601DateFormatter().string(from: expiresAt)]
        return try await rpc("sl_create", data: JSONSerialization.data(withJSONObject: parameters))
    }

    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot {
        try await rpc("sl_join", parameters: Join(p_actor: actor, p_invite_hash: inviteHash))
    }

    func receipt(actor: UUID, envelope: SharedCommandEnvelope, digest: String) async throws -> SharedCommandResult? {
        try await rpc("sl_receipt", parameters: Receipt(p_actor: actor, p_space: envelope.spaceID,
            p_command_id: envelope.commandID, p_digest: digest))
    }

    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String,
                result: SharedCommandResult) async throws -> SharedCommandResult {
        let state = try JSONSerialization.jsonObject(with: SharedWireCodec.encode(result.snapshot.state))
        let parameters: [String: Any] = ["p_actor": actor.uuidString, "p_space": envelope.spaceID.uuidString,
            "p_expected_revision": envelope.expectedSpaceRevision, "p_command_id": envelope.commandID.uuidString,
            "p_digest": digest, "p_state": state, "p_created_id": result.createdID?.uuidString as Any? ?? NSNull()]
        return try await rpc("sl_commit", data: JSONSerialization.data(withJSONObject: parameters))
    }

    private func rpc<P: Encodable, R: Decodable>(_ name: String, parameters: P) async throws -> R {
        try await rpc(name, data: SharedWireCodec.encode(parameters))
    }

    private func rpc<R: Decodable>(_ name: String, data: Data) async throws -> R {
        var request = URLRequest(url: configuration.providerURL.appendingPathComponent("rest/v1/rpc/\(name)"))
        request.httpMethod = "POST"
        request.setValue(configuration.serviceKey, forHTTPHeaderField: "apikey")
        // Modern Supabase secret keys are not JWTs. Legacy service_role keys remain
        // JWTs in the pinned local stack and still need the Bearer header there.
        if !configuration.serviceKey.hasPrefix("sb_secret_") {
            request.setValue("Bearer \(configuration.serviceKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (body, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw SharedStateFailure.serviceUnavailable }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(DatabaseError.self, from: body))?.message
            switch message {
            case "forbidden": throw SharedStateFailure.forbidden
            case "notPaired": throw SharedStateFailure.notPaired
            case "invalidInvite": throw SharedStateFailure.invalidInvite
            case "pairingUnavailable": throw SharedStateFailure.pairingUnavailable
            case "staleState": throw SharedStateFailure.staleState
            default: throw SharedStateFailure.serviceUnavailable
            }
        }
        guard let decoded = try? SharedWireCodec.decode(R.self, from: body) else {
            throw SharedStateFailure.invalidResponse
        }
        return decoded
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.timeoutInterval = 15
        do { return try await session.data(for: request) }
        catch { throw SharedStateFailure.serviceUnavailable }
    }
}

private struct VerifiedUser: Decodable { let id: UUID }
private struct DatabaseError: Decodable { let message: String }
private struct Read: Encodable {
    let p_actor: UUID
    let p_space: UUID?
    init(actor: UUID, space: UUID?) { p_actor = actor; p_space = space }
}
private struct Join: Encodable { let p_actor: UUID; let p_invite_hash: String }
private struct Receipt: Encodable {
    let p_actor: UUID; let p_space: UUID; let p_command_id: UUID; let p_digest: String
}
