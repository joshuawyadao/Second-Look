import Foundation
import Testing
import VaporTesting
import SecondLookCore
@testable import SecondLookServer

@Suite struct JoinResultBoundaryTests {
    private let owner = UUID(uuidString: "80000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "80000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "80000000-0000-0000-0000-000000000003")!

    private func configuration() throws -> ServerConfiguration {
        try ServerConfiguration(environment: [
            "SECONDLOOK_PROVIDER_URL": "http://127.0.0.1:56321",
            "SECONDLOOK_PUBLISHABLE_KEY": "synthetic-public-configuration",
            "SECONDLOOK_SERVICE_KEY": "synthetic-server-only-secret",
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
            "SECONDLOOK_LOCAL_DEVELOPMENT": "1",
        ])
    }

    private func join(_ snapshot: SharedSnapshot, actor: UUID,
                      check: @escaping (TestingHTTPResponse) throws -> Void) async throws {
        let store = JoinResultStore(snapshot: snapshot)
        try await withApp { app in
            try configure(app, configuration: try configuration(),
                          verifier: JoinResultVerifier(account: actor), store: store)
            try await app.testing().test(.POST, "/v1/pairing/join", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "verified-synthetic")
                request.body = ByteBuffer(string: "{\"inviteToken\":\"\(String(repeating: "a", count: 72))\"}")
            }, afterResponse: check)
        }
        #expect(await store.joinCount() == 1)
    }

    @Test func callerOnlyJoinResultCannotBePublishedAsPaired() async throws {
        let callerOnly = SharedSnapshot(spaceID: space, revision: 1,
                                        members: [peer], state: .init())
        try callerOnly.validate(for: peer) // The generic snapshot validator accepts one member.
        try await join(callerOnly, actor: peer) { response in
            #expect(response.status == .serviceUnavailable)
            #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
            #expect(response.headers[.cacheControl] == ["no-store"])
            #expect(!response.body.string.contains("members"))
        }
    }

    @Test func eitherAllowlistedRecipientCanJoinAsSecondMember() async throws {
        for (actor, members) in [(peer, [owner, peer]), (owner, [peer, owner])] {
            let paired = SharedSnapshot(spaceID: space, revision: 2,
                                        members: members, state: .init())
            try await join(paired, actor: actor) { response in
                #expect(response.status == .ok)
                let decoded = try SharedWireCodec.decode(SharedSnapshot.self,
                    from: Data(response.body.readableBytesView))
                #expect(decoded == paired)
            }
        }
    }

    @Test func reversedOrderForVerifiedCallerCannotBePublished() async throws {
        for (actor, members) in [(peer, [peer, owner]), (owner, [owner, peer])] {
            let paired = SharedSnapshot(spaceID: space, revision: 2,
                                        members: members, state: .init())
            try paired.validate(for: actor)
            try await join(paired, actor: actor) { response in
                #expect(response.status == .serviceUnavailable)
                #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
                #expect(response.headers[.cacheControl] == ["no-store"])
                #expect(!response.body.string.contains("members"))
            }
        }
    }
}

private struct JoinResultVerifier: AccountVerifier {
    let account: UUID
    func account(for bearer: String) async throws -> UUID {
        guard bearer == "verified-synthetic" else { throw SharedStateFailure.unauthenticated }
        return account
    }
}

private actor JoinResultStore: SpaceStore {
    let snapshot: SharedSnapshot
    private var joins = 0
    init(snapshot: SharedSnapshot) { self.snapshot = snapshot }
    func joinCount() -> Int { joins }
    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot {
        throw SharedStateFailure.forbidden
    }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date,
                expectedRevision: Int?) async throws -> SharedSnapshot {
        throw SharedStateFailure.forbidden
    }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot {
        joins += 1
        return snapshot
    }
    func receipt(actor: UUID, envelope: SharedCommandEnvelope,
                 digest: String) async throws -> SharedCommandResult? {
        throw SharedStateFailure.forbidden
    }
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String,
                result: SharedCommandResult) async throws -> SharedCommandResult {
        throw SharedStateFailure.forbidden
    }
}
