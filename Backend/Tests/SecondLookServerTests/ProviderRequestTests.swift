import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
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
        ProviderRequestRecorder.shared.record(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body: Data
        if url.path == "/auth/v1/user" {
            let id = request.value(forHTTPHeaderField: "Authorization") ==
                "Bearer synthetic-outsider-access-token"
                ? "10000000-0000-0000-0000-000000000003"
                : "10000000-0000-0000-0000-000000000001"
            body = Data("{\"id\":\"\(id)\"}".utf8)
        } else {
            let owner = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            let peer = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
            do {
                body = try SharedWireCodec.encode(SharedSnapshot(spaceID: UUID(), revision: 0,
                                                                 members: [owner, peer], state: .init()))
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
