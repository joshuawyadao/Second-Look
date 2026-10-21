import Foundation
import Testing
import VaporTesting
import SecondLookCore
@testable import SecondLookServer

@Suite(.serialized) struct InitialCreationBoundaryTests {
    private let owner = UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "B0000000-0000-0000-0000-000000000003")!

    private func configuration() throws -> ServerConfiguration {
        try ServerConfiguration(environment: [
            "SECONDLOOK_PROVIDER_URL": "http://127.0.0.1:56321",
            "SECONDLOOK_PUBLISHABLE_KEY": "synthetic-public-configuration",
            "SECONDLOOK_SERVICE_KEY": "synthetic-server-only-secret",
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
            "SECONDLOOK_LOCAL_DEVELOPMENT": "1",
        ])
    }

    private func snapshot(revision: Int = 0, members: [UUID]? = nil,
                          state: SecondLookState = .init()) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: revision,
                       members: members ?? [owner], state: state)
    }

    private func post(_ store: InitialCreationStore, body: String,
                      check: @escaping (TestingHTTPResponse) throws -> Void) async throws {
        try await withApp { app in
            try configure(app, configuration: try configuration(),
                          verifier: InitialCreationVerifier(owner: owner), store: store)
            try await app.testing().test(.POST, "/v1/spaces", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "verified-synthetic")
                request.body = ByteBuffer(string: body)
            }, afterResponse: check)
        }
        #expect(await store.readCount() == 0, "Initial creation must not pre-read")
        #expect(await store.createCount() == 1)
        #expect(await store.lastExpectedRevision() == nil)
    }

    @Test func coherentButNoninitialResultsCannotExposeAnInviteToken() async throws {
        var nonempty = SecondLookState()
        try nonempty.saveRoutine(Routine(title: "Invented routine",
                                         items: [RoutineItem(title: "Keys")]))
        let malformed = [snapshot(revision: 1),
                         snapshot(members: [owner, peer]),
                         snapshot(state: nonempty)]
        for result in malformed {
            try result.validate(for: owner)
            let store = InitialCreationStore(result: result)
            try await post(store, body: "{}") { response in
                #expect(response.status == .serviceUnavailable)
                #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
                #expect(response.headers[.cacheControl] == ["no-store"])
                #expect(!response.body.string.contains("inviteToken"))
            }
        }
    }

    @Test func absentAndExplicitNullExpectedRevisionAllowCleanInitialSpace() async throws {
        for body in ["{}", "{\"expectedSpaceRevision\":null}"] {
            let created = snapshot()
            let store = InitialCreationStore(result: created)
            try await post(store, body: body) { response in
                #expect(response.status == .ok)
                let value = try #require(JSONSerialization.jsonObject(
                    with: Data(response.body.readableBytesView)) as? [String: Any])
                #expect((value["inviteToken"] as? String)?.utf8.count == 72)
                let returned = try #require(value["snapshot"] as? [String: Any])
                #expect(returned["revision"] as? Int == 0)
                #expect(returned["members"] as? [String] == [owner.uuidString])
            }
        }
    }

    @Test func existingSingletonConflictKeepsAuthoritative409() async throws {
        for failure in [SharedStateFailure.staleState, .pairingUnavailable] {
            let store = InitialCreationStore(result: snapshot(), createFailure: failure)
            try await post(store, body: "{}") { response in
                #expect(response.status == .conflict)
                #expect(response.body.string == "{\"code\":\"\(failure)\"}")
                #expect(response.headers[.cacheControl] == ["no-store"])
                #expect(!response.body.string.contains("inviteToken"))
            }
        }
    }
}

private struct InitialCreationVerifier: AccountVerifier {
    let owner: UUID
    func account(for bearer: String) async throws -> UUID {
        guard bearer == "verified-synthetic" else { throw SharedStateFailure.unauthenticated }
        return owner
    }
}

private actor InitialCreationStore: SpaceStore {
    let result: SharedSnapshot
    let createFailure: SharedStateFailure?
    private var reads = 0
    private var creates = 0
    private var lastExpected: Int?
    init(result: SharedSnapshot, createFailure: SharedStateFailure? = nil) {
        self.result = result
        self.createFailure = createFailure
    }
    func readCount() -> Int { reads }
    func createCount() -> Int { creates }
    func lastExpectedRevision() -> Int? { lastExpected }
    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot {
        reads += 1
        throw SharedStateFailure.invalidResponse
    }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date,
                expectedRevision: Int?) async throws -> SharedSnapshot {
        creates += 1
        lastExpected = expectedRevision
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
