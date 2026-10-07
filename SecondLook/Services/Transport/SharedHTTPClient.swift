import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SecondLookCore

public struct PairingInvitation: Codable, Equatable, Sendable {
    public let snapshot: SharedSnapshot
    public let inviteToken: String
    public let expiresAt: Date
}

/// HTTP transport for the authenticated private-space service. The token supplier belongs to
/// one account session; callers must create a new client when that session changes.
public struct SharedHTTPClient: SharedStateClient {
    private let endpoint: PrivateHTTPEndpoint
    private let bearerToken: @Sendable () async throws -> String

    public init(serverURL: URL, bearerToken: @escaping @Sendable () async throws -> String,
                allowLocalHTTP: Bool = false, session: URLSession = .shared) {
        endpoint = PrivateHTTPEndpoint(baseURL: serverURL, allowLocalHTTP: allowLocalHTTP,
                                       session: session, apiKey: nil, failureFormat: .commandService)
        self.bearerToken = bearerToken
    }

    public init(serverURL: URL, accessToken: String, allowLocalHTTP: Bool = false,
                session: URLSession = .shared) {
        self.init(serverURL: serverURL, bearerToken: { accessToken },
                  allowLocalHTTP: allowLocalHTTP, session: session)
    }

    public func currentSpace() async throws -> SharedSnapshot {
        try await endpoint.send(path: ["v1", "space"], method: "GET", token: bearerToken())
    }

    public func createSpace() async throws -> PairingInvitation {
        try await endpoint.send(path: ["v1", "spaces"], method: "POST", token: bearerToken(),
                                body: EmptyRequest())
    }

    public func joinSpace(inviteToken: String) async throws -> SharedSnapshot {
        try await endpoint.send(path: ["v1", "pairing", "join"], method: "POST",
                                token: bearerToken(), body: JoinRequest(inviteToken: inviteToken))
    }

    public func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        try await endpoint.send(path: ["v1", "spaces", spaceID.uuidString], method: "GET",
                                token: bearerToken())
    }

    public func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        try await endpoint.send(path: ["v1", "spaces", envelope.spaceID.uuidString, "commands"],
                                method: "POST", token: bearerToken(), body: envelope)
    }
}

private struct EmptyRequest: Encodable, Sendable {}
private struct JoinRequest: Encodable, Sendable { let inviteToken: String }

/// Bounded Auth rejection; raw provider messages and credentials never enter product errors.
public enum SharedAuthFailure: Error, Equatable, Sendable {
    case invalidCredentials
}

/// Supabase Auth REST endpoints; the publishable key is public configuration, never a service key.
public struct SharedAuthClient: Sendable {
    private let endpoint: PrivateHTTPEndpoint

    public init(authURL: URL, publishableKey: String, allowLocalHTTP: Bool = false,
                session: URLSession = .shared) {
        endpoint = PrivateHTTPEndpoint(baseURL: authURL, allowLocalHTTP: allowLocalHTTP,
                                       session: session, apiKey: publishableKey, failureFormat: .supabaseAuth)
    }

    public func signIn(email: String, password: String) async throws -> SharedAuthSession {
        try await endpoint.send(path: ["auth", "v1", "token"], method: "POST", token: nil,
                                query: [URLQueryItem(name: "grant_type", value: "password")],
                                body: Credentials(email: email, password: password))
    }

    public func refresh(refreshToken: String) async throws -> SharedAuthSession {
        try await endpoint.send(path: ["auth", "v1", "token"], method: "POST", token: nil,
                                query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                body: RefreshRequest(refresh_token: refreshToken))
    }

    public func getUser(accessToken: String) async throws -> SharedAuthUser {
        try await endpoint.send(path: ["auth", "v1", "user"], method: "GET", token: accessToken)
    }
}

public struct SharedAuthUser: Codable, Equatable, Sendable {
    public let id: UUID
    public let email: String?
}

public struct SharedAuthSession: Codable, Equatable, Sendable {
    public let access_token: String
    public let refresh_token: String
    public let expires_at: Int?
    public let expires_in: Int?
    public let user: SharedAuthUser
}

private struct Credentials: Encodable, Sendable { let email: String; let password: String }
private struct RefreshRequest: Encodable, Sendable { let refresh_token: String }
private enum HTTPFailureFormat { case commandService, supabaseAuth }

/// Kept in the same target as the app's transport so package tests exercise exact request code.
private struct PrivateHTTPEndpoint: @unchecked Sendable {
    let baseURL: URL
    let allowLocalHTTP: Bool
    let session: URLSession
    let apiKey: String?
    let failureFormat: HTTPFailureFormat

    func send<Response: Decodable>(path: [String], method: String, token: String?,
                                   query: [URLQueryItem] = []) async throws -> Response {
        try await send(path: path, method: method, token: token, query: query,
                       body: Optional<EmptyRequest>.none)
    }

    func send<Request: Encodable, Response: Decodable>(path: [String], method: String,
                                                       token: String?, query: [URLQueryItem] = [],
                                                       body: Request?) async throws -> Response {
        guard let scheme = baseURL.scheme?.lowercased(),
              (scheme == "https" || (allowLocalHTTP && scheme == "http" &&
                ["localhost", "127.0.0.1", "::1"].contains(baseURL.host?.lowercased() ?? ""))),
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              !path.contains(where: { $0 == ".." || $0.contains("/") }),
              apiKey.map({ !$0.isEmpty }) ?? true else { throw SharedStateFailure.invalidResponse }
        var url = baseURL
        for part in path { url.appendPathComponent(part) }
        if !query.isEmpty {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw SharedStateFailure.invalidResponse
            }
            parts.queryItems = query
            guard let built = parts.url else { throw SharedStateFailure.invalidResponse }
            url = built
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "apikey") }
        if let token {
            guard !token.isEmpty, !token.contains("\n"), !token.contains("\r") else {
                throw SharedStateFailure.unauthenticated
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try SharedWireCodec.encode(body)
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw SharedStateFailure.serviceUnavailable }
        guard let http = response as? HTTPURLResponse else { throw SharedStateFailure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw failure(status: http.statusCode, data: data)
        }
        do { return try SharedWireCodec.decode(Response.self, from: data) }
        catch { throw SharedStateFailure.invalidResponse }
    }

    private func failure(status: Int, data: Data) -> any Error {
        if failureFormat == .supabaseAuth, status == 400 {
            let authCode = (try? SharedWireCodec.decode(AuthError.self, from: data))?.error_code
            switch authCode {
            case "invalid_credentials": return SharedAuthFailure.invalidCredentials
            case "refresh_token_not_found", "refresh_token_already_used":
                return SharedStateFailure.unauthenticated
            default: return SharedStateFailure.invalidResponse
            }
        }
        return Self.serviceFailure(status: status, data: data)
    }

    private static func serviceFailure(status: Int, data: Data) -> SharedStateFailure {
        let code = (try? SharedWireCodec.decode(ServiceError.self, from: data))?.code
        switch status {
        case 401: return .unauthenticated
        case 403: return .forbidden
        case 404: return .notPaired
        case 409: return code == "pairingUnavailable" ? .pairingUnavailable : .staleState
        case 400:
            switch code {
            case "invalidInvite": return .invalidInvite
            case "invalidDefinition": return .domain(.invalidDefinition)
            case "unauthorized": return .domain(.unauthorized)
            case "reviewerRequired": return .domain(.reviewerRequired)
            case "wrongItemType": return .domain(.wrongItemType)
            case "closed": return .domain(.closed)
            case "staleVersion": return .domain(.staleVersion)
            case "invalidTransition": return .domain(.invalidTransition)
            case "noteRequired": return .domain(.noteRequired)
            case "notFound": return .domain(.notFound)
            default: return .invalidResponse
            }
        default: return .serviceUnavailable
        }
    }
}

private struct ServiceError: Decodable { let code: String }
private struct AuthError: Decodable { let error_code: String }
