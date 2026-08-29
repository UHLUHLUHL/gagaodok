import Foundation
import Security

/// Enrollment, end to end, with the order of operations as the contract.
///
/// The individual pieces already exist — the package builder, the secret
/// vault, the enrollment journal, the connection state and the Worker client.
/// What was missing is the sequence they have to run in, because every
/// dangerous outcome here is an ordering mistake: sending before the user has
/// written the phrase down, storing secrets for an enrollment the server never
/// accepted, or acknowledging a journal entry whose request never landed.
///
/// Sync stays off after a successful enrollment. Connecting an account and
/// turning synchronisation on are separate decisions, and only the second one
/// touches real conversations.

// MARK: - Injection seams

/// The secret vault, behind a protocol so a test never touches the Keychain.
public protocol SyncSecretVault {
    func load() -> SyncSecretLoadResult
    func save(_ bundle: SyncSecretBundle) throws
}

/// The real vault. Device-local, non-exportable, and never used from a test.
public struct KeychainSyncSecretVault: SyncSecretVault {
    public init() {}
    public func load() -> SyncSecretLoadResult { SyncSecretStore.load() }
    public func save(_ bundle: SyncSecretBundle) throws { try SyncSecretStore.save(bundle) }
}

/// Random material, so a test can make a draft reproducible without weakening
/// what the app actually generates.
public protocol SyncRandomSource {
    func bytes(_ count: Int) -> Data
}

public struct SystemSyncRandomSource: SyncRandomSource {
    public init() {}
    public func bytes(_ count: Int) -> Data {
        var value = Data(count: count)
        value.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        return value
    }
}

// MARK: - Surface

public enum SyncOnboardingStatus: Equatable {
    /// No account is linked. This is the state a fresh install is in.
    case disconnected
    /// Linked. `enabled` says whether the user has turned sync on, which is a
    /// separate decision from having connected.
    case connected(SyncConnectionConfiguration)
    /// The secrets and the endpoint state disagree, so neither is trusted.
    case relinkRequired
}

public enum SyncOnboardingError: Error {
    case alreadyConnected
    case relinkRequired
    /// The user was shown a recovery phrase and did not type it back.
    case phraseNotConfirmed
    /// The server refused the enrollment. The staged bytes are kept.
    case enrollmentRejected(Int)
    case malformedResponse
    case noPendingEnrollment
}

/// What the user must see exactly once, plus the request that will be sent.
///
/// The phrase lives here and nowhere else: it is never written to the journal,
/// the vault, the connection state or a log. Losing it means losing the
/// account, and storing it on the device would defeat the point of having one.
public struct SyncOnboardingDraft {
    public let accountID: String
    public let deviceID: String
    public let enrollmentID: String
    public let recoveryPhrase: String
    let package: SyncEnrollmentPackage
}

// MARK: - Coordinator

public final class SyncOnboardingCoordinator {
    private let baseURL: URL
    private let vault: SyncSecretVault
    private let connectionStore: SyncConnectionStateStore
    private let journal: SyncEnrollmentJournal
    private let transport: SyncHTTPTransport
    private let random: SyncRandomSource
    private let words: [String]

    public init(
        baseURL: URL,
        vault: SyncSecretVault,
        connectionStore: SyncConnectionStateStore,
        journal: SyncEnrollmentJournal,
        transport: SyncHTTPTransport,
        random: SyncRandomSource = SystemSyncRandomSource(),
        words: [String]
    ) throws {
        guard baseURL.scheme == "https", baseURL.host != nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw SyncWorkerClientError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.vault = vault
        self.connectionStore = connectionStore
        self.journal = journal
        self.transport = transport
        self.random = random
        self.words = words
    }

    /// The two halves of "connected" read together.
    ///
    /// Secrets without endpoint state, or endpoint state without secrets, is a
    /// half-finished link. It is reported as `relinkRequired` rather than
    /// repaired, because the missing half cannot be reconstructed and guessing
    /// at it would attach this device to the wrong account.
    public func status() -> SyncOnboardingStatus {
        let secrets = vault.load()
        let connection = connectionStore.load()
        switch (secrets, connection) {
        case (.absent, .absent):
            return .disconnected
        case (.available, .available(let configuration)):
            return .connected(configuration)
        default:
            return .relinkRequired
        }
    }

    /// Build the enrollment without sending it.
    ///
    /// Nothing is staged, stored or transmitted here. The caller shows the
    /// phrase, and only a caller that can hand it back gets to `confirm`.
    public func prepare(
        accountID: String,
        deviceID: String,
        enrollmentID: String,
        spaceID: String,
        platform: String
    ) throws -> SyncOnboardingDraft {
        switch status() {
        case .connected:
            throw SyncOnboardingError.alreadyConnected
        case .relinkRequired:
            throw SyncOnboardingError.relinkRequired
        case .disconnected:
            break
        }

        let package = try SyncEnrollmentBuilder.build(
            accountID: accountID,
            deviceID: deviceID,
            enrollmentID: enrollmentID,
            spaceID: spaceID,
            platform: platform,
            accountMasterKey: random.bytes(32),
            deviceToken: random.bytes(32),
            // 16 bytes: BIP-39 twelve words, which is what the recovery
            // material and the mnemonic codec both require.
            recoveryEntropy: random.bytes(16),
            recoveryNonce: random.bytes(12),
            words: words
        )
        return SyncOnboardingDraft(
            accountID: accountID,
            deviceID: deviceID,
            enrollmentID: enrollmentID,
            recoveryPhrase: package.recoveryPhrase,
            package: package
        )
    }

    /// Send the enrollment, then activate — never the other way round.
    ///
    /// `confirmedPhrase` must be what `prepare` returned. It is the only
    /// evidence the app has that the phrase was actually written down, and
    /// without it a user could complete enrollment and then be unable to
    /// recover the account from any other device.
    @discardableResult
    public func confirm(
        _ draft: SyncOnboardingDraft,
        confirmedPhrase: String
    ) async throws -> SyncConnectionConfiguration {
        guard confirmedPhrase == draft.recoveryPhrase else {
            throw SyncOnboardingError.phraseNotConfirmed
        }

        // Staged first, so a crash between here and the response leaves the
        // exact bytes to retry. Enrollment is idempotent on those bytes; a
        // re-serialised body would be a different request.
        try journal.stage(enrollmentID: draft.enrollmentID, rawBody: draft.package.rawRequestBody)
        return try await send(
            enrollmentID: draft.enrollmentID,
            rawBody: draft.package.rawRequestBody,
            accountID: draft.accountID,
            deviceID: draft.deviceID,
            secrets: draft.package.secrets
        )
    }

    /// Resend a staged enrollment whose response was never seen.
    ///
    /// The bytes come from the journal, not from a rebuilt request: the server
    /// decides replay by the exact bytes it fingerprinted, so anything else
    /// would be a new enrollment for an account that already exists.
    @discardableResult
    public func retryPendingEnrollment(secrets: SyncSecretBundle) async throws -> SyncConnectionConfiguration {
        guard let pending = try journal.pending() else {
            throw SyncOnboardingError.noPendingEnrollment
        }
        let identity = try Self.identity(inRawBody: pending.rawBody)
        return try await send(
            enrollmentID: pending.enrollmentID,
            rawBody: pending.rawBody,
            accountID: identity.accountID,
            deviceID: identity.deviceID,
            secrets: secrets
        )
    }

    private func send(
        enrollmentID: String,
        rawBody: Data,
        accountID: String,
        deviceID: String,
        secrets: SyncSecretBundle
    ) async throws -> SyncConnectionConfiguration {
        var request = URLRequest(url: URL(string: "/v1/enrollment/initialize", relativeTo: baseURL)!)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No Authorization header: enrollment is what creates the device this
        // token would prove, so there is nothing to authenticate against yet.
        request.httpBody = rawBody

        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            // The journal entry stays. A refusal the client can retry and a
            // refusal it cannot are the server's to distinguish, and dropping
            // the bytes here would lose the only idempotent retry available.
            throw SyncOnboardingError.enrollmentRejected(response.statusCode)
        }

        // Only now. Secrets stored for an enrollment the server never accepted
        // would leave the device believing it is linked to nothing.
        try vault.save(secrets)
        let configuration = try SyncConnectionConfiguration(
            baseURL: baseURL,
            accountID: accountID,
            deviceID: deviceID,
            // Connected, not synchronising. Turning sync on is a separate
            // decision the user makes later, and it is the one that reaches
            // real conversations.
            enabled: false,
            changesCursor: nil
        )
        try connectionStore.save(configuration)
        try journal.acknowledge(enrollmentID: enrollmentID)
        return configuration
    }

    /// Read the account and device out of a staged body.
    ///
    /// A retry has no draft to read them from, and they must be the ones the
    /// server will have recorded rather than whatever the caller believes.
    private static func identity(inRawBody body: Data) throws -> (accountID: String, deviceID: String) {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let accountID = root["account_id"] as? String,
              let device = root["device"] as? [String: Any],
              let deviceID = device["device_id"] as? String else {
            throw SyncOnboardingError.malformedResponse
        }
        return (accountID, deviceID)
    }
}
