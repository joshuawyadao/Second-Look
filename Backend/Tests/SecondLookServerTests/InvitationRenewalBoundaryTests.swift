import Foundation
import Testing
import VaporTesting
import SecondLookCore
@testable import SecondLookServer

@Suite(.serialized) struct InvitationRenewalBoundaryTests {
    private let owner = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "70000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "70000000-0000-0000-0000-000000000003")!

    private func configuration() throws -> ServerConfiguration {
        try ServerConfiguration(environment: [
            "SECONDLOOK_PROVIDER_URL": "http://127.0.0.1:56321",
            "SECONDLOOK_PUBLISHABLE_KEY": "synthetic-public-configuration",
            "SECONDLOOK_SERVICE_KEY": "synthetic-server-only-secret",
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
            "SECONDLOOK_LOCAL_DEVELOPMENT": "1",
        ])
    }

    private func baseline(revision: Int = 8) throws -> SharedSnapshot {
        var state = SecondLookState()
        try state.saveRoutine(Routine(title: "Invented baseline",
                                      items: [RoutineItem(title: "Keys")]))
        return SharedSnapshot(spaceID: space, revision: revision,
                              members: [owner], state: state)
    }

    private func request(_ store: RenewalStore, expected: Int?,
                         check: @escaping (TestingHTTPResponse) throws -> Void) async throws {
        let body = expected.map { "{\"expectedSpaceRevision\":\($0)}" } ?? "{}"
        try await withApp { app in
            try configure(app, configuration: try configuration(),
                          verifier: RenewalVerifier(owner: owner), store: store)
            try await app.testing().test(.POST, "/v1/spaces", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "verified-synthetic")
                request.body = ByteBuffer(string: body)
            }, afterResponse: check)
        }
    }

    @Test func malformedRenewalResultsCannotExposeAnInviteToken() async throws {
        let prior = try baseline()
        var changedState = prior.state
        try changedState.saveRoutine(Routine(title: "Invented replacement",
                                             items: [RoutineItem(title: "Wallet")]))
        let changes: [(String, SharedSnapshot)] = [
            ("unchanged", SharedSnapshot(spaceID: space, revision: 8,
                                           members: [owner], state: prior.state)),
            ("lower", SharedSnapshot(spaceID: space, revision: 7,
                                       members: [owner], state: prior.state)),
            ("jumped", SharedSnapshot(spaceID: space, revision: 10,
                                        members: [owner], state: prior.state)),
            ("different space", SharedSnapshot(spaceID: UUID(), revision: 9,
                                                 members: [owner], state: prior.state)),
            ("changed membership", SharedSnapshot(spaceID: space, revision: 9,
                                                    members: [owner, peer], state: prior.state)),
            ("changed aggregate", SharedSnapshot(spaceID: space, revision: 9,
                                                   members: [owner], state: changedState)),
        ]
        for (label, result) in changes {
            try result.validate(for: owner) // A coherent snapshot can still be a bad renewal.
            let store = RenewalStore(prior: prior, result: result)
            try await request(store, expected: 8) { response in
                #expect(response.status == .serviceUnavailable, "\(label)")
                #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}", "\(label)")
                #expect(response.headers[.cacheControl] == ["no-store"], "\(label)")
                #expect(!response.body.string.contains("inviteToken"), "\(label)")
            }
            #expect(await store.readCount() == 1, "\(label)")
            #expect(await store.createCount() == 1, "\(label)")
        }
    }

    @Test func exactRenewalAndInitialCreationReturnUsableInvitations() async throws {
        let prior = try baseline()
        let renewed = SharedSnapshot(spaceID: space, revision: 9,
                                     members: prior.members, state: prior.state)
        let renewal = RenewalStore(prior: prior, result: renewed)
        try await request(renewal, expected: 8) { response in
            #expect(response.status == .ok)
            let body = try #require(JSONSerialization.jsonObject(
                with: Data(response.body.readableBytesView)) as? [String: Any])
            #expect((body["inviteToken"] as? String)?.utf8.count == 72)
            let snapshot = try #require(body["snapshot"] as? [String: Any])
            #expect(snapshot["revision"] as? Int == 9)
        }
        #expect(await renewal.readCount() == 1)
        #expect(await renewal.createCount() == 1)

        let created = SharedSnapshot(spaceID: UUID(), revision: 0,
                                     members: [owner], state: .init())
        let initial = RenewalStore(prior: nil, result: created)
        try await request(initial, expected: nil) { response in
            #expect(response.status == .ok)
            let body = try #require(JSONSerialization.jsonObject(
                with: Data(response.body.readableBytesView)) as? [String: Any])
            #expect((body["inviteToken"] as? String)?.utf8.count == 72)
        }
        #expect(await initial.readCount() == 0)
        #expect(await initial.createCount() == 1)
    }

    @Test func ProviderConflictsRemain409AndCapacityDoesNotWrap() async throws {
        let prior = try baseline()
        for failure in [SharedStateFailure.staleState, .pairingUnavailable] {
            let store = RenewalStore(prior: prior, result: prior, createFailure: failure)
            try await request(store, expected: 8) { response in
                #expect(response.status == .conflict)
                #expect(response.body.string == "{\"code\":\"\(failure)\"}")
                #expect(response.headers[.cacheControl] == ["no-store"])
                #expect(!response.body.string.contains("inviteToken"))
            }
            #expect(await store.readCount() == 1)
            #expect(await store.createCount() == 1)
        }
        let absent = RenewalStore(prior: nil, result: prior, createFailure: .staleState)
        try await request(absent, expected: 8) { response in
            #expect(response.status == .conflict)
            #expect(response.body.string == "{\"code\":\"staleState\"}")
            #expect(!response.body.string.contains("inviteToken"))
        }
        #expect(await absent.readCount() == 1)
        #expect(await absent.createCount() == 0)

        let exhausted = RenewalStore(prior: try baseline(revision: Int.max),
                                     result: try baseline(revision: Int.max))
        try await request(exhausted, expected: Int.max) { response in
            #expect(response.status == .serviceUnavailable)
            #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
            #expect(response.headers[.cacheControl] == ["no-store"])
            #expect(!response.body.string.contains("inviteToken"))
        }
        #expect(await exhausted.createCount() == 0)
    }

    @Test func invalidOrMismatchedBaselineCannotAuthorizeAClaimedRenewal() async throws {
        let prior = try baseline(revision: 7)
        let claimed = SharedSnapshot(spaceID: space, revision: 9,
                                     members: prior.members, state: prior.state)
        let mismatch = RenewalStore(prior: prior, result: claimed)
        try await request(mismatch, expected: 8) { response in
            #expect(response.status == .serviceUnavailable)
            #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
            #expect(!response.body.string.contains("inviteToken"))
        }
        #expect(await mismatch.createCount() == 1)

        var invalid = prior
        invalid.schemaVersion = 2
        let invalidRead = RenewalStore(prior: invalid, result: claimed)
        try await request(invalidRead, expected: 8) { response in
            #expect(response.status == .serviceUnavailable)
            #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
            #expect(!response.body.string.contains("inviteToken"))
        }
        #expect(await invalidRead.createCount() == 0)
    }
}

private struct RenewalVerifier: AccountVerifier {
    let owner: UUID
    func account(for bearer: String) async throws -> UUID {
        guard bearer == "verified-synthetic" else { throw SharedStateFailure.unauthenticated }
        return owner
    }
}

private actor RenewalStore: SpaceStore {
    let prior: SharedSnapshot?
    let result: SharedSnapshot
    let createFailure: SharedStateFailure?
    private var reads = 0
    private var creates = 0

    init(prior: SharedSnapshot?, result: SharedSnapshot,
         createFailure: SharedStateFailure? = nil) {
        self.prior = prior
        self.result = result
        self.createFailure = createFailure
    }

    func readCount() -> Int { reads }
    func createCount() -> Int { creates }
    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot {
        reads += 1
        guard space == nil else { throw SharedStateFailure.invalidResponse }
        guard let prior else { throw SharedStateFailure.notPaired }
        return prior
    }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date,
                expectedRevision: Int?) async throws -> SharedSnapshot {
        creates += 1
        if let createFailure { throw createFailure }
        return result
    }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot {
        throw SharedStateFailure.forbidden
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
