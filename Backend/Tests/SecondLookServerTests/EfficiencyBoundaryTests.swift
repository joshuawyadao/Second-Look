import Foundation
import Testing
import VaporTesting
import SecondLookCore
@testable import SecondLookServer

@Suite struct EfficiencyBoundaryTests {
    private let owner = UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "60000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "60000000-0000-0000-0000-000000000003")!

    private func configuration() throws -> ServerConfiguration {
        try ServerConfiguration(environment: [
            "SECONDLOOK_PROVIDER_URL": "http://127.0.0.1:56321",
            "SECONDLOOK_PUBLISHABLE_KEY": "synthetic-public-configuration",
            "SECONDLOOK_SERVICE_KEY": "synthetic-server-only-secret",
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
            "SECONDLOOK_LOCAL_DEVELOPMENT": "1"
        ])
    }

    @Test func conditionalRefreshRequiresExactContentAndFullValidation() async throws {
        let initial = SharedSnapshot(spaceID: space, revision: 0,
            members: [owner, peer], state: .init())
        let store = EfficiencyStore(snapshot: initial)
        let verifier = EfficiencyVerifier(owner: owner)
        let gate = PrivateRequestAdmission(limit: 4)
        let token = PrivateSpaceService.digest(try SharedWireCodec.encode(initial))
        let query = "?knownSpaceID=\(space)&knownRevision=0"
        try await withApp { app in
            try configure(app, configuration: try configuration(), verifier: verifier,
                store: store, admission: gate)
            try await app.testing().test(.GET, "/v1/space", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "synthetic")
            }) { response in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: "ETag") == "\"\(token)\"")
                #expect(response.headers[.cacheControl] == ["no-store"])
                let body = try SharedWireCodec.decode(SharedSnapshot.self,
                    from: Data(response.body.readableBytesView))
                #expect(body == initial)
            }
            try await app.testing().test(.GET, "/v1/space\(query)", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "synthetic")
                request.headers.replaceOrAdd(name: "If-None-Match", value: "\"\(token)\"")
            }) { response in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: "ETag") == "\"\(token)\"")
                let body = try SharedWireCodec.decode(SharedUnchangedReply.self,
                    from: Data(response.body.readableBytesView))
                #expect(body.unchanged == SharedSnapshotValidator(spaceID: space,
                    revision: 0, token: token))
            }
            let altered = SharedSnapshot(spaceID: space, revision: 0,
                members: [peer, owner], state: .init())
            await store.set(altered)
            try await app.testing().test(.GET, "/v1/space\(query)", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "synthetic")
                request.headers.replaceOrAdd(name: "If-None-Match", value: "\"\(token)\"")
            }) { response in
                #expect(response.status == .ok)
                let body = try SharedWireCodec.decode(SharedSnapshot.self,
                    from: Data(response.body.readableBytesView))
                #expect(body == altered)
                #expect(response.headers.first(name: "ETag") != "\"\(token)\"")
            }
            let outsider = UUID(uuidString: "60000000-0000-0000-0000-000000000099")!
            await store.set(SharedSnapshot(spaceID: space, revision: 0,
                members: [owner, outsider], state: .init()))
            try await app.testing().test(.GET, "/v1/space\(query)", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "synthetic")
                request.headers.replaceOrAdd(name: "If-None-Match", value: "\"\(token)\"")
            }) { response in
                #expect(response.status == .forbidden)
                #expect(response.headers.first(name: "ETag") == nil)
            }
            await store.set(altered)
            for invalid in ["/v1/space?knownRevision=0", "/v1/space\(query)"] {
                try await app.testing().test(.GET, invalid, beforeRequest: { request in
                    request.headers.bearerAuthorization = .init(token: "synthetic")
                }) { response in
                    #expect(response.status == .badRequest)
                    #expect(response.body.string == "{\"code\":\"invalidResponse\"}")
                }
            }
        }
        #expect(await store.readCount() == 6)
        #expect(await gate.full == 2)
        #expect(await gate.unchanged == 1)
        #expect(await gate.responseBytes > 0)
    }

    @Test func saturatedPrivateGateRejectsBeforeAuthAndHealthStaysAvailable() async throws {
        let store = EfficiencyStore(snapshot: SharedSnapshot(spaceID: space, revision: 0,
            members: [owner, peer], state: .init()))
        let verifier = EfficiencyVerifier(owner: owner)
        let gate = PrivateRequestAdmission(limit: 1)
        #expect(await gate.acquire())
        try await withApp { app in
            try configure(app, configuration: try configuration(), verifier: verifier,
                store: store, admission: gate)
            try await app.testing().test(.GET, "/v1/space", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "synthetic")
            }) { response in
                #expect(response.status == .tooManyRequests)
                #expect(response.body.string == "{\"code\":\"rateLimited\"}")
                #expect(response.headers.first(name: "Retry-After") == "1")
                #expect(response.headers[.cacheControl] == ["no-store"])
            }
            try await app.testing().test(.GET, "/health") { response in
                #expect(response.status == .ok)
            }
            #expect(await verifier.calls() == 0)
            #expect(await store.readCount() == 0)
            await gate.release()
            try await app.testing().test(.GET, "/v1/space") { response in
                #expect(response.status == .unauthorized)
            }
            #expect(await gate.active == 0)
            try await app.testing().test(.GET, "/v1/space", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "synthetic")
            }) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(await verifier.calls() == 1)
        #expect(await store.readCount() == 1)
        #expect(await gate.active == 0)
        #expect(await gate.peak == 1)
        #expect(await gate.rejected == 1)
    }
}

private actor EfficiencyVerifier: AccountVerifier {
    let owner: UUID
    private var count = 0
    init(owner: UUID) { self.owner = owner }
    func account(for bearer: String) async throws -> UUID { count += 1; return owner }
    func calls() -> Int { count }
}

private actor EfficiencyStore: SpaceStore {
    private var snapshot: SharedSnapshot
    private var reads = 0
    init(snapshot: SharedSnapshot) { self.snapshot = snapshot }
    func set(_ snapshot: SharedSnapshot) { self.snapshot = snapshot }
    func readCount() -> Int { reads }
    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot { reads += 1; return snapshot }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date,
                expectedRevision: Int?) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot {
        throw SharedStateFailure.forbidden
    }
    func receipt(actor: UUID, envelope: SharedCommandEnvelope,
                 digest: String) async throws -> SharedCommandResult? { nil }
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String,
                result: SharedCommandResult) async throws -> SharedCommandResult { result }
}
