import CryptoKit
import Foundation

/// Where a rotation currently stands.
///
/// `confirmed` is the only state that means the user can actually recover the
/// account. `awaitingConfirmation` deliberately is not: the server has accepted
/// the new record by then, but nobody has proved the words left the screen.
public enum SyncRecoveryRotationStage: Equatable {
    case idle
    case awaitingConfirmation(phrase: String, version: UInt32)
    case confirmed(version: UInt32)
    case failed(SyncRecoveryRotationError)
}

public enum SyncRecoveryRotationError: Error, Equatable {
    case secretsUnavailable
    case wordListUnavailable
    case rejected(Int)
    case transport
    case malformedResponse
    case phraseMismatch
    case nothingToConfirm
}

/// Issuing and confirming a replacement recovery phrase.
///
/// The order matters and is not negotiable: the server accepts the new record
/// first, the phrase is shown second, and the user re-enters it third. Showing
/// the words before the server has them would hand the user a phrase that
/// recovers nothing; accepting the confirmation without re-deriving would make
/// the whole screen a formality.
///
/// The confirmation is a real check, not a string comparison against what was
/// displayed. The typed words are decoded back to entropy, the wrap key is
/// re-derived from it and the sealed master key is opened — the same path a
/// recovery on a blank device takes. If that unwrap does not reproduce the
/// master key this device already holds, the phrase is refused.
@MainActor
public final class SyncRecoveryRotationCoordinator {
    public private(set) var stage: SyncRecoveryRotationStage = .idle

    private let accountID: String
    private let client: SyncWorkerClient
    private let words: [String]
    private let loadSecrets: () -> SyncSecretLoadResult
    private let randomBytes: (Int) -> Data

    /// Held only between issue and confirmation, and only in memory.
    private var pending: PendingRotation?

    private struct PendingRotation {
        let version: UInt32
        let phrase: String
        let entropy: Data
        let wrappedMasterKey: Data
        let recoveryLookup: Data
    }

    public init(
        accountID: String,
        client: SyncWorkerClient,
        words: [String],
        loadSecrets: @escaping () -> SyncSecretLoadResult = { SyncSecretStore.load() },
        randomBytes: @escaping (Int) -> Data = { count in
            var bytes = Data(count: count)
            _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
            return bytes
        }
    ) {
        self.accountID = accountID
        self.client = client
        self.words = words
        self.loadSecrets = loadSecrets
        self.randomBytes = randomBytes
    }

    /// Ask the Worker for a new recovery version, then show the phrase.
    ///
    /// `nextVersion` comes from the caller rather than being guessed here: the
    /// Worker is the authority on which version is current, and a mismatch
    /// comes back as a conflict rather than silently overwriting.
    public func issue(nextVersion: UInt32) async {
        guard case .available(let secrets) = loadSecrets() else {
            stage = .failed(.secretsUnavailable)
            return
        }
        guard words.count == 2_048 else {
            stage = .failed(.wordListUnavailable)
            return
        }
        let entropy = randomBytes(SyncRecoveryEscrowPolicy.entropyLength)
        let nonce = randomBytes(12)
        let package: SyncRecoveryRotationPackage
        do {
            package = try SyncRecoveryRotationBuilder.build(
                accountID: accountID,
                accountMasterKey: secrets.accountMasterKey,
                recoveryEntropy: entropy,
                recoveryNonce: nonce,
                nextVersion: nextVersion,
                words: words
            )
        } catch {
            stage = .failed(.malformedResponse)
            return
        }
        do {
            _ = try await client.rotateRecovery(body: package.rawRequestBody)
        } catch SyncWorkerClientError.httpStatus(let status) {
            stage = .failed(.rejected(status))
            return
        } catch {
            stage = .failed(.transport)
            return
        }
        guard
            let body = try? JSONSerialization.jsonObject(with: package.rawRequestBody) as? [String: Any],
            let lookup = (body["recovery_lookup"] as? String).flatMap({ Data(base64Encoded: $0) }),
            let wrapped = (body["wrapped_master_key"] as? String).flatMap({ Data(base64Encoded: $0) })
        else {
            stage = .failed(.malformedResponse)
            return
        }
        pending = PendingRotation(
            version: nextVersion,
            phrase: package.recoveryPhrase,
            entropy: entropy,
            wrappedMasterKey: wrapped,
            recoveryLookup: lookup
        )
        stage = .awaitingConfirmation(phrase: package.recoveryPhrase, version: nextVersion)
    }

    /// Accept the phrase only if it really recovers the master key.
    ///
    /// Case and spacing are normalised because the user is copying by hand from
    /// a screen; the words themselves are not forgiven.
    @discardableResult
    public func confirm(typedPhrase: String) -> Bool {
        guard let pending else {
            stage = .failed(.nothingToConfirm)
            return false
        }
        guard case .available(let secrets) = loadSecrets() else {
            stage = .failed(.secretsUnavailable)
            return false
        }
        let normalized = typedPhrase.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard
            let entropy = try? SyncRecoveryMnemonic.decode(normalized, words: words),
            let material = try? SyncE2EE.deriveRecoveryMaterial(recoveryEntropy: entropy),
            material.recoveryLookup == pending.recoveryLookup,
            let opened = try? SyncE2EE.openRecoveryWrappedMasterKey(
                envelope: pending.wrappedMasterKey,
                recoveryWrapKey: material.recoveryWrapKey,
                context: SyncE2EE.RecoveryAADContext(
                    accountID: accountID,
                    recoveryLookup: material.recoveryLookup,
                    recoveryVersion: pending.version
                )
            ),
            constantTimeEqual(opened, secrets.accountMasterKey)
        else {
            // The rotation itself stands — the phrase on screen is the account's
            // recovery phrase whether or not it was typed back correctly. Only
            // the confirmation failed, so the user is asked again.
            stage = .failed(.phraseMismatch)
            return false
        }
        self.pending = nil
        stage = .confirmed(version: pending.version)
        return true
    }

    /// Let the user try typing again without re-issuing a phrase.
    public func retryConfirmation() {
        guard let pending else { return }
        stage = .awaitingConfirmation(phrase: pending.phrase, version: pending.version)
    }

    private func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}
