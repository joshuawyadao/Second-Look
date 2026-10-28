import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import VaporTesting
import SecondLookCore
@testable import SecondLookServer

@Suite(.serialized) struct ProviderRequestTests {
    private let owner = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!

    private func provider(serviceKey: String, session: URLSession) throws -> SupabaseProvider {
        let configuration = try ServerConfiguration(environment: [
            "SECONDLOOK_PROVIDER_URL": "https://second-look.test",
            "SECONDLOOK_PUBLISHABLE_KEY": "sb_publishable_synthetic",
            "SECONDLOOK_SERVICE_KEY": serviceKey,
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
        ])
        return SupabaseProvider(configuration: configuration, session: session)
    }

    @Test func modernSecretUsesAPIKeyWhileAuthUsesUserBearer() async throws {
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let provider = try provider(serviceKey: "sb_secret_synthetic", session: session)

        let snapshot = try await provider.read(actor: owner, space: nil)
        #expect(snapshot.members == [owner, peer])
        let rpc = try #require(ProviderRequestRecorder.shared.take().only)
        #expect(rpc.url?.path == "/rest/v1/rpc/sl_read")
        #expect(rpc.httpMethod == "POST")
        #expect(rpc.value(forHTTPHeaderField: "apikey") == "sb_secret_synthetic")
        #expect(rpc.value(forHTTPHeaderField: "Authorization") == nil)

        let verified = try await provider.account(for: "synthetic-user-access-token")
        #expect(verified == owner)
        let auth = try #require(ProviderRequestRecorder.shared.take().only)
        #expect(auth.url?.path == "/auth/v1/user")
        #expect(auth.value(forHTTPHeaderField: "apikey") == "sb_publishable_synthetic")
        #expect(auth.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-user-access-token")

        do {
            _ = try await provider.account(for: "synthetic-outsider-access-token")
            Issue.record("A verified account outside the explicit allowlist must be denied")
        } catch {
            #expect(error as? SharedStateFailure == .forbidden)
        }
        let denied = try #require(ProviderRequestRecorder.shared.take().only)
        #expect(denied.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-outsider-access-token")
    }

    @Test func legacyServiceRoleJWTKeepsBearerCompatibility() async throws {
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        // The local Supabase stack still supplies a legacy JWT service_role key.
        let legacyKey = "eyJ.synthetic.legacy-service-role"
        let provider = try provider(serviceKey: legacyKey, session: session)
        _ = try await provider.read(actor: owner, space: nil)
        let rpc = try #require(ProviderRequestRecorder.shared.take().only)
        #expect(rpc.value(forHTTPHeaderField: "apikey") == legacyKey)
        #expect(rpc.value(forHTTPHeaderField: "Authorization") == "Bearer \(legacyKey)")
    }

    @Test func preparationUsesOneRPCAndRejectsMalformedUnion() async throws {
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let provider = try provider(serviceKey: "sb_secret_synthetic", session: session)
        let space = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        let envelope = SharedCommandEnvelope(spaceID: space, commandID: UUID(),
            expectedSpaceRevision: 0,
            command: .startOneOff(title: "Synthetic", items: [RoutineItem(title: "Step")],
                settings: .init()))
        for (marker, expectReceipt) in [("a", false), ("b", true)] {
            let outcome = try await provider.prepare(actor: owner, envelope: envelope,
                digest: String(repeating: marker, count: 64))
            switch outcome {
            case .snapshot(let snapshot):
                #expect(!expectReceipt)
                #expect(snapshot.spaceID == space)
            case .receipt(let receipt):
                #expect(expectReceipt)
                #expect(receipt.snapshot.spaceID == space)
            }
            let request = try #require(ProviderRequestRecorder.shared.take().only)
            #expect(request.url?.path == "/rest/v1/rpc/sl_prepare")
        }
        for marker in ["c", "d", "e"] {
            do {
                _ = try await provider.prepare(actor: owner, envelope: envelope,
                    digest: String(repeating: marker, count: 64))
                Issue.record("Malformed preparation union must be rejected")
            } catch {
                #expect(error as? SharedStateFailure == .invalidResponse)
            }
            #expect(ProviderRequestRecorder.shared.take().count == 1)
        }
    }

    @Test func invitationRPCAlwaysCarriesConditionalRevision() async throws {
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let provider = try provider(serviceKey: "sb_secret_synthetic", session: session)
        for expectedRevision in [nil, 4] as [Int?] {
            let data = try SupabaseProvider.createParameters(actor: owner, peer: peer,
                inviteHash: String(repeating: "a", count: 64),
                expiresAt: Date().addingTimeInterval(600), expectedRevision: expectedRevision)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body.keys.contains("p_expected_revision"))
            if let expectedRevision {
                #expect(body["p_expected_revision"] as? Int == expectedRevision)
            } else {
                #expect(body["p_expected_revision"] is NSNull)
            }
            let created = try await provider.create(actor: owner, peer: peer,
                                          inviteHash: String(repeating: "a", count: 64),
                                          expiresAt: Date().addingTimeInterval(600),
                                          expectedRevision: expectedRevision)
            let request = try #require(ProviderRequestRecorder.shared.take().only)
            #expect(request.url?.path == "/rest/v1/rpc/sl_create")
            #expect(request.value(forHTTPHeaderField: "apikey") == "sb_secret_synthetic")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let requestBody = try #require(request.httpBody)
            let sent = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let rawSpace = try #require(sent["p_space"] as? String)
            let proposedSpace = try #require(UUID(uuidString: rawSpace))
            if expectedRevision == nil {
                #expect(created.spaceID == proposedSpace)
            } else {
                #expect(created.spaceID != proposedSpace,
                        "Renewal keeps the existing space, not the unused proposed UUID")
            }
        }
    }

    @Test func initialCreateRejectsCoherentResultWithWrongSpaceID() async throws {
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let provider = try provider(serviceKey: "sb_secret_synthetic", session: session)
        do {
            _ = try await provider.create(actor: owner, peer: peer,
                inviteHash: String(repeating: "b", count: 64),
                expiresAt: Date().addingTimeInterval(600), expectedRevision: nil)
            Issue.record("Initial creation accepted a different space UUID")
        } catch {
            #expect(error as? SharedStateFailure == .invalidResponse)
        }
        let request = try #require(ProviderRequestRecorder.shared.take().only)
        let requestBody = try #require(request.httpBody)
        let sent = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(sent["p_expected_revision"] is NSNull)
        let rawSpace = try #require(sent["p_space"] as? String)
        #expect(UUID(uuidString: rawSpace) != nil)
    }

    @Test func malformedAuthUserRepliesAreProviderFailures() async throws {
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let provider = try provider(serviceKey: "sb_secret_synthetic", session: session)
        for token in ["synthetic-malformed-json-access-token", "synthetic-invalid-id-access-token"] {
            do {
                _ = try await provider.account(for: token)
                Issue.record("Malformed Auth user replies must not look like allowlist denials")
            } catch {
                #expect(error as? SharedStateFailure == .invalidResponse)
            }
            _ = ProviderRequestRecorder.shared.take()
        }
        do {
            _ = try await provider.account(for: "synthetic-outsider-access-token")
            Issue.record("A decoded user outside the allowlist must remain forbidden")
        } catch {
            #expect(error as? SharedStateFailure == .forbidden)
        }
        _ = ProviderRequestRecorder.shared.take()
    }

    @Test func malformedAuthRepliesBecomeBoundedServerResponses() async throws {
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let provider = try provider(serviceKey: "sb_secret_synthetic", session: session)
        try await withApp { app in
            try configure(app, configuration: provider.configuration, verifier: provider, store: provider)
            for token in ["synthetic-malformed-json-access-token", "synthetic-invalid-id-access-token"] {
                try await app.testing().test(.GET, "/v1/space", beforeRequest: { request in
                    request.headers.bearerAuthorization = .init(token: token)
                }, afterResponse: { response in
                    #expect(response.status == .serviceUnavailable)
                    #expect(response.body.string == "{\"code\":\"serviceUnavailable\"}")
                    #expect(response.headers[.cacheControl] == ["no-store"])
                })
                _ = ProviderRequestRecorder.shared.take()
            }
            try await app.testing().test(.GET, "/v1/space", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "synthetic-outsider-access-token")
            }, afterResponse: { response in
                #expect(response.status == .forbidden)
                #expect(response.body.string == "{\"code\":\"forbidden\"}")
            })
            _ = ProviderRequestRecorder.shared.take()
        }
    }

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderRequestProtocol.self]
        return URLSession(configuration: config)
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}

private final class ProviderRequestRecorder: @unchecked Sendable {
    static let shared = ProviderRequestRecorder()
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
    }

    func take() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        let result = requests
        requests.removeAll()
        return result
    }
}

private final class ProviderRequestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "second-look.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let requestBody: Data
        do { requestBody = try Self.bodyData(request) }
        catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        var recorded = request
        if !requestBody.isEmpty { recorded.httpBodyStream = nil; recorded.httpBody = requestBody }
        ProviderRequestRecorder.shared.record(recorded)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body: Data
        if url.path == "/auth/v1/user" {
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            if authorization == "Bearer synthetic-malformed-json-access-token" {
                body = Data("{".utf8)
            } else if authorization == "Bearer synthetic-invalid-id-access-token" {
                body = Data("{\"id\":\"not-a-uuid\"}".utf8)
            } else {
                let id = authorization == "Bearer synthetic-outsider-access-token"
                    ? "10000000-0000-0000-0000-000000000003"
                    : "10000000-0000-0000-0000-000000000001"
                body = Data("{\"id\":\"\(id)\"}".utf8)
            }
        } else {
            let owner = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            let peer = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
            do {
                if url.path == "/rest/v1/rpc/sl_create" {
                    let parameters = try JSONSerialization.jsonObject(with: requestBody)
                        as? [String: Any] ?? [:]
                    let proposed = UUID(uuidString: parameters["p_space"] as? String ?? "") ?? UUID()
                    let renewal = parameters["p_expected_revision"] is Int
                    let wrongInitial = parameters["p_invite_hash"] as? String ==
                        String(repeating: "b", count: 64)
                    let returnedID = renewal || wrongInitial ?
                        UUID(uuidString: "10000000-0000-0000-0000-000000000099")! : proposed
                    body = try SharedWireCodec.encode(SharedSnapshot(spaceID: returnedID,
                        revision: renewal ? 5 : 0, members: [owner], state: .init()))
                } else if url.path == "/rest/v1/rpc/sl_prepare" {
                    let parameters = try JSONSerialization.jsonObject(with: requestBody)
                        as? [String: Any] ?? [:]
                    let space = UUID(uuidString: parameters["p_space"] as? String ?? "") ?? UUID()
                    let snapshot = SharedSnapshot(spaceID: space, revision: 1,
                        members: [owner, peer], state: .init())
                    let marker = (parameters["p_digest"] as? String)?.first
                    switch marker {
                    case "a": body = try SharedWireCodec.encode(["snapshot": snapshot])
                    case "b": body = try SharedWireCodec.encode(["receipt": SharedCommandResult(snapshot: snapshot)])
                    case "c": body = Data("{}".utf8)
                    case "e": body = try SharedWireCodec.encode(PreparationBoth(
                        snapshot: snapshot, receipt: SharedCommandResult(snapshot: snapshot)))
                    default: body = Data("{\"snapshot\":null,\"receipt\":null}".utf8)
                    }
                } else {
                    body = try SharedWireCodec.encode(SharedSnapshot(spaceID: UUID(), revision: 0,
                                                                     members: [owner, peer], state: .init()))
                }
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while body.count <= 64 * 1_024 {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return body }
            guard count > 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            body.append(contentsOf: buffer.prefix(count))
        }
        throw URLError(.dataLengthExceedsMaximum)
    }

    override func stopLoading() {}
}

private struct PreparationBoth: Encodable {
    let snapshot: SharedSnapshot
    let receipt: SharedCommandResult
}
