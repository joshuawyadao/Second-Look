import Foundation
import Testing
import VaporTesting
import SecondLookCore
@testable import SecondLookServer

@Suite struct ReleaseEvidenceBoundaryTests {
    private let owner = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
    private let space = UUID(uuidString: "50000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func configuration() throws -> ServerConfiguration {
        try ServerConfiguration(environment: [
            "SECONDLOOK_PROVIDER_URL": "http://127.0.0.1:56321",
            "SECONDLOOK_PUBLISHABLE_KEY": "synthetic-public-configuration",
            "SECONDLOOK_SERVICE_KEY": "synthetic-server-only-secret",
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
            "SECONDLOOK_LOCAL_DEVELOPMENT": "1",
        ])
    }

    private func storedSnapshot() throws -> SharedSnapshot {
        var state = SecondLookState()
        let runID = try state.startOneOff(title: "Invented departure", items: [
            RoutineItem(title: "Keys"), RoutineItem(title: "Door", priority: .high)
        ], performerID: owner, reviewerID: peer, now: now)
        let itemID = state.runs[0].items[1].id
        try state.prepareDraft(runID: runID, itemID: itemID, actorID: owner,
                               fixtureID: "M2-SYNTHETIC-NO-REAL-PHOTO",
                               source: .simulatedCamera, now: now)
        let version = try state.beginSend(runID: runID, itemID: itemID, actorID: owner, now: now)
        try state.acceptSend(runID: runID, itemID: itemID, actorID: owner,
                             expectedVersion: version, now: now)
        return SharedSnapshot(spaceID: space, revision: 1, members: [owner, peer], state: state)
    }

    @Test func authenticatedReadAndCommandCannotPublishCurrentEvidenceInRelease() async throws {
        let stored = try storedSnapshot()
        let store = ReleaseEvidenceStore(snapshot: stored)
        let command = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: stored.revision,
            command: .saveRoutine(definition: Routine(title: "Invented list",
                items: [RoutineItem(title: "Wallet")]), expectedDefinitionVersion: nil))
        let commandBody = String(decoding: try SharedWireCodec.encode(command), as: UTF8.self)
        try await withApp { app in
            try configure(app, configuration: configuration(),
                          verifier: ReleaseEvidenceVerifier(owner: owner), store: store)
            try await app.testing().test(.GET, "/v1/spaces/\(space)", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "verified-synthetic")
            }, afterResponse: { response in
                #if DEBUG
                #expect(response.status == .ok)
                #else
                #expect(response.status == .serviceUnavailable)
                #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
                #expect(response.headers[.cacheControl] == ["no-store"])
                #endif
            })
            try await app.testing().test(.POST, "/v1/spaces/\(space)/commands",
                beforeRequest: { request in
                    request.headers.bearerAuthorization = .init(token: "verified-synthetic")
                    request.headers.contentType = .json
                    request.body = ByteBuffer(string: commandBody)
                }, afterResponse: { response in
                    #if DEBUG
                    #expect(response.status == .ok)
                    #else
                    #expect(response.status == .serviceUnavailable)
                    #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
                    #expect(response.headers[.cacheControl] == ["no-store"])
                    #endif
                })
        }
        let commits = await store.commitCount()
        #if DEBUG
        #expect(commits == 1)
        #else
        #expect(commits == 0)
        #endif
    }
}

private struct ReleaseEvidenceVerifier: AccountVerifier {
    let owner: UUID
    func account(for bearer: String) async throws -> UUID {
        guard bearer == "verified-synthetic" else { throw SharedStateFailure.unauthenticated }
        return owner
    }
}

private actor ReleaseEvidenceStore: SpaceStore {
    let snapshot: SharedSnapshot
    private var commits = 0
    init(snapshot: SharedSnapshot) { self.snapshot = snapshot }
    func commitCount() -> Int { commits }
    func read(actor: UUID, space: UUID?) async throws -> SharedSnapshot { snapshot }
    func create(actor: UUID, peer: UUID, inviteHash: String, expiresAt: Date,
                expectedRevision: Int?) async throws -> SharedSnapshot {
        throw SharedStateFailure.forbidden
    }
    func join(actor: UUID, inviteHash: String) async throws -> SharedSnapshot {
        throw SharedStateFailure.forbidden
    }
    func receipt(actor: UUID, envelope: SharedCommandEnvelope,
                 digest: String) async throws -> SharedCommandResult? { nil }
    func commit(actor: UUID, envelope: SharedCommandEnvelope, digest: String,
                result: SharedCommandResult) async throws -> SharedCommandResult {
        commits += 1
        return result
    }
}
