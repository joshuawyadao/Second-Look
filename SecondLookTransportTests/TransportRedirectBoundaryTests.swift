import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import XCTest
import SecondLookCore
import SecondLookTransport

// Real loopback sockets exercise URLSession's redirect handling. URLProtocol's
// synthetic redirects do not behave consistently on FoundationNetworking.
private final class TransportLoopbackHTTPServer: @unchecked Sendable {
    private let listener: Int32
    private let lock = NSLock()
    private var requests: [String] = []
    private let respond: @Sendable (String) -> (Int, [String: String], Data)
    let url: URL

    init(respond: @escaping @Sendable (String) -> (Int, [String: String], Data)) throws {
        #if canImport(Darwin)
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw TransportLoopbackFailure.socket }
        listener = fd
        self.respond = respond
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw TransportLoopbackFailure.socket
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0, let url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))") else {
            close(fd)
            throw TransportLoopbackFailure.socket
        }
        self.url = url
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                let connection = accept(listener, nil, nil)
                if connection < 0 { return }
                var deadline = timeval(tv_sec: 3, tv_usec: 0)
                _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &deadline,
                               socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &deadline,
                               socklen_t(MemoryLayout<timeval>.size))
                #if canImport(Darwin)
                var noSignal: Int32 = 1
                _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                               socklen_t(MemoryLayout<Int32>.size))
                #endif
                guard let request = Self.readRequest(connection) else {
                    close(connection)
                    continue
                }
                lock.lock()
                requests.append(request)
                lock.unlock()
                let (status, headers, body) = respond(request)
                let reason = status == 307 ? "Temporary Redirect" : status == 308 ? "Permanent Redirect" : "OK"
                var header = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
                for (name, value) in headers { header += "\(name): \(value)\r\n" }
                header += "\r\n"
                let output = Array(header.utf8) + Array(body)
                Self.writeAll(output, to: connection)
                close(connection)
            }
        }
    }

    private static func readRequest(_ connection: Int32) -> String? {
        let limit = 64 * 1_024
        let delimiter = Data("\r\n\r\n".utf8)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var data = Data()
        var totalNeeded: Int?
        while data.count < limit {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            var timeout = timeval(tv_sec: Int(remaining),
                                  tv_usec: suseconds_t((remaining.truncatingRemainder(dividingBy: 1)) * 1_000_000))
            _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                           socklen_t(MemoryLayout<timeval>.size))
            var chunk = [UInt8](repeating: 0, count: min(4_096, limit - data.count))
            let count = recv(connection, &chunk, chunk.count, 0)
            guard count > 0 else { return nil }
            data.append(contentsOf: chunk.prefix(count))
            if totalNeeded == nil, let boundary = data.range(of: delimiter) {
                let headers = String(decoding: data[..<boundary.lowerBound], as: UTF8.self)
                let lengthField = headers.components(separatedBy: "\r\n").first {
                    $0.lowercased().hasPrefix("content-length:")
                }
                let length: Int
                if let lengthField {
                    guard let parsed = Int(String(lengthField.dropFirst("content-length:".count))
                        .trimmingCharacters(in: .whitespaces)) else { return nil }
                    length = parsed
                } else {
                    length = 0
                }
                guard length >= 0, length <= limit - boundary.upperBound else { return nil }
                totalNeeded = boundary.upperBound + length
            }
            if let totalNeeded, data.count >= totalNeeded {
                return String(decoding: data.prefix(totalNeeded), as: UTF8.self)
            }
        }
        return nil
    }

    private static func writeAll(_ bytes: [UInt8], to connection: Int32) {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                #if canImport(Darwin)
                let sent = send(connection, base.advanced(by: offset), bytes.count - offset, 0)
                #else
                let sent = send(connection, base.advanced(by: offset), bytes.count - offset,
                                Int32(MSG_NOSIGNAL))
                #endif
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }

    func captured() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func stop() {
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
    }
}

private enum TransportLoopbackFailure: Error { case socket }

@MainActor
final class TransportRedirectBoundaryTests: XCTestCase {
    private let userID = UUID(uuidString: "CC000000-0000-0000-0000-000000000001")!
    private let inventedPassword = "invented-password-for-redirect-test"
    private let inventedRefresh = "invented-refresh-for-redirect-test"

    private var validAuthBody: Data {
        let body: [String: Any] = [
            "access_token": "invented-access-result",
            "refresh_token": "invented-refresh-result",
            "expires_in": 3_600,
            "user": ["id": userID.uuidString, "email": "invented@example.test"],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func authenticate(_ client: SharedAuthClient, refreshing: Bool) async throws
        -> SharedAuthSession {
        if refreshing { return try await client.refresh(refreshToken: inventedRefresh) }
        return try await client.signIn(email: "invented@example.test",
                                       password: inventedPassword)
    }

    func testAuth307And308NeverResendPasswordOrRefreshBodyToDestination() async throws {
        for status in [307, 308] {
            for refreshing in [false, true] {
                for injected in [false, true] {
                    try await { () async throws -> Void in
                        let body = validAuthBody
                        let target = try TransportLoopbackHTTPServer { _ in (200, [:], body) }
                        let origin = try TransportLoopbackHTTPServer { _ in
                            (status, ["Location": target.url.appendingPathComponent("auth/v1/token")
                                .absoluteString], Data())
                        }
                        let injectedSession = injected ? URLSession(configuration: .ephemeral) : nil
                        defer {
                            injectedSession?.invalidateAndCancel()
                            origin.stop()
                            target.stop()
                        }
                        let client = SharedAuthClient(authURL: origin.url,
                            publishableKey: "invented-public-key", allowLocalHTTP: true,
                            session: injectedSession ?? .shared)
                        do {
                            _ = try await authenticate(client, refreshing: refreshing)
                            XCTFail("A redirected Auth POST was accepted")
                        } catch {
                            XCTAssertEqual(error as? SharedStateFailure, .serviceUnavailable)
                        }
                        let originalCount = origin.captured().count
                        let destination = target.captured()
                        let destinationCount = destination.count
                        if destinationCount > 0 {
                            let marker = refreshing ? inventedRefresh : inventedPassword
                            let receivedBody = destination.contains {
                                $0.hasPrefix("POST ") && $0.contains(marker)
                            }
                            XCTAssertTrue(receivedBody, "Old-code leak proof must include the invented POST body")
                        }
                        XCTAssertEqual(originalCount, 1)
                        XCTAssertEqual(destinationCount, 0)
                    }()
                }
            }
        }
    }

    func testDirect200SignInAndRefreshRemainValidForDefaultAndInjectedSessions() async throws {
        for refreshing in [false, true] {
            for injected in [false, true] {
                try await { () async throws -> Void in
                    let body = validAuthBody
                    let origin = try TransportLoopbackHTTPServer { _ in (200, [:], body) }
                    let injectedSession = injected ? URLSession(configuration: .ephemeral) : nil
                    defer { injectedSession?.invalidateAndCancel(); origin.stop() }
                    let client = SharedAuthClient(authURL: origin.url,
                        publishableKey: "invented-public-key", allowLocalHTTP: true,
                        session: injectedSession ?? .shared)
                    let result = try await authenticate(client, refreshing: refreshing)
                    let validResponse = result.user.id == userID && result.expires_in == 3_600 &&
                        result.access_token == "invented-access-result" &&
                        result.refresh_token == "invented-refresh-result"
                    XCTAssertTrue(validResponse)
                    let received = origin.captured()
                    XCTAssertEqual(received.count, 1)
                    let marker = refreshing ? inventedRefresh : inventedPassword
                    let receivedBody = received.contains {
                        $0.hasPrefix("POST ") && $0.contains(marker)
                    }
                    XCTAssertTrue(receivedBody)
                }()
            }
        }
    }
}

