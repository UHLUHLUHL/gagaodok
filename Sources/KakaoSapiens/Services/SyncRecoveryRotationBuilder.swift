import CryptoKit
import Foundation

/// A rotation package: the new phrase for the user, the request for the Worker,
/// and the entropy to escrow once the server has accepted it.
struct SyncRecoveryRotationPackage {
    let recoveryVersion: UInt32
    let recoveryPhrase: String
    let recoveryEntropy: Data
    let rawRequestBody: Data
}

/// Issuing a new recovery phrase without touching the account master key.
///
/// The three enrolled devices stay linked because nothing they hold changes:
/// the same master key is simply re-wrapped under a key derived from new
/// entropy. Only the phrase — what the user writes down — is replaced, which
/// is the whole point when the original was never recorded.
///
/// The master key and the entropy are never sent. What travels is the lookup,
/// the auth verifier and the sealed wrap, all of which are useless without the
/// phrase itself.
enum SyncRecoveryRotationBuilder {
    static func build(
        accountID: String,
        accountMasterKey: Data,
        recoveryEntropy: Data,
        recoveryNonce: Data,
        nextVersion: UInt32,
        words: [String]
    ) throws -> SyncRecoveryRotationPackage {
        // Version 1 belongs to enrollment. A rotation always supersedes
        // something, so the first one it can produce is 2.
        guard nextVersion >= 2 else { throw SyncE2EE.ContractError.invalidIdentity }
        let recovery = try SyncE2EE.deriveRecoveryMaterial(recoveryEntropy: recoveryEntropy)
        let verifier = try SyncE2EE.recoveryAuthVerifier(recovery.recoveryAuth)
        // The version is inside the AAD, so a wrap made for one version cannot
        // be replayed into another even by a server that holds both rows.
        let context = SyncE2EE.RecoveryAADContext(
            accountID: accountID,
            recoveryLookup: recovery.recoveryLookup,
            recoveryVersion: nextVersion
        )
        let wrapped = try SyncE2EE.sealRecoveryWrappedMasterKey(
            accountMasterKey: accountMasterKey,
            recoveryWrapKey: recovery.recoveryWrapKey,
            nonce: recoveryNonce,
            context: context
        )
        let json: [String: Any] = [
            "protocol_version": 1,
            "recovery_version": Int(nextVersion),
            "recovery_lookup": recovery.recoveryLookup.base64EncodedString(),
            "recovery_auth_verifier": verifier.base64EncodedString(),
            "wrapped_master_key": wrapped.base64EncodedString(),
        ]
        return SyncRecoveryRotationPackage(
            recoveryVersion: nextVersion,
            recoveryPhrase: try SyncRecoveryMnemonic.encode(entropy: recoveryEntropy, words: words),
            recoveryEntropy: recoveryEntropy,
            rawRequestBody: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        )
    }
}
