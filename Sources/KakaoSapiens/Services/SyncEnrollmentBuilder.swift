import CryptoKit
import Foundation

struct SyncEnrollmentPackage {
    let accountID: String
    let deviceID: String
    let enrollmentID: String
    let recoveryPhrase: String
    let secrets: SyncSecretBundle
    let rawRequestBody: Data
}

enum SyncEnrollmentBuilder {
    static func build(
        accountID: String,
        deviceID: String,
        enrollmentID: String,
        spaceID: String,
        platform: String,
        accountMasterKey: Data,
        deviceToken: Data,
        recoveryEntropy: Data,
        recoveryNonce: Data,
        words: [String]
    ) throws -> SyncEnrollmentPackage {
        let secrets = try SyncSecretBundle(accountMasterKey: accountMasterKey, deviceToken: deviceToken)
        let recovery = try SyncE2EE.deriveRecoveryMaterial(recoveryEntropy: recoveryEntropy)
        let verifier = try SyncE2EE.recoveryAuthVerifier(recovery.recoveryAuth)
        let context = SyncE2EE.RecoveryAADContext(
            accountID: accountID,
            recoveryLookup: recovery.recoveryLookup,
            recoveryVersion: 1
        )
        let wrapped = try SyncE2EE.sealRecoveryWrappedMasterKey(
            accountMasterKey: accountMasterKey,
            recoveryWrapKey: recovery.recoveryWrapKey,
            nonce: recoveryNonce,
            context: context
        )
        let tokenHash = Data(SHA256.hash(data: deviceToken)).map {
            String(format: "%02x", $0)
        }.joined()
        let json: [String: Any] = [
            "protocol_version": 1,
            "enrollment_id": enrollmentID,
            "account_id": accountID,
            "device": [
                "device_id": deviceID,
                "space_id": spaceID,
                "platform": platform,
                "display_name": NSNull(),
                "device_token_hash": tokenHash,
            ],
            "recovery": [
                "recovery_version": 1,
                "recovery_lookup": recovery.recoveryLookup.base64EncodedString(),
                "recovery_auth_verifier": verifier.base64EncodedString(),
                "wrapped_master_key": wrapped.base64EncodedString(),
            ],
        ]
        let raw = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return SyncEnrollmentPackage(
            accountID: accountID,
            deviceID: deviceID,
            enrollmentID: enrollmentID,
            recoveryPhrase: try SyncRecoveryMnemonic.encode(entropy: recoveryEntropy, words: words),
            secrets: secrets,
            rawRequestBody: raw
        )
    }
}
