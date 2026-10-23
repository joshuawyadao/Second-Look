import Foundation
import Testing
import VaporTesting
import SecondLookCore
@testable import SecondLookServer

@Suite struct SharedCapacityBoundaryTests {
    private let owner = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "50000000-0000-0000-0000-000000000003")!

    private func snapshot(routines: Int) -> SharedSnapshot {
        SharedSnapshot(spaceID: space, revision: 0, members: [owner, peer],
            state: .init(routines: (0..<routines).map {
                Routine(title: "Invented routine \($0)", items: [RoutineItem(title: "Keys")])
            }))
    }

    private func submit(_ command: SharedCommand, source: SharedSnapshot,
                        check: @escaping (TestingHTTPResponse) throws -> Void) async throws -> Int {
        let store = CapacityBoundaryStore(snapshot: source)
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: source.revision, command: command)
        let configuration = try ServerConfiguration(environment: [
            "SECONDLOOK_PROVIDER_URL": "https://provider.example.test",
            "SECONDLOOK_PUBLISHABLE_KEY": "invented-public-key",
            "SECONDLOOK_SERVICE_KEY": "invented-server-secret",
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
        ])
        try await withApp { app in
            try configure(app, configuration: configuration,
                verifier: CapacityBoundaryVerifier(owner: owner), store: store)
            try await app.testing().test(.POST, "/v1/spaces/\(space)/commands",
                beforeRequest: { request in
                    request.headers.bearerAuthorization = .init(token: "invented-bearer")
                    request.body = ByteBuffer(data: try SharedWireCodec.encode(envelope))
                }, afterResponse: check)
        }
        return await store.commitCount()
    }

    @Test func fullAggregateRejectsGrowthBeforeCommitWithBoundedConflict() async throws {
        let commits = try await submit(.saveRoutine(definition: Routine(title: "Invented overflow",
            items: [RoutineItem(title: "Coat")]), expectedDefinitionVersion: nil),
            source: snapshot(routines: 128)) { response in
                #expect(response.status == .conflict)
                #expect(response.body.string == "{\"code\":\"capacityExceeded\"}")
                #expect(response.headers[.cacheControl] == ["no-store"])
            }
        #expect(commits == 0)
    }

    @Test func fullRoutineCollectionStillAllowsDeletingAnUnusedRoutine() async throws {
        let source = snapshot(routines: 128)
        let routine = try #require(source.state.routines.first)
        let commits = try await submit(.deleteRoutine(routineID: routine.id,
            expectedDefinitionVersion: routine.definitionVersion), source: source) { response in
                #expect(response.status == .ok)
                let result = try SharedWireCodec.decode(SharedCommandResult.self,
                    from: Data(response.body.readableBytesView))
                #expect(result.snapshot.state.routines.count == 127)
                #expect(result.snapshot.revision == 1)
            }
        #expect(commits == 1)
    }

    @Test func overlongClientTextIsDefinitionFailureBeforeCommit() async throws {
        let commits = try await submit(.startOneOff(title: String(repeating: "é", count: 129),
            items: [RoutineItem(title: "Keys")], settings: .init()),
            source: snapshot(routines: 0)) { response in
                #expect(response.status == .badRequest)
                #expect(response.body.string == "{\"code\":\"invalidDefinition\"}")
            }
        #expect(commits == 0)
    }

    @Test func oversizedStoredStateIsUnavailableWithoutCommit() async throws {
        let commits = try await submit(.startOneOff(title: "Invented list",
            items: [RoutineItem(title: "Keys")], settings: .init()),
            source: snapshot(routines: 129)) { response in
                #expect(response.status == .serviceUnavailable)
                #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
            }
        #expect(commits == 0)
    }
}

private struct CapacityBoundaryVerifier: AccountVerifier {
    let owner: UUID
    func account(for bearer: String) async throws -> UUID { owner }
}

private actor CapacityBoundaryStore: SpaceStore {
    private var snapshot: SharedSnapshot
    private var commits = 0
    init(snapshot: SharedSnapshot) { self.snapshot = snapshot }
    func commitCount() -> Int { commits }
    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot { snapshot }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date,
                expectedRevision: Int?) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot { throw SharedStateFailure.forbidden }
    func receipt(actor: UUID, envelope: SharedCommandEnvelope,
                 digest: String) async throws -> SharedCommandResult? { nil }
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String,
                result: SharedCommandResult) async throws -> SharedCommandResult {
        commits += 1
        snapshot = result.snapshot
        return result
    }
}
