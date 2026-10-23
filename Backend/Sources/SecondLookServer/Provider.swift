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
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date,
                expectedRevision: Int?) async throws -> SharedSnapshot
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot
    func receipt(actor: UUID, envelope: SharedCommandEnvelope, digest: String) async throws -> SharedCommandResult?
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String,
                result: SharedCommandResult) async throws -> SharedCommandResult
}

/// Verification contacts Auth with the bearer token. No JWT claim is trusted before this request.
struct SupabaseProvider: AccountVerifier, SpaceStore, Sendable {
    let configuration: ServerConfiguration
    private let transport: ProviderHTTPSession

    init(configuration: ServerConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        // FoundationNetworking ignores the per-task redirect delegate. Install
        // the policy on a private session while preserving injected configuration.
        self.transport = ProviderHTTPSession(configuration: session.configuration)
    }

    func account(for bearer: String) async throws -> UUID {
        var request = URLRequest(url: configuration.providerURL.appendingPathComponent("auth/v1/user"))
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw SharedStateFailure.serviceUnavailable }
        guard http.statusCode == 200 else {
            if [401, 403].contains(http.statusCode),
               Self.isExplicitAuthDenial(data, status: http.statusCode) {
                throw SharedStateFailure.unauthenticated
            }
            throw SharedStateFailure.serviceUnavailable
        }
        guard let user = try? JSONDecoder().decode(VerifiedUser.self, from: data) else {
            throw SharedStateFailure.invalidResponse
        }
        guard configuration.allowedAccounts.contains(user.id) else { throw SharedStateFailure.forbidden }
        return user.id
    }

    private static func isExplicitAuthDenial(_ data: Data, status: Int) -> Bool {
        // The gateway can reject an invalid project apikey with the same HTTP
        // status as Auth rejects a bearer. Only Auth's bounded, structured
        // error_code proves that the user's credential was rejected.
        guard data.count <= 16 * 1_024,
              let failure = try? JSONDecoder().decode(AuthFailure.self, from: data),
              failure.code == nil || failure.code == status else { return false }
        return ["bad_jwt", "unexpected_audience", "session_expired", "session_not_found",
                "user_not_found", "user_banned"].contains(failure.errorCode)
    }

    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot {
        try await rpc("sl_read", parameters: Read(actor: actor, space: space))
    }

    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date,
                expectedRevision: Int?) async throws -> SharedSnapshot {
        let proposedSpace = UUID()
        let data = try Self.createParameters(actor: actor, peer: peer, inviteHash: inviteHash,
                                             expiresAt: expiresAt, expectedRevision: expectedRevision,
                                             proposedSpace: proposedSpace)
        let snapshot: SharedSnapshot = try await rpc("sl_create", data: data)
        // Initial creation must return the exact singleton UUID we proposed.
        // Renewal deliberately returns its existing space instead.
        if expectedRevision == nil, snapshot.spaceID != proposedSpace {
            throw SharedStateFailure.invalidResponse
        }
        return snapshot
    }

    static func createParameters(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date,
                                 expectedRevision: Int?, proposedSpace: UUID = UUID()) throws -> Data {
        let state = try JSONSerialization.jsonObject(with: SharedWireCodec.encode(SecondLookState()))
        let parameters: [String: Any] = ["p_actor": actor.uuidString, "p_peer": peer.uuidString,
            "p_space": proposedSpace.uuidString, "p_state": state, "p_invite_hash": inviteHash,
            "p_expires_at": ISO8601DateFormatter().string(from: expiresAt),
            "p_expected_revision": expectedRevision as Any? ?? NSNull()]
        return try JSONSerialization.data(withJSONObject: parameters)
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
        do {
            let result = try await transport.session.data(for: request)
            guard let http = result.1 as? HTTPURLResponse,
                  !(300..<400).contains(http.statusCode) else {
                throw SharedStateFailure.serviceUnavailable
            }
            return result
        }
        catch { throw SharedStateFailure.serviceUnavailable }
    }
}

private struct AuthFailure: Decodable {
    let code: Int?
    let errorCode: String

    enum CodingKeys: String, CodingKey {
        case code
        case errorCode = "error_code"
    }
}

/// Own only the derived session; the caller's injected session remains usable.
private final class ProviderHTTPSession: @unchecked Sendable {
    let session: URLSession

    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration,
                             delegate: RejectProviderRedirect.shared, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }
}

/// A provider redirect must never issue a second credential-bearing request.
private final class RejectProviderRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RejectProviderRedirect()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
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
