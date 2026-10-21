import Foundation
import Vapor
import Crypto
import SecondLookCore

struct Invitation: Encodable, Sendable {
    let snapshot: SharedSnapshot
    let inviteToken: String
    let expiresAt: Date
}

struct PrivateSpaceService: Sendable {
    let verifier: any AccountVerifier
    let store: any SpaceStore
    let configuration: ServerConfiguration

    func actor(_ request: Request) async throws -> UUID {
        guard let token = request.headers.bearerAuthorization?.token,
              !token.isEmpty, token.utf8.count < 8192 else { throw SharedStateFailure.unauthenticated }
        let account = try await verifier.account(for: token)
        guard configuration.allowedAccounts.contains(account) else { throw SharedStateFailure.forbidden }
        return account
    }

    func validateSnapshot(_ snapshot: SharedSnapshot, actor: UUID,
                          expectedSpaceID: UUID? = nil) throws {
        // The persisted membership must still match this server's current private allowlist.
        // A valid token for one member does not authorize publication of an excluded peer.
        guard snapshot.members.allSatisfy(configuration.allowedAccounts.contains) else {
            throw SharedStateFailure.forbidden
        }
        try snapshot.validate(for: actor)
        // An explicit space or command is scoped by its request. A different, otherwise
        // valid provider snapshot is a bad stored response, not a client scope error.
        if let expectedSpaceID, snapshot.spaceID != expectedSpaceID {
            throw SharedStateFailure.invalidResponse
        }
    }

    func validateAcceptedResult(_ result: SharedCommandResult,
                                actor: UUID, envelope: SharedCommandEnvelope) throws {
        try validateSnapshot(result.snapshot, actor: actor, expectedSpaceID: envelope.spaceID)
        guard result.snapshot.revision > envelope.expectedSpaceRevision else {
            throw SharedStateFailure.invalidResponse
        }
        let createsObject: Bool
        switch envelope.command {
        case .startRun, .startOneOff, .repeatRun, .saveRunAsRoutine:
            createsObject = true
        default:
            createsObject = false
        }
        guard (result.createdID != nil) == createsObject else {
            throw SharedStateFailure.invalidResponse
        }
    }

    func execute(_ envelope: SharedCommandEnvelope, actor: UUID) async throws -> SharedCommandResult {
        let digest = Self.digest(try SharedWireCodec.encode(envelope))
        if let receipt = try await store.receipt(actor: actor, envelope: envelope, digest: digest) {
            try validateAcceptedResult(receipt, actor: actor, envelope: envelope)
            return receipt
        }
        let snapshot = try await store.read(actor: actor, space: envelope.spaceID)
        try validateSnapshot(snapshot, actor: actor, expectedSpaceID: envelope.spaceID)
        let result: SharedCommandResult
        do {
            result = try SharedCommandProcessor.apply(envelope, to: snapshot, actorID: actor, now: Date())
        } catch SharedStateFailure.staleState {
            // An identical retry can miss its receipt just before the first request commits.
            // Recheck after the newer read; distinct actor/payload collisions still fail in SQL.
            if let receipt = try await store.receipt(actor: actor, envelope: envelope, digest: digest) {
                try validateAcceptedResult(receipt, actor: actor, envelope: envelope)
                return receipt
            }
            throw SharedStateFailure.staleState
        }
        try validateSnapshot(result.snapshot, actor: actor, expectedSpaceID: envelope.spaceID)
        let committed = try await store.commit(actor: actor, envelope: envelope, digest: digest, result: result)
        return try await confirmCommit(committed, computed: result, actor: actor,
                                       envelope: envelope, digest: digest)
    }

    func confirmCommit(_ committed: SharedCommandResult, computed result: SharedCommandResult,
                       actor: UUID, envelope: SharedCommandEnvelope,
                       digest: String) async throws -> SharedCommandResult {
        try validateSnapshot(committed.snapshot, actor: actor, expectedSpaceID: envelope.spaceID)
        if committed == result {
            try validateAcceptedResult(committed, actor: actor, envelope: envelope)
            return committed
        }
        // SQL may have committed an identical request first and returned its own
        // result (or a newer current view). Only its bound receipt proves that case.
        guard let receipt = try await store.receipt(actor: actor, envelope: envelope, digest: digest) else {
            throw SharedStateFailure.invalidResponse
        }
        try validateAcceptedResult(receipt, actor: actor, envelope: envelope)
        return receipt
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

func configure(_ app: Application, configuration: ServerConfiguration,
               verifier: (any AccountVerifier)? = nil, store: (any SpaceStore)? = nil) throws {
    // Never emit a request body, Authorization header, invite, email or database error payload.
    app.middleware = .init()
    // Framework errors (including an absent route) still need an HTTP response.
    // The default error middleware logs the full URL and error; keep this bounded.
    app.middleware.use(ErrorMiddleware { _, error in
        let status = (error as? any AbortError)?.status ?? .serviceUnavailable
        let code = status == .notFound ? "notFound"
            : (status.code < 500 ? "invalidRequest" : "serviceUnavailable")
        return Response(status: status,
            headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
            body: .init(string: "{\"code\":\"\(code)\"}"))
    })
    app.http.server.configuration.hostname = configuration.localDevelopment ? "127.0.0.1" : "0.0.0.0"
    app.http.server.configuration.port = configuration.port
    app.routes.defaultMaxBodySize = "512kb"
    let provider = SupabaseProvider(configuration: configuration)
    let service = PrivateSpaceService(verifier: verifier ?? provider, store: store ?? provider,
                                      configuration: configuration)
    app.get("health") { _ in Response(status: .ok, body: .init(string: "ok")) }
    app.get("v1", "space") { request async -> Response in
        await respond {
            let actor = try await service.actor(request)
            let snapshot = try await service.store.read(actor: actor, space: nil)
            try service.validateSnapshot(snapshot, actor: actor)
            return try json(snapshot)
        }
    }
    app.post("v1", "spaces") { request async -> Response in
        await respond {
            let actor = try await service.actor(request)
            let body = try decode(CreateSpaceBody.self, request: request,
                                  allowedKeys: [[], ["expectedSpaceRevision"]])
            guard body.expectedSpaceRevision.map({ $0 >= 0 }) ?? true else {
                throw MalformedClientRequest.invalid
            }
            guard let peer = configuration.allowedAccounts.first(where: { $0 != actor }) else {
                throw SharedStateFailure.pairingUnavailable
            }
            var renewalBaseline: SharedSnapshot?
            if let expectedRevision = body.expectedSpaceRevision {
                guard expectedRevision < Int.max else { throw SharedStateFailure.invalidResponse }
                do {
                    let current = try await service.store.read(actor: actor, space: nil)
                    try service.validateSnapshot(current, actor: actor)
                    renewalBaseline = current
                } catch SharedStateFailure.notPaired {
                    // Let the authoritative SQL create RPC return staleState for an absent
                    // singleton rather than inventing a new renewal outcome here.
                }
            }
            // Two independent UUIDs supply 244 random bits; only a SHA256 digest reaches the database.
            let token = UUID().uuidString + UUID().uuidString
            let expiresAt = Date().addingTimeInterval(15 * 60)
            let snapshot = try await service.store.create(actor: actor, peer: peer,
                inviteHash: PrivateSpaceService.digest(Data(token.utf8)), expiresAt: expiresAt,
                expectedRevision: body.expectedSpaceRevision)
            try service.validateSnapshot(snapshot, actor: actor)
            if let expectedRevision = body.expectedSpaceRevision {
                guard let renewalBaseline,
                      renewalBaseline.revision == expectedRevision,
                      renewalBaseline.members == [actor],
                      snapshot.spaceID == renewalBaseline.spaceID,
                      snapshot.revision == expectedRevision + 1,
                      snapshot.members == renewalBaseline.members,
                      snapshot.state == renewalBaseline.state else {
                    throw SharedStateFailure.invalidResponse
                }
            } else {
                guard snapshot.revision == 0,
                      snapshot.members == [actor],
                      snapshot.state == SecondLookState() else {
                    throw SharedStateFailure.invalidResponse
                }
            }
            return try json(Invitation(snapshot: snapshot, inviteToken: token, expiresAt: expiresAt))
        }
    }
    app.post("v1", "pairing", "join") { request async -> Response in
        await respond {
            let actor = try await service.actor(request)
            let body = try decode(JoinBody.self, request: request, keys: ["inviteToken"])
            guard body.inviteToken.utf8.count == 72 else { throw SharedStateFailure.invalidInvite }
            let snapshot = try await service.store.join(actor: actor,
                inviteHash: PrivateSpaceService.digest(Data(body.inviteToken.utf8)))
            try service.validateSnapshot(snapshot, actor: actor)
            guard snapshot.members.count == 2, snapshot.members[1] == actor else {
                throw SharedStateFailure.invalidResponse
            }
            return try json(snapshot)
        }
    }
    app.get("v1", "spaces", ":space") { request async -> Response in
        await respond {
            let actor = try await service.actor(request)
            let requestedSpace = try spaceID(request)
            let snapshot = try await service.store.read(actor: actor, space: requestedSpace)
            try service.validateSnapshot(snapshot, actor: actor, expectedSpaceID: requestedSpace)
            return try json(snapshot)
        }
    }
    app.post("v1", "spaces", ":space", "commands") { request async -> Response in
        await respond {
            let actor = try await service.actor(request)
            let envelope = try decode(SharedCommandEnvelope.self, request: request,
                keys: ["spaceID", "commandID", "expectedSpaceRevision", "command"])
            guard envelope.spaceID == (try spaceID(request)) else { throw SharedStateFailure.scopeMismatch }
            return try await json(service.execute(envelope, actor: actor))
        }
    }
    #if DEBUG
    if configuration.testEvidence {
        guard configuration.localDevelopment, app.environment != .production else { throw ConfigurationFailure.invalid }
        app.post("_testing", "synthetic-evidence") { request async -> Response in
            await respond {
                let actor = try await service.actor(request)
                let body = try decode(SyntheticEvidence.self, request: request,
                    keys: ["spaceID", "runID", "itemID", "expectedSpaceRevision", "expectedRunRevision"])
                let snapshot = try await service.store.read(actor: actor, space: body.spaceID)
                try service.validateSnapshot(snapshot, actor: actor, expectedSpaceID: body.spaceID)
                guard snapshot.revision == body.expectedSpaceRevision,
                      snapshot.state.runs.first(where: { $0.id == body.runID })?.revision == body.expectedRunRevision else {
                    throw SharedStateFailure.staleState
                }
                guard snapshot.revision < Int.max else { throw SharedStateFailure.invalidResponse }
                var state = snapshot.state
                let now = Date()
                try state.prepareDraft(runID: body.runID, itemID: body.itemID, actorID: actor,
                    fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO", source: .simulatedCamera, now: now)
                let sending = try state.beginSend(runID: body.runID, itemID: body.itemID, actorID: actor)
                try state.acceptSend(runID: body.runID, itemID: body.itemID, actorID: actor,
                    expectedVersion: sending, now: now)
                let envelope = SharedCommandEnvelope(spaceID: body.spaceID, commandID: UUID(),
                    expectedSpaceRevision: snapshot.revision, command: .cancel(runID: body.runID,
                        expectedRunRevision: body.expectedRunRevision))
                let result = SharedCommandResult(snapshot: .init(spaceID: snapshot.spaceID,
                    revision: snapshot.revision + 1, members: snapshot.members, state: state))
                try service.validateSnapshot(result.snapshot, actor: actor, expectedSpaceID: body.spaceID)
                let digest = PrivateSpaceService.digest(try SharedWireCodec.encode(body))
                let committed = try await service.store.commit(actor: actor, envelope: envelope,
                    digest: digest, result: result)
                let confirmed = try await service.confirmCommit(committed, computed: result,
                    actor: actor, envelope: envelope, digest: digest)
                return try json(confirmed.snapshot)
            }
        }
    }
    #endif
}

private struct CreateSpaceBody: Decodable { let expectedSpaceRevision: Int? }
private struct JoinBody: Decodable { let inviteToken: String }
private enum MalformedClientRequest: Error { case invalid }
private struct SyntheticEvidence: Codable {
    let spaceID: UUID; let runID: UUID; let itemID: UUID
    let expectedSpaceRevision: Int; let expectedRunRevision: Int
}

private func spaceID(_ request: Request) throws -> UUID {
    guard let raw = request.parameters.get("space"), let id = UUID(uuidString: raw) else {
        throw SharedStateFailure.scopeMismatch
    }
    return id
}

private func decode<T: Decodable>(_ type: T.Type, request: Request, keys: Set<String>) throws -> T {
    try decode(type, request: request, allowedKeys: [keys])
}

private func decode<T: Decodable>(_ type: T.Type, request: Request,
                                  allowedKeys: Set<Set<String>>) throws -> T {
    guard let buffer = request.body.data else { throw MalformedClientRequest.invalid }
    let data = Data(buffer.readableBytesView)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          allowedKeys.contains(Set(object.keys)),
          let value = try? SharedWireCodec.decode(T.self, from: data) else {
        throw MalformedClientRequest.invalid
    }
    return value
}

private func json<T: Encodable>(_ value: T) throws -> Response {
    Response(status: .ok, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
             body: .init(data: try SharedWireCodec.encode(value)))
}

private func respond(_ operation: () async throws -> Response) async -> Response {
    do { return try await operation() }
    catch {
        let status: HTTPResponseStatus
        let code: String
        switch error {
        case SharedStateFailure.unauthenticated: status = .unauthorized; code = "unauthenticated"
        case SharedStateFailure.forbidden: status = .forbidden; code = "forbidden"
        case SharedStateFailure.notPaired: status = .notFound; code = "notPaired"
        case SharedStateFailure.invalidInvite: status = .badRequest; code = "invalidInvite"
        case SharedStateFailure.pairingUnavailable: status = .conflict; code = "pairingUnavailable"
        case SharedStateFailure.staleState: status = .conflict; code = "staleState"
        case let SharedStateFailure.domain(domain): status = .badRequest; code = String(describing: domain)
        case let domain as SecondLookError: status = .badRequest; code = String(describing: domain)
        case SharedStateFailure.scopeMismatch: status = .badRequest; code = "scopeMismatch"
        case MalformedClientRequest.invalid: status = .badRequest; code = "invalidResponse"
        case SharedStateFailure.invalidResponse: status = .serviceUnavailable; code = "serviceUnavailable"
        default: status = .serviceUnavailable; code = "serviceUnavailable"
        }
        return Response(status: status, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
                        body: .init(string: "{\"code\":\"\(code)\"}"))
    }
}
