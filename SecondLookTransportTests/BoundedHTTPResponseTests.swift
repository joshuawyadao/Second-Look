import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SecondLookCore
import SecondLookTransport

@MainActor
final class BoundedHTTPResponseTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticTransportProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func auth(host: String, session: URLSession) -> SharedAuthClient {
        SharedAuthClient(authURL: URL(string: "https://\(host)")!, publishableKey: "invented-public-key",
                         session: session)
    }

    private func command(host: String, session: URLSession) -> SharedHTTPClient {
        SharedHTTPClient(serverURL: URL(string: "https://\(host)")!,
                         accessToken: "invented-access-token", session: session)
    }

    func testDeclaredOversizedSuccessAndErrorAreRejectedBeforeBody() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await auth(host: "declared-auth-large.test", session: session)
                .signIn(email: "invented@example.test", password: "invented-password")
            XCTFail("A declared oversized Auth success must be refused")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .invalidResponse) }

        do {
            _ = try await command(host: "declared-command-large.test", session: session).currentSpace()
            XCTFail("A declared oversized command success must be refused")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .invalidResponse) }

        do {
            _ = try await auth(host: "declared-error-large.test", session: session)
                .signIn(email: "invented@example.test", password: "invented-password")
            XCTFail("An oversized error must not classify credentials")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable) }
    }

    func testUnknownLengthStreamStopsOnceErrorLimitIsReached() async throws {
        BoundedResponseFixture.resetStreamCount()
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await auth(host: "streamed-error-large.test", session: session)
                .signIn(email: "invented@example.test", password: "invented-password")
            XCTFail("An unannounced oversized error must be refused")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThan(BoundedResponseFixture.streamedChunkCount, 128,
                          "The receiver must cancel before all 128 chunks can be buffered")
        XCTAssertGreaterThan(BoundedResponseFixture.streamedChunkCount, 16,
                             "The test must actually cross the 16 KiB error limit")
    }

    func testBoundedSuccessesAndInjectedSessionRemainUsable() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let signedIn = try await auth(host: "valid-auth.test", session: session)
            .signIn(email: "invented@example.test", password: "invented-password")
        XCTAssertEqual(signedIn.access_token, "invented-access")
        let snapshot = try await command(host: "valid-command.test", session: session).currentSpace()
        XCTAssertEqual(snapshot.revision, 1)
        let (_, response) = try await session.data(
            for: URLRequest(url: URL(string: "https://valid-auth.test/auth/v1/token")!))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testCancellationStopsDerivedTaskWithoutInvalidatingInjectedSession() async throws {
        BoundedResponseFixture.resetDelayedCount()
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = auth(host: "delayed-auth.test", session: session)
        let pending = Task {
            try await client.signIn(email: "invented@example.test", password: "invented-password")
        }
        for _ in 0..<100 where BoundedResponseFixture.delayedStarted == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(BoundedResponseFixture.delayedStarted, 1)
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("Cancellation must not publish a session")
        } catch { XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable) }
        XCTAssertEqual(BoundedResponseFixture.delayedStopped, 1)
        let signedIn = try await auth(host: "valid-auth.test", session: session)
            .signIn(email: "invented@example.test", password: "invented-password")
        XCTAssertEqual(signedIn.access_token, "invented-access")
    }
}

/// Reuse the established synthetic protocol class so Linux FoundationNetworking
/// never chooses between two competing URLProtocol subclasses in one test run.
enum BoundedResponseFixture {
    private static let streamCounter = StreamCounter()
    private static let delayedCounter = DelayedCounter()

    static var streamedChunkCount: Int {
        streamCounter.value
    }

    static func resetStreamCount() {
        streamCounter.reset()
    }

    static var delayedStarted: Int { delayedCounter.started }
    static var delayedStopped: Int { delayedCounter.stopped }
    static func resetDelayedCount() { delayedCounter.reset() }

    static func start(_ protocolInstance: SyntheticTransportProtocol) -> Bool {
        guard let url = protocolInstance.request.url else { return false }
        let host = url.host ?? ""
        guard host.hasSuffix("-large.test") || host.hasPrefix("valid-") ||
                host == "delayed-auth.test" else { return false }
        if host == "delayed-auth.test" {
            Self.delayedCounter.didStart()
            return true
        }
        let declared = host.hasPrefix("declared-")
        let error = host.contains("error-")
        let fields = declared
            ? ["Content-Length": String(error ? 17 * 1_024 : 17 * 1_024 * 1_024)]
            : ["Content-Type": "application/json"]
        let response = HTTPURLResponse(url: url, statusCode: error ? 400 : 200,
                                       httpVersion: nil, headerFields: fields)!
        protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response,
                                             cacheStoragePolicy: .notAllowed)
        if declared {
            // These bodies are otherwise valid. A data(for:) receiver accepts
            // them despite the advertised size and exposes the wrong result.
            let body: Data
            switch host {
            case "declared-auth-large.test": body = Self.validAuthBody
            case "declared-command-large.test": body = Self.validCommandBody
            default: body = Data(#"{"error_code":"invalid_credentials"}"#.utf8)
            }
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: body)
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
            return true
        }
        if host == "streamed-error-large.test" {
            let stream = BoundedResponseStream(protocolInstance: protocolInstance,
                                               counter: Self.streamCounter)
            DispatchQueue.global(qos: .userInitiated).async { stream.run() }
            return true
        }
        let body = host == "valid-command.test" ? Self.validCommandBody : Self.validAuthBody
        protocolInstance.client?.urlProtocol(protocolInstance, didLoad: body)
        protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        return true
    }

    private static var validCommandBody: Data {
        let snapshot = SharedSnapshot(spaceID: UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!,
                                      revision: 1,
                                      members: [UUID(uuidString: "AA000000-0000-0000-0000-000000000002")!],
                                      state: .init())
        return try! SharedWireCodec.encode(snapshot)
    }

    private static var validAuthBody: Data {
        Data("{\"access_token\":\"invented-access\",\"refresh_token\":\"invented-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"AA000000-0000-0000-0000-000000000002\"}}".utf8)
    }

    static func didStop(_ protocolInstance: SyntheticTransportProtocol) -> Bool {
        guard protocolInstance.request.url?.host == "delayed-auth.test" else { return false }
        delayedCounter.didStop()
        return true
    }
}

/// The URLProtocol test double is Foundation-owned and cannot be Sendable; this
/// wrapper confines the off-queue fixture producer to one reference and a
/// lock-protected cancellation flag.
private final class BoundedResponseStream: @unchecked Sendable {
    private let protocolInstance: SyntheticTransportProtocol
    private let counter: StreamCounter

    init(protocolInstance: SyntheticTransportProtocol, counter: StreamCounter) {
        self.protocolInstance = protocolInstance
        self.counter = counter
    }

    func run() {
        for _ in 0..<128 {
            guard !protocolInstance.fixtureStopped else { return }
            counter.increment()
            protocolInstance.client?.urlProtocol(protocolInstance,
                                                didLoad: Data(repeating: 65, count: 1_024))
            Thread.sleep(forTimeInterval: 0.002)
        }
        if !protocolInstance.fixtureStopped {
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
    }
}

private final class DelayedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var stopCount = 0

    var started: Int {
        lock.lock()
        defer { lock.unlock() }
        return startCount
    }

    var stopped: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopCount
    }

    func reset() {
        lock.lock()
        startCount = 0
        stopCount = 0
        lock.unlock()
    }

    func didStart() {
        lock.lock()
        startCount += 1
        lock.unlock()
    }

    func didStop() {
        lock.lock()
        stopCount += 1
        lock.unlock()
    }
}

private final class StreamCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
