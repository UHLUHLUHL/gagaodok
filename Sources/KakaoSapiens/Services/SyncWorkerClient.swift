import Foundation

public struct SyncHTTPResponse {
    public let statusCode: Int
    public let body: Data
}

public protocol SyncHTTPTransport {
    func send(_ request: URLRequest) async throws -> SyncHTTPResponse
}

public struct URLSessionSyncTransport: SyncHTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> SyncHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncWorkerClientError.invalidResponse }
        return SyncHTTPResponse(statusCode: http.statusCode, body: data)
    }
}

public enum SyncWorkerClientError: Error {
    case invalidBaseURL
    case invalidToken
    case invalidResponse
    case httpStatus(Int)
}

public final class SyncWorkerClient {
    private let baseURL: URL
    /// Read afresh for every request rather than captured once.
    ///
    /// The settings screen builds its client before enrollment has stored
    /// anything, so a token captured at construction stays empty for the rest
    /// of the app session and every read is refused until a restart.
    private let token: () -> Data?
    private let transport: SyncHTTPTransport

    public init(baseURL: URL, deviceToken: Data, transport: SyncHTTPTransport = URLSessionSyncTransport()) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw SyncWorkerClientError.invalidBaseURL
        }
        guard deviceToken.count == 32 else { throw SyncWorkerClientError.invalidToken }
        self.baseURL = baseURL
        self.token = { deviceToken }
        self.transport = transport
    }

    /// A client for a token that does not exist yet.
    ///
    /// The provider is consulted per request, so a token stored after this
    /// client was built is used without rebuilding anything. While the
    /// provider has nothing to give the request is refused locally: an
    /// unauthenticated request is never sent.
    public init(
        baseURL: URL,
        token: @escaping () -> Data?,
        transport: SyncHTTPTransport = URLSessionSyncTransport()
    ) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw SyncWorkerClientError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    /// Sends exactly one oldest operation. The journal is acknowledged only
    /// after a 2xx response; every error leaves the original bytes untouched.
    public func drainOne(from outbox: SyncOutbox) async throws -> SyncHTTPResponse? {
        guard let entry = try outbox.pending().first else { return nil }
        var request = try authorizedRequest(path: "/v1/sync/operations", method: "POST")
        request.httpBody = entry.rawBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw SyncWorkerClientError.httpStatus(response.statusCode)
        }
        _ = try outbox.acknowledge(operationID: entry.operationID)
        return response
    }

    public func changes(after sequence: UInt64, limit: Int = 300) async throws -> SyncHTTPResponse {
        try await get(path: "/v1/sync/changes?after_seq=\(sequence)&limit=\(limit)")
    }

    public func bootstrap(cursor: String? = nil, limit: Int = 300) async throws -> SyncHTTPResponse {
        var path = "/v1/sync/bootstrap?limit=\(limit)"
        if let cursor {
            path += "&cursor=\(cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }
        return try await get(path: path)
    }

    private func get(path: String) async throws -> SyncHTTPResponse {
        let response = try await transport.send(try authorizedRequest(path: path, method: "GET"))
        guard (200..<300).contains(response.statusCode) else { throw SyncWorkerClientError.httpStatus(response.statusCode) }
        return response
    }

    private func authorizedRequest(path: String, method: String) throws -> URLRequest {
        guard let deviceToken = token(), deviceToken.count == 32 else {
            throw SyncWorkerClientError.invalidToken
        }
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Device gdt1_\(deviceToken.base64URLEncoded)", forHTTPHeaderField: "Authorization")
        return request
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
