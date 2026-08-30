import Foundation

/// The four pairing calls, and nothing else.
///
/// Two of them are authenticated as the host device and two are not: a joiner
/// has no token yet, which is the whole reason pairing exists. The token is
/// read per request rather than captured, for the same reason the pull client
/// reads it per request — a client built before enrollment would otherwise
/// stay unauthenticated for the rest of the session.
public struct SyncPairingClient {
    public struct Claim: Equatable {
        public let claimID: String
        public let claimLookup: String
        public let claimEnvelope: String
        public let state: String
    }

    public struct Session: Equatable {
        public let sessionID: String
        public let expiresAt: String
        public let replayed: Bool
    }

    public enum PairingClientError: Error, Equatable {
        /// The status alone. Server text could carry a lookup or an envelope.
        case httpStatus(Int)
        case malformedResponse
        case notAuthenticated
    }

    private let baseURL: URL
    private let token: () -> Data?
    private let transport: SyncHTTPTransport

    public init(baseURL: URL, token: @escaping () -> Data?, transport: SyncHTTPTransport) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    // MARK: host

    public func createSession(sessionID: String, sessionLookup: Data) async throws -> Session {
        let result = try await send(
            path: "/v1/pairing/sessions",
            body: [
                "protocol_version": 1,
                "session_id": sessionID,
                "pairing_session_lookup": Self.wire(sessionLookup),
            ],
            authenticated: true
        )
        guard let id = result["session_id"] as? String,
              let expires = result["expires_at"] as? String,
              let status = result["status"] as? String else {
            throw PairingClientError.malformedResponse
        }
        return Session(sessionID: id, expiresAt: expires, replayed: status == "replayed")
    }

    public func listClaims(sessionID: String) async throws -> [Claim] {
        let result = try await send(
            path: "/v1/pairing/sessions/\(sessionID)/claims",
            body: nil,
            authenticated: true
        )
        guard let raw = result["claims"] as? [[String: Any]] else {
            throw PairingClientError.malformedResponse
        }
        return try raw.map { entry in
            guard let id = entry["claim_id"] as? String,
                  let lookup = entry["claim_lookup"] as? String,
                  let envelope = entry["claim_envelope"] as? String,
                  let state = entry["state"] as? String else {
                throw PairingClientError.malformedResponse
            }
            return Claim(claimID: id, claimLookup: lookup, claimEnvelope: envelope, state: state)
        }
    }

    public func approve(
        sessionID: String,
        claimID: String,
        claimLookup: Data,
        deliveryEnvelope: Data,
        device: (id: String, spaceID: String, platform: String, tokenHash: String)
    ) async throws {
        _ = try await send(
            path: "/v1/pairing/sessions/\(sessionID)/claims/\(claimID)/approve",
            body: [
                "protocol_version": 1,
                "claim_lookup": Self.wire(claimLookup),
                "delivery_envelope": Self.wire(deliveryEnvelope),
                "device": [
                    "device_id": device.id,
                    "space_id": device.spaceID,
                    "platform": device.platform,
                    "display_name": NSNull(),
                    "device_token_hash": device.tokenHash,
                ],
            ],
            authenticated: true
        )
    }

    // MARK: joiner

    public func submitClaim(
        sessionID: String,
        sessionLookup: Data,
        claimID: String,
        claimLookup: Data,
        claimEnvelope: Data,
        redeemVerifier: String
    ) async throws {
        let result = try await send(
            path: "/v1/pairing/sessions/\(sessionID)/claims",
            body: [
                "protocol_version": 1,
                "pairing_session_lookup": Self.wire(sessionLookup),
                "claim_id": claimID,
                "claim_lookup": Self.wire(claimLookup),
                "claim_envelope": Self.wire(claimEnvelope),
                "claim_redeem_verifier": redeemVerifier,
            ],
            authenticated: false
        )
        // Deliberately no ciphertext is expected here. At submit time the host
        // has not approved anything, so a response carrying a delivery package
        // would mean the server handed out a package nobody authorised.
        guard result["status"] as? String == "submitted" else {
            throw PairingClientError.malformedResponse
        }
    }

    /// Returns the delivery envelope. Only ever succeeds once per claim.
    public func redeem(
        sessionID: String,
        claimID: String,
        claimLookup: Data,
        redeemAuth: Data
    ) async throws -> Data {
        let result = try await send(
            path: "/v1/pairing/sessions/\(sessionID)/claims/\(claimID)/redeem",
            body: [
                "protocol_version": 1,
                "claim_lookup": Self.wire(claimLookup),
                "claim_redeem_auth": Self.wire(redeemAuth),
            ],
            authenticated: false
        )
        guard let encoded = result["delivery_envelope"] as? String,
              let envelope = Data(base64Encoded: encoded) else {
            throw PairingClientError.malformedResponse
        }
        return envelope
    }

    // MARK: transport

    private func send(
        path: String,
        body: [String: Any]?,
        authenticated: Bool
    ) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if authenticated {
            // Refused here rather than sent unauthenticated.
            guard let deviceToken = token(), deviceToken.count == 32 else {
                throw PairingClientError.notAuthenticated
            }
            request.setValue("Device gdt1_\(Self.tokenText(deviceToken))", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let response = try await transport.send(request)
        let data = response.body
        guard (200..<300).contains(response.statusCode) else {
            throw PairingClientError.httpStatus(response.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["protocol_version"] as? Int == 1,
              let result = root["result"] as? [String: Any] else {
            throw PairingClientError.malformedResponse
        }
        return result
    }

    /// Request bodies use padded standard Base64, which is what the Worker's
    /// canonical-Base64 check accepts.
    private static func wire(_ data: Data) -> String { data.base64EncodedString() }

    /// The Authorization header is the one place using unpadded Base64URL.
    private static func tokenText(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
