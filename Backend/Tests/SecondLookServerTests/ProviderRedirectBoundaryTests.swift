import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
import SecondLookCore
@testable import SecondLookServer

// Real loopback sockets exercise URLSession's redirect handling. URLProtocol's
// synthetic redirects do not behave consistently on FoundationNetworking.
private final class LoopbackHTTPServer: @unchecked Sendable {
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
        guard fd >= 0 else { throw LoopbackFailure.socket }
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
            throw LoopbackFailure.socket
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0, let url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))") else {
            close(fd)
            throw LoopbackFailure.socket
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
                let reason = status == 302 ? "Found" : "OK"
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

private enum LoopbackFailure: Error { case socket }

@Suite(.serialized) struct ProviderRedirectBoundaryTests {
    private let owner = UUID(uuidString: "BB000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "BB000000-0000-0000-0000-000000000002")!

    private func provider(url: URL, serviceKey: String, session: URLSession? = nil) throws -> SupabaseProvider {
        let config = try ServerConfiguration(environment: [
            "SECONDLOOK_LOCAL_DEVELOPMENT": "1",
            "SECONDLOOK_PROVIDER_URL": url.absoluteString,
            "SECONDLOOK_PUBLISHABLE_KEY": "sb_publishable_synthetic",
            "SECONDLOOK_SERVICE_KEY": serviceKey,
            "SECONDLOOK_ALLOWED_ACCOUNTS": "\(owner),\(peer)",
        ])
        return SupabaseProvider(configuration: config, session: session ?? .shared)
    }

    @Test func rpcRedirectNeverContactsDestinationWithModernOrLegacyCredentials() async throws {
        let response = try SharedWireCodec.encode(SharedSnapshot(spaceID: UUID(),
            revision: 0, members: [owner, peer], state: .init()))
        for key in ["sb_secret_synthetic", "eyJ.synthetic.legacy-service-role"] {
            let target = try LoopbackHTTPServer { _ in (200, [:], response) }
            let origin = try LoopbackHTTPServer { _ in
                (302, ["Location": target.url.appendingPathComponent("stolen").absoluteString], Data())
            }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel(); origin.stop(); target.stop() }
            do {
                let provider = try provider(url: origin.url, serviceKey: key, session: session)
                do {
                    _ = try await provider.read(actor: owner, space: nil)
                    Issue.record("A redirected RPC was accepted")
                } catch {
                    #expect(error as? SharedStateFailure == .serviceUnavailable)
                }
            }
            #expect(origin.captured().count == 1)
            #expect(target.captured().isEmpty)
            let originalRequest = origin.captured()[0].lowercased()
            #expect(originalRequest.contains("apikey: \(key.lowercased())"))
            if key.hasPrefix("sb_secret_") {
                #expect(!originalRequest.contains("authorization:"))
            } else {
                #expect(originalRequest.contains("authorization: bearer \(key.lowercased())"))
            }
            // The provider may own and invalidate its derived session, never the injected one.
            let (_, directResponse) = try await session.data(for: URLRequest(url: target.url))
            #expect((directResponse as? HTTPURLResponse)?.statusCode == 200)
            #expect(target.captured().count == 1)
        }
    }

    @Test func authRedirectNeverContactsDestinationAndDirectAuthStillWorks() async throws {
        let authBody = Data("{\"id\":\"\(owner.uuidString)\"}".utf8)
        let target = try LoopbackHTTPServer { _ in (200, [:], authBody) }
        let origin = try LoopbackHTTPServer { _ in
            (302, ["Location": target.url.appendingPathComponent("auth/v1/user").absoluteString], Data())
        }
        defer { origin.stop(); target.stop() }
        let redirected = try provider(url: origin.url, serviceKey: "sb_secret_synthetic")
        do {
            _ = try await redirected.account(for: "synthetic-user-bearer")
            Issue.record("A redirected Auth request was accepted")
        } catch {
            #expect(error as? SharedStateFailure == .serviceUnavailable)
        }
        #expect(origin.captured().count == 1)
        #expect(target.captured().isEmpty)
        #expect(origin.captured()[0].contains("Bearer synthetic-user-bearer"))
        #expect(origin.captured()[0].lowercased().contains("apikey: sb_publishable_synthetic"))

        let direct = try provider(url: target.url, serviceKey: "sb_secret_synthetic")
        #expect(try await direct.account(for: "synthetic-user-bearer") == owner)
        #expect(target.captured().count == 1)
    }

    @Test func sameOriginRedirectIsDeniedAndDirectRPCStillWorks() async throws {
        let body = try SharedWireCodec.encode(SharedSnapshot(spaceID: UUID(),
            revision: 0, members: [owner, peer], state: .init()))
        let sameOrigin = try LoopbackHTTPServer { _ in
            (302, ["Location": "/rest/v1/rpc/sl_read?follow=1"], Data())
        }
        defer { sameOrigin.stop() }
        let redirected = try provider(url: sameOrigin.url, serviceKey: "sb_secret_synthetic")
        do {
            _ = try await redirected.read(actor: owner, space: nil)
            Issue.record("A same-origin RPC redirect was accepted")
        } catch {
            #expect(error as? SharedStateFailure == .serviceUnavailable)
        }
        #expect(sameOrigin.captured().count == 1)

        let directServer = try LoopbackHTTPServer { _ in (200, [:], body) }
        defer { directServer.stop() }
        let direct = try provider(url: directServer.url, serviceKey: "sb_secret_synthetic")
        let snapshot = try await direct.read(actor: owner, space: nil)
        #expect(snapshot.members == [owner, peer])
        #expect(directServer.captured().count == 1)
    }
}
