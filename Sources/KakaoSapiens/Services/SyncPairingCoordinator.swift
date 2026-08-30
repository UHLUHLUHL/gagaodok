import CryptoKit
import Foundation

/// Joining an existing account, from both ends.
///
/// Two roles that know different things. The host already holds the account
/// master key and decides whether to let a device in; the joiner holds nothing
/// and only builds its own device identity. The Worker between them is a
/// mailbox: the plaintext master key never passes through it, because what the
/// joiner receives is a package the host sealed under a key derived from the
/// `pairing_secret` that was handed over by screen.
public enum SyncPairingError: Error, Equatable {
    case notConnected
    case sessionExpired
    case noSuchClaim
    /// The user has not confirmed the two screens show the same number.
    case shortAuthenticationStringNotConfirmed
    case rejected
    case storageFailed
    case transport
}

/// What the host learned about one waiting device.
public struct SyncPairingCandidate: Equatable {
    public let claimID: String
    public let claimLookup: Data
    /// The six digits the user compares against the joiner's screen.
    public let shortAuthenticationString: String
    let deviceID: String
    let spaceID: String
    let platform: String
    let claimSecret: Data
}

/// The host side: the device that is already in.
public actor SyncPairingHostCoordinator {
    private let client: SyncPairingClient
    private let secrets: () -> SyncSecretLoadResult
    private let random: SyncRandomSource

    private var sessionID: String?
    private var pairingSecret: Data?

    public init(
        client: SyncPairingClient,
        secrets: @escaping () -> SyncSecretLoadResult,
        random: SyncRandomSource
    ) {
        self.client = client
        self.secrets = secrets
        self.random = random
    }

    /// Open a session and produce the payload to show. Only a device that is
    /// actually connected may do this — an unconnected one has no master key
    /// to hand over and would strand whoever scanned it.
    public func openSession(accountID: String, baseURL: URL) async throws -> SyncPairingPayload {
        guard case .available = secrets() else { throw SyncPairingError.notConnected }
        let secret = random.bytes(32)
        let material = try? SyncE2EE.derivePairingMaterial(pairingSecret: secret, claimSecret: secret)
        guard let lookup = material?.pairingSessionLookup else { throw SyncPairingError.storageFailed }
        let session = Self.uuid(random)

        do {
            _ = try await client.createSession(sessionID: session, sessionLookup: lookup)
        } catch let error as SyncPairingClient.PairingClientError {
            throw Self.map(error)
        }

        sessionID = session
        pairingSecret = secret
        return try SyncPairingPayload(
            baseURL: baseURL,
            accountID: accountID,
            sessionID: session,
            pairingSecret: secret
        )
    }

    /// Read waiting claims and open each one. A claim this host cannot open is
    /// not for this session and is dropped rather than shown.
    public func pollCandidates() async throws -> [SyncPairingCandidate] {
        guard let session = sessionID, let secret = pairingSecret else {
            throw SyncPairingError.notConnected
        }
        let claims: [SyncPairingClient.Claim]
        do {
            claims = try await client.listClaims(sessionID: session)
        } catch let error as SyncPairingClient.PairingClientError {
            throw Self.map(error)
        }

        return claims.compactMap { claim -> SyncPairingCandidate? in
            guard claim.state == "submitted",
                  let lookup = Data(base64Encoded: claim.claimLookup),
                  let envelope = Data(base64Encoded: claim.claimEnvelope) else { return nil }
            // The claim key comes from the pairing secret alone, so only a host
            // holding the secret it showed can read what a scanner submitted.
            guard let claimKey = try? SyncE2EE.derivePairingMaterial(
                pairingSecret: secret,
                claimSecret: secret
            ).pairingClaimKey else { return nil }
            guard let plaintext = try? SyncE2EE.openPairing(
                envelope: envelope,
                key: claimKey,
                sessionID: session,
                claimID: claim.claimID,
                claimLookup: lookup,
                payloadType: .claim
            ) else { return nil }
            guard let body = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
                  let deviceID = body["device_id"] as? String,
                  let spaceID = body["space_id"] as? String,
                  let platform = body["platform"] as? String,
                  let claimSecretText = body["claim_secret"] as? String,
                  let claimSecret = Data(base64Encoded: claimSecretText) else { return nil }
            guard let material = try? SyncE2EE.derivePairingMaterial(
                pairingSecret: secret,
                claimSecret: claimSecret
            ), material.claimLookup == lookup else { return nil }

            return SyncPairingCandidate(
                claimID: claim.claimID,
                claimLookup: lookup,
                shortAuthenticationString: material.pairingSAS,
                deviceID: deviceID,
                spaceID: spaceID,
                platform: platform,
                claimSecret: claimSecret
            )
        }
    }

    /// Approve exactly one candidate, after the user says the numbers match.
    ///
    /// `sasConfirmed` is not a formality. Without a human comparing the two
    /// screens, an attacker who relayed the QR could be the one waiting, and
    /// approving would hand them the account master key.
    public func approve(
        _ candidate: SyncPairingCandidate,
        sasConfirmed: Bool
    ) async throws {
        guard sasConfirmed else { throw SyncPairingError.shortAuthenticationStringNotConfirmed }
        guard let session = sessionID, let secret = pairingSecret else {
            throw SyncPairingError.notConnected
        }
        guard case .available(let bundle) = secrets() else { throw SyncPairingError.notConnected }
        guard let material = try? SyncE2EE.derivePairingMaterial(
            pairingSecret: secret,
            claimSecret: candidate.claimSecret
        ) else { throw SyncPairingError.storageFailed }

        // A token the joiner will authenticate with. Only its hash goes to the
        // Worker; the value itself travels inside the sealed package.
        let newToken = random.bytes(32)
        let tokenHash = Data(SHA256.hash(data: newToken)).map { String(format: "%02x", $0) }.joined()
        // No account id here: the joiner already read it from the payload it
        // scanned, and a second copy inside the package would be a second
        // answer to the same question.
        let delivery: [String: Any] = [
            "account_master_key": bundle.accountMasterKey.base64EncodedString(),
            "device_token": newToken.base64EncodedString(),
        ]
        guard let plaintext = try? JSONSerialization.data(withJSONObject: delivery, options: [.sortedKeys]),
              let envelope = try? SyncE2EE.sealPairing(
                  plaintext: plaintext,
                  key: material.pairingDeliveryKey,
                  nonce: random.bytes(12),
                  sessionID: session,
                  claimID: candidate.claimID,
                  claimLookup: candidate.claimLookup,
                  payloadType: .delivery
              ) else { throw SyncPairingError.storageFailed }

        do {
            try await client.approve(
                sessionID: session,
                claimID: candidate.claimID,
                claimLookup: candidate.claimLookup,
                deliveryEnvelope: envelope,
                device: (
                    id: candidate.deviceID,
                    spaceID: candidate.spaceID,
                    platform: candidate.platform,
                    tokenHash: tokenHash
                )
            )
        } catch let error as SyncPairingClient.PairingClientError {
            throw Self.map(error)
        }
    }

    static func uuid(_ random: SyncRandomSource) -> String {
        var bytes = [UInt8](random.bytes(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let ranges = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        return ranges.map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }.joined(separator: "-")
    }

    static func map(_ error: SyncPairingClient.PairingClientError) -> SyncPairingError {
        switch error {
        case .httpStatus(let status) where status == 404 || status == 410: return .sessionExpired
        case .httpStatus(let status) where status == 409: return .rejected
        case .httpStatus: return .rejected
        case .notAuthenticated: return .notConnected
        case .malformedResponse: return .transport
        }
    }
}

/// The joiner side: a device that belongs to no account yet.
public actor SyncPairingJoinerCoordinator {
    private let random: SyncRandomSource
    private let vault: SyncSecretVault
    private let connectionStore: SyncConnectionStateStore

    private var payload: SyncPairingPayload?
    private var claimID: String?
    private var claimSecret: Data?
    private var material: SyncE2EE.PairingMaterial?

    public init(
        random: SyncRandomSource,
        vault: SyncSecretVault,
        connectionStore: SyncConnectionStateStore
    ) {
        self.random = random
        self.vault = vault
        self.connectionStore = connectionStore
    }

    /// Accept a scanned payload and build this device's claim. Nothing is sent.
    public func accept(text: String, deviceID: String, spaceID: String, platform: String) throws
        -> (payload: SyncPairingPayload, claimID: String, shortAuthenticationString: String) {
        let scanned = try SyncPairingPayload.decode(text: text)
        let secret = random.bytes(32)
        let claim = SyncPairingHostCoordinator.uuid(random)
        guard let derived = try? SyncE2EE.derivePairingMaterial(
            pairingSecret: scanned.pairingSecret,
            claimSecret: secret
        ) else { throw SyncPairingError.storageFailed }

        payload = scanned
        claimID = claim
        claimSecret = secret
        material = derived
        self.deviceIdentity = (deviceID, spaceID, platform)
        return (scanned, claim, derived.pairingSAS)
    }

    private var deviceIdentity: (id: String, space: String, platform: String)?

    public func submit(using client: SyncPairingClient) async throws {
        guard let scanned = payload, let claim = claimID, let secret = claimSecret,
              let derived = material, let identity = deviceIdentity else {
            throw SyncPairingError.notConnected
        }
        let body: [String: Any] = [
            "device_id": identity.id,
            "space_id": identity.space,
            "platform": identity.platform,
            "claim_secret": secret.base64EncodedString(),
        ]
        guard let plaintext = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let hostKey = try? SyncE2EE.derivePairingMaterial(
                  pairingSecret: scanned.pairingSecret,
                  claimSecret: scanned.pairingSecret
              ).pairingClaimKey,
              let envelope = try? SyncE2EE.sealPairing(
                  plaintext: plaintext,
                  key: hostKey,
                  nonce: random.bytes(12),
                  sessionID: scanned.sessionID,
                  claimID: claim,
                  claimLookup: derived.claimLookup,
                  payloadType: .claim
              ),
              let verifier = try? SyncE2EE.claimRedeemVerifier(
                  sessionID: scanned.sessionID,
                  claimID: claim,
                  claimLookup: derived.claimLookup,
                  claimRedeemAuth: derived.claimRedeemAuth
              ) else { throw SyncPairingError.storageFailed }

        do {
            try await client.submitClaim(
                sessionID: scanned.sessionID,
                sessionLookup: derived.pairingSessionLookup,
                claimID: claim,
                claimLookup: derived.claimLookup,
                claimEnvelope: envelope,
                redeemVerifier: verifier.map { String(format: "%02x", $0) }.joined()
            )
        } catch let error as SyncPairingClient.PairingClientError {
            throw SyncPairingHostCoordinator.map(error)
        }
    }

    /// Redeem once and store what came back.
    ///
    /// Nothing is written until the package opens and its contents check out.
    /// A half-linked device — secrets without a connection, or the reverse — is
    /// a state the user has no way to repair.
    public func redeem(using client: SyncPairingClient, sasConfirmed: Bool) async throws {
        guard sasConfirmed else { throw SyncPairingError.shortAuthenticationStringNotConfirmed }
        guard let scanned = payload, let claim = claimID, let derived = material,
              let identity = deviceIdentity else {
            throw SyncPairingError.notConnected
        }

        let envelope: Data
        do {
            envelope = try await client.redeem(
                sessionID: scanned.sessionID,
                claimID: claim,
                claimLookup: derived.claimLookup,
                redeemAuth: derived.claimRedeemAuth
            )
        } catch let error as SyncPairingClient.PairingClientError {
            throw SyncPairingHostCoordinator.map(error)
        }

        guard let plaintext = try? SyncE2EE.openPairing(
            envelope: envelope,
            key: derived.pairingDeliveryKey,
            sessionID: scanned.sessionID,
            claimID: claim,
            claimLookup: derived.claimLookup,
            payloadType: .delivery
        ) else { throw SyncPairingError.rejected }

        guard let body = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let masterText = body["account_master_key"] as? String,
              let tokenText = body["device_token"] as? String,
              let master = Data(base64Encoded: masterText),
              let token = Data(base64Encoded: tokenText),
              let bundle = try? SyncSecretBundle(accountMasterKey: master, deviceToken: token) else {
            throw SyncPairingError.rejected
        }

        do { try vault.save(bundle) } catch { throw SyncPairingError.storageFailed }
        // The account is the host's, and synchronisation stays off: joining is
        // a connection, not a decision to start syncing.
        guard let configuration = try? SyncConnectionConfiguration(
            baseURL: scanned.baseURL,
            accountID: scanned.accountID,
            deviceID: identity.id,
            enabled: false,
            changesCursor: nil
        ), (try? connectionStore.save(configuration)) != nil else {
            throw SyncPairingError.storageFailed
        }
    }
}
