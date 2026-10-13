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

    @Test func providerKeysRejectHTTPControlCharacters() throws {
        let controls: [(String, String)] = [
            ("CRLF source trailing CR", "\r"),
            ("CRLF", "\r\n"),
            ("NUL", "\0"),
            ("DEL", "\u{007F}"),
            ("horizontal tab", "\t"),
            ("vertical tab", "\u{000B}"),
            ("Unicode next line", "\u{0085}")
        ]
        for field in ["SECONDLOOK_PUBLISHABLE_KEY", "SECONDLOOK_SERVICE_KEY"] {
            for (caseName, control) in controls {
                var env = environment()
                env[field] = "invented-key" + control
                let rejected: Bool
                do { _ = try ServerConfiguration(environment: env); rejected = false }
                catch is ConfigurationFailure { rejected = true }
                catch { rejected = false }
                #expect(rejected, "\(field) must refuse \(caseName) without exposing the key")
            }
        }
    }

    @Test func providerKeysAcceptValidModernAndLegacyFormats() throws {
        let validPairs = [
            ("sb_publishable_invented-for-test", "sb_secret_invented-for-test"),
            ("invented-local-anon-jwt", "invented-local-service-jwt")
        ]
        for (publishable, service) in validPairs {
            var env = environment()
            env["SECONDLOOK_PUBLISHABLE_KEY"] = publishable
            env["SECONDLOOK_SERVICE_KEY"] = service
            let configuration = try ServerConfiguration(environment: env)
            #expect(configuration.publishableKey == publishable)
            #expect(configuration.serviceKey == service)
        }
    }

    @Test func allowedAccountsRequireExactlyTwoValidDistinctFields() throws {
        let valid = try ServerConfiguration(environment: environment())
        #expect(valid.allowedAccounts == Set([owner, peer]))

        let malformed = [
            "two valid plus typo": "\(owner),\(peer),not-a-uuid",
            "leading empty": ",\(owner),\(peer)",
            "trailing empty": "\(owner),\(peer),",
            "interior empty": "\(owner),,\(peer)",
            "duplicate valid": "\(owner),\(owner)",
        ]
        for (caseName, accounts) in malformed {
            var env = environment()
            env["SECONDLOOK_ALLOWED_ACCOUNTS"] = accounts
            #expect(throws: ConfigurationFailure.self, "\(caseName) must be refused") {
                try ServerConfiguration(environment: env)
            }
        }
    }

    @Test func providerURLRequiresHost() throws {
        var env = environment()
        let local = try ServerConfiguration(environment: env)
        #expect(local.providerURL.host == "127.0.0.1")

        env["SECONDLOOK_LOCAL_DEVELOPMENT"] = nil
        env["SECONDLOOK_PROVIDER_URL"] = "https://example.test"
        let hosted = try ServerConfiguration(environment: env)
        #expect(hosted.providerURL.host == "example.test")

        for hostless in ["https:", "https:///"] {
            env["SECONDLOOK_PROVIDER_URL"] = hostless
            #expect(throws: ConfigurationFailure.self) {
                try ServerConfiguration(environment: env)
            }
        }
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

    @Test func invalidStoredResponsesAreServerFailures() async throws {
        let configuration = try ServerConfiguration(environment: environment())
        for mode in InvalidReadStore.Mode.allCases {
            try await withApp { app in
                try configure(app, configuration: configuration,
                              verifier: SyntheticVerifier(account: owner),
                              store: InvalidReadStore(mode: mode, peer: peer))
                try await app.testing().test(.GET, "/v1/space", beforeRequest: { request in
                    request.headers.bearerAuthorization = .init(token: "verified-synthetic")
                }, afterResponse: { response in
                    #expect(response.status == .serviceUnavailable)
                    #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
                    #expect(response.headers[.cacheControl] == ["no-store"])
                })
            }
        }
    }

    @Test func malformedAuthenticatedBodiesRemainClientFailures() async throws {
        let configuration = try ServerConfiguration(environment: environment())
        try await withApp { app in
            try configure(app, configuration: configuration,
                          verifier: SyntheticVerifier(account: owner), store: InaccessibleStore())
            for path in ["/v1/spaces", "/v1/spaces/\(UUID())/commands"] {
                try await app.testing().test(.POST, path, beforeRequest: { request in
                    request.headers.bearerAuthorization = .init(token: "verified-synthetic")
                    request.body = ByteBuffer(string: "{")
                }, afterResponse: { response in
                    #expect(response.status == .badRequest)
                    #expect(response.body.string == "{\"code\":\"invalidResponse\"}")
                })
            }
            try await app.testing().test(.POST, "/v1/spaces", beforeRequest: { request in
                request.body = ByteBuffer(string: "{")
            }, afterResponse: { response in
                #expect(response.status == .unauthorized)
                #expect(response.body.string == "{\"code\":\"unauthenticated\"}")
            })
        }
    }

    @Test func invitationRevisionIsValidatedAndPassedToStore() async throws {
        let configuration = try ServerConfiguration(environment: environment())
        let store = InvitationRevisionStore(owner: owner)
        try await withApp { app in
            try configure(app, configuration: configuration,
                          verifier: SyntheticVerifier(account: owner), store: store)
            for (body, expected) in [("{}", nil),
                                     ("{\"expectedSpaceRevision\":null}", nil),
                                     ("{\"expectedSpaceRevision\":2}", 2)] {
                try await app.testing().test(.POST, "/v1/spaces", beforeRequest: { request in
                    request.headers.bearerAuthorization = .init(token: "verified-synthetic")
                    request.body = ByteBuffer(string: body)
                }, afterResponse: { response in
                    #expect(response.status == .ok)
                    #expect(response.headers[.cacheControl] == ["no-store"])
                })
                #expect(await store.lastExpectedRevision() == expected)
            }
            #expect(await store.createCount() == 3)
            for body in ["{\"expectedSpaceRevision\":-1}",
                         "{\"expectedSpaceRevision\":1.5}",
                         "{\"expectedSpaceRevision\":2,\"actor\":\"forged\"}"] {
                try await app.testing().test(.POST, "/v1/spaces", beforeRequest: { request in
                    request.headers.bearerAuthorization = .init(token: "verified-synthetic")
                    request.body = ByteBuffer(string: body)
                }, afterResponse: { response in
                    #expect(response.status == .badRequest)
                    #expect(response.body.string == "{\"code\":\"invalidResponse\"}")
                })
            }
            #expect(await store.createCount() == 3)
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

private actor InvitationRevisionStore: SpaceStore {
    let owner: UUID
    private var revisions: [Int?] = []
    init(owner: UUID) { self.owner = owner }
    func lastExpectedRevision() -> Int? { revisions.last ?? nil }
    func createCount() -> Int { revisions.count }
    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date,
                expectedRevision: Int?) async throws -> SharedSnapshot {
        revisions.append(expectedRevision)
        return SharedSnapshot(spaceID: UUID(), revision: expectedRevision ?? 0,
                              members: [owner], state: .init())
    }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func receipt(actor: UUID, envelope: SharedCommandEnvelope, digest: String) async throws -> SharedCommandResult? { throw SharedStateFailure.forbidden }
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String, result: SharedCommandResult) async throws -> SharedCommandResult { throw SharedStateFailure.forbidden }
}

private struct InaccessibleStore: SpaceStore {
    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date, expectedRevision: Int?) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func receipt(actor: UUID, envelope: SharedCommandEnvelope, digest: String) async throws -> SharedCommandResult? { throw SharedStateFailure.forbidden }
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String, result: SharedCommandResult) async throws -> SharedCommandResult { throw SharedStateFailure.forbidden }
}

private struct InvalidReadStore: SpaceStore {
    enum Mode: CaseIterable, Sendable { case throwsInvalidResponse, returnsInvalidSnapshot }
    let mode: Mode
    let peer: UUID

    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot {
        switch mode {
        case .throwsInvalidResponse: throw SharedStateFailure.invalidResponse
        case .returnsInvalidSnapshot:
            return SharedSnapshot(spaceID: UUID(), revision: 1, members: [peer], state: .init())
        }
    }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date, expectedRevision: Int?) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func receipt(actor: UUID, envelope: SharedCommandEnvelope, digest: String) async throws -> SharedCommandResult? { throw SharedStateFailure.forbidden }
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String, result: SharedCommandResult) async throws -> SharedCommandResult { throw SharedStateFailure.forbidden }
}

private actor ReceiptRaceStore: SpaceStore {
    let result: SharedCommandResult
    var lookups = 0
    init(result: SharedCommandResult) { self.result = result }
    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot { result.snapshot }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date, expectedRevision: Int?) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func receipt(actor: UUID, envelope: SharedCommandEnvelope, digest: String) async throws -> SharedCommandResult? {
        lookups += 1
        return lookups == 1 ? nil : result
    }
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String, result: SharedCommandResult) async throws -> SharedCommandResult { throw SharedStateFailure.invalidResponse }
}
