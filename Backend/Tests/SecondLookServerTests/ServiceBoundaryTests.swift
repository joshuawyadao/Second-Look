import Foundation
import Testing
import VaporTesting
import SecondLookCore
@testable import SecondLookServer

@Suite struct ServiceBoundaryTests {
    private let owner = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!

    private func environment() -> [String: String] {
        ["SECONDLOOK_PROVIDER_URL": "http://127.0.0.1:56321",
         "SECONDLOOK_PUBLISHABLE_KEY": "synthetic-public-configuration",
         "SECONDLOOK_SERVICE_KEY": "synthetic-server-only-secret",
         "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
         "SECONDLOOK_LOCAL_DEVELOPMENT": "1"]
    }

    @Test func configurationFailsClosed() throws {
        var env = environment()
        env["SECONDLOOK_LOCAL_DEVELOPMENT"] = nil
        #expect(throws: ConfigurationFailure.self) { try ServerConfiguration(environment: env) }
        env = environment()
        env["SECONDLOOK_PROVIDER_URL"] = "http://example.test"
        #expect(throws: ConfigurationFailure.self) { try ServerConfiguration(environment: env) }
        env = environment()
        env["SECONDLOOK_ALLOWED_ACCOUNTS"] = "\(owner),\(owner)"
        #expect(throws: ConfigurationFailure.self) { try ServerConfiguration(environment: env) }
        env = environment()
        env["SECONDLOOK_PROVIDER_URL"] = "https://user:password@example.test"
        #expect(throws: ConfigurationFailure.self) { try ServerConfiguration(environment: env) }
        env = environment()
        env["SECONDLOOK_TEST_EVIDENCE"] = "1"
        env["SECONDLOOK_PROVIDER_URL"] = "https://example.test"
        #expect(throws: ConfigurationFailure.self) { try ServerConfiguration(environment: env) }
    }

    @Test func requestsRequireVerifiedIdentity() async throws {
        let configuration = try ServerConfiguration(environment: environment())
        try await withApp { app in
            try configure(app, configuration: configuration,
                          verifier: SyntheticVerifier(account: owner), store: InaccessibleStore())
            try await app.testing().test(.GET, "/v1/space") { response in
                #expect(response.status == .unauthorized)
                #expect(response.body.string == "{\"code\":\"unauthenticated\"}")
            }
            try await app.testing().test(.GET, "/v1/space", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "unverified")
            }, afterResponse: { response in
                #expect(response.status == .unauthorized)
            })
        }
    }

    @Test func forgedActorIsNotAnInput() async throws {
        let configuration = try ServerConfiguration(environment: environment())
        try await withApp { app in
            try configure(app, configuration: configuration,
                          verifier: SyntheticVerifier(account: owner), store: InaccessibleStore())
            try await app.testing().test(.POST, "/v1/spaces", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "verified-synthetic")
                request.body = ByteBuffer(string: "{\"actor\":\"\(peer)\"}")
            }, afterResponse: { response in
                #expect(response.status == .badRequest)
                #expect(response.body.string == "{\"code\":\"invalidResponse\"}")
            })
        }
    }

    @Test func frameworkErrorsReturnBoundedResponses() async throws {
        let configuration = try ServerConfiguration(environment: environment())
        try await withApp { app in
            try configure(app, configuration: configuration,
                          verifier: SyntheticVerifier(account: owner), store: InaccessibleStore())
            try await app.testing().test(.POST, "/_testing/synthetic-evidence?private=synthetic") { response in
                #expect(response.status == .notFound)
                #expect(response.body.string == "{\"code\":\"notFound\"}")
                #expect(response.headers[.cacheControl] == ["no-store"])
            }
            app.get("test-framework-failure") { _ -> Response in
                throw Abort(.internalServerError, reason: "SYNTHETIC_PRIVATE_ERROR_DETAIL")
            }
            try await app.testing().test(.GET, "/test-framework-failure") { response in
                #expect(response.status == .internalServerError)
                #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
                #expect(response.headers[.contentType] == ["application/json"])
            }
        }
    }

    @Test func identicalRetryFindsReceiptCommittedBetweenReads() async throws {
        let configuration = try ServerConfiguration(environment: environment())
        let original = SharedSnapshot(spaceID: UUID(), revision: 0, members: [owner, peer], state: .init())
        let envelope = SharedCommandEnvelope(spaceID: original.spaceID, commandID: UUID(),
            expectedSpaceRevision: 0, command: .startOneOff(title: "Synthetic retry",
                items: [RoutineItem(title: "Synthetic step")], settings: .init()))
        let committed = try SharedCommandProcessor.apply(envelope, to: original, actorID: owner, now: Date())
        let service = PrivateSpaceService(verifier: SyntheticVerifier(account: owner),
            store: ReceiptRaceStore(result: committed), configuration: configuration)
        let actual = try await service.execute(envelope, actor: owner)
        #expect(actual == committed)
    }

    @Test func productionCompositionHasNoSyntheticEvidenceRoute() async throws {
        let configuration = try ServerConfiguration(environment: environment())
        try await withApp { app in
            try configure(app, configuration: configuration,
                          verifier: SyntheticVerifier(account: owner), store: InaccessibleStore())
            #expect(!app.routes.all.contains { route in route.path.contains(.constant("_testing")) })
        }
        var env = environment()
        env["SECONDLOOK_TEST_EVIDENCE"] = "1"
        #if DEBUG
        let requested = try ServerConfiguration(environment: env)
        let app = try await Application.make(.production)
        do {
            #expect(throws: ConfigurationFailure.self) { try configure(app, configuration: requested) }
            try await app.asyncShutdown()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        #else
        #expect(throws: ConfigurationFailure.self) { try ServerConfiguration(environment: env) }
        #endif
    }
}

private struct SyntheticVerifier: AccountVerifier {
    let account: UUID
    func account(for bearer: String) async throws -> UUID {
        guard bearer == "verified-synthetic" else { throw SharedStateFailure.unauthenticated }
        return account
    }
}

private struct InaccessibleStore: SpaceStore {
    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func receipt(actor: UUID, envelope: SharedCommandEnvelope, digest: String) async throws -> SharedCommandResult? { throw SharedStateFailure.forbidden }
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String, result: SharedCommandResult) async throws -> SharedCommandResult { throw SharedStateFailure.forbidden }
}

private actor ReceiptRaceStore: SpaceStore {
    let result: SharedCommandResult
    var lookups = 0
    init(result: SharedCommandResult) { self.result = result }
    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot { result.snapshot }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func receipt(actor: UUID, envelope: SharedCommandEnvelope, digest: String) async throws -> SharedCommandResult? {
        lookups += 1
        return lookups == 1 ? nil : result
    }
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String, result: SharedCommandResult) async throws -> SharedCommandResult { throw SharedStateFailure.invalidResponse }
}
