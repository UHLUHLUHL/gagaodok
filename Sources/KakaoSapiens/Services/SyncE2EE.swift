import CryptoKit
import Foundation

enum SyncE2EE {
    static let protocolVersion: UInt16 = 1
    static let algorithm: UInt8 = 1
    static let keyGeneration: UInt32 = 1

    struct Scope: Equatable {
        let accountID: String
        let spaceID: String
        let roomID: String
        let worldlineID: String?
    }

    struct AADContext: Equatable {
        let scope: Scope
        let entityType: String
        let entityID: String
        let fieldPath: String?
        let bubbleOrder: UInt64?
        let recoveryVersion: UInt32?
    }

    struct ScopeKeys: Equatable {
        let scopeRootKey: Data
        let fieldAEADKey: Data
        let checkpointAEADKey: Data
        let attachmentWrapKey: Data
        let compatTagKey: Data
    }

    struct RecoveryMaterial: Equatable {
        let recoveryLookup: Data
        let recoveryAuth: Data
        let recoveryWrapKey: Data
    }

    struct PairingMaterial: Equatable {
        let pairingSessionLookup: Data
        let pairingClaimKey: Data
        let claimLookup: Data
        let claimRedeemAuth: Data
        let pairingDeliveryKey: Data
        let pairingSAS: String
    }

    enum PairingPayloadType: String {
        case claim
        case delivery
    }

    enum ContractError: Error, Equatable {
        case invalidAccountMasterKey
        case invalidKey
        case invalidNonce
        case invalidEnvelope
        case invalidIdentity
        case invalidScope
        case invalidText
        case unsupportedVersion
        case unsupportedAlgorithm
        case unsupportedKeyGeneration
        case authenticationFailed
        case nonCanonicalBase64
    }

    static func deriveScopeKeys(accountMasterKey: Data, scope: Scope) throws -> ScopeKeys {
        guard accountMasterKey.count == 32 else { throw ContractError.invalidAccountMasterKey }
        let context = try encodeScopeContext(scope)
        let protocolSalt = Data("gagaodok/e2ee/v1/hkdf-salt".utf8)
        let scopePRK = hmacSHA256(key: protocolSalt, message: accountMasterKey)
        let scopeRoot = try hkdfExpand(
            prk: scopePRK,
            info: hkdfInfo(purpose: "gagaodok/e2ee/v1/scope-root", context: context),
            length: 32
        )
        return ScopeKeys(
            scopeRootKey: scopeRoot,
            fieldAEADKey: try derivedKey(label: "gagaodok/e2ee/v1/field-aead", scopeRoot: scopeRoot),
            checkpointAEADKey: try derivedKey(label: "gagaodok/e2ee/v1/checkpoint-aead", scopeRoot: scopeRoot),
            attachmentWrapKey: try derivedKey(label: "gagaodok/e2ee/v1/attachment-wrap", scopeRoot: scopeRoot),
            compatTagKey: try derivedKey(label: "gagaodok/e2ee/v1/compat-tag", scopeRoot: scopeRoot)
        )
    }

    static func deriveRecoveryMaterial(recoveryEntropy: Data) throws -> RecoveryMaterial {
        guard recoveryEntropy.count == 16 else { throw ContractError.invalidKey }
        return RecoveryMaterial(
            recoveryLookup: try hkdfSHA256(
                ikm: recoveryEntropy,
                label: "gagaodok/e2ee/v1/recovery-lookup"
            ),
            recoveryAuth: try hkdfSHA256(
                ikm: recoveryEntropy,
                label: "gagaodok/e2ee/v1/recovery-auth"
            ),
            recoveryWrapKey: try hkdfSHA256(
                ikm: recoveryEntropy,
                label: "gagaodok/e2ee/v1/recovery-wrap"
            )
        )
    }

    static func recoveryAuthVerifier(_ recoveryAuth: Data) throws -> Data {
        guard recoveryAuth.count == 32 else { throw ContractError.invalidKey }
        return try labeledHash(
            label: "gagaodok/e2ee/v1/recovery-auth-verifier",
            payload: recoveryAuth
        )
    }

    static func derivePairingMaterial(pairingSecret: Data, claimSecret: Data) throws -> PairingMaterial {
        guard pairingSecret.count == 32, claimSecret.count == 32 else {
            throw ContractError.invalidKey
        }
        let jointSecret = try encodeLP([(1, pairingSecret), (2, claimSecret)])
        let sasBytes = try hkdfSHA256(
            ikm: jointSecret,
            label: "gagaodok/e2ee/v1/pairing-sas",
            length: 4
        )
        let sasNumber = sasBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return PairingMaterial(
            pairingSessionLookup: try hkdfSHA256(
                ikm: pairingSecret,
                label: "gagaodok/e2ee/v1/pairing-session-lookup"
            ),
            pairingClaimKey: try hkdfSHA256(
                ikm: pairingSecret,
                label: "gagaodok/e2ee/v1/pairing-claim"
            ),
            claimLookup: try hkdfSHA256(
                ikm: claimSecret,
                label: "gagaodok/e2ee/v1/claim-lookup"
            ),
            claimRedeemAuth: try hkdfSHA256(
                ikm: claimSecret,
                label: "gagaodok/e2ee/v1/claim-redeem-auth"
            ),
            pairingDeliveryKey: try hkdfSHA256(
                ikm: jointSecret,
                label: "gagaodok/e2ee/v1/pairing-delivery"
            ),
            pairingSAS: String(format: "%06u", sasNumber)
        )
    }

    static func encodePairingAAD(
        sessionID: String,
        claimID: String,
        claimLookup: Data,
        payloadType: PairingPayloadType
    ) throws -> Data {
        guard claimLookup.count == 32 else { throw ContractError.invalidIdentity }
        return try encodeLP([
            (1, Data(protocolVersion.bigEndianBytes)),
            (2, canonicalUUID(sessionID)),
            (3, canonicalUUID(claimID)),
            (4, claimLookup),
            (5, try ascii(payloadType.rawValue)),
            (6, Data([algorithm])),
        ])
    }

    static func claimRedeemVerifier(
        sessionID: String,
        claimID: String,
        claimLookup: Data,
        claimRedeemAuth: Data
    ) throws -> Data {
        guard claimLookup.count == 32, claimRedeemAuth.count == 32 else {
            throw ContractError.invalidIdentity
        }
        let payload = try encodeLP([
            (1, canonicalUUID(sessionID)),
            (2, canonicalUUID(claimID)),
            (3, claimLookup),
            (4, claimRedeemAuth),
        ])
        return try labeledHash(
            label: "gagaodok/e2ee/v1/claim-redeem-verifier",
            payload: payload
        )
    }

    static func encodeAAD(_ context: AADContext) throws -> Data {
        try encodeLP([
            (1, Data(protocolVersion.bigEndianBytes)),
            (2, Data(keyGeneration.bigEndianBytes)),
            (3, canonicalUUID(context.scope.accountID)),
            (4, try utf8(context.scope.spaceID)),
            (5, canonicalUUID(context.scope.roomID)),
            (6, try context.scope.worldlineID.map(canonicalUUID)),
            (7, try ascii(context.entityType)),
            (8, try utf8(context.entityID)),
            (9, try context.fieldPath.map(utf8)),
            (10, context.bubbleOrder.map { Data($0.bigEndianBytes) }),
            (11, context.recoveryVersion.map { Data($0.bigEndianBytes) }),
            (12, Data([algorithm])),
        ])
    }

    static func seal(
        plaintext: Data,
        key: Data,
        nonce: Data,
        context: AADContext
    ) throws -> Data {
        guard key.count == 32 else { throw ContractError.invalidKey }
        guard nonce.count == 12 else { throw ContractError.invalidNonce }
        let aad = try encodeAAD(context)
        do {
            let sealed = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: key),
                nonce: AES.GCM.Nonce(data: nonce),
                authenticating: aad
            )
            var envelope = Data([UInt8(protocolVersion), algorithm])
            envelope.append(contentsOf: keyGeneration.bigEndianBytes)
            envelope.append(nonce)
            envelope.append(sealed.ciphertext)
            envelope.append(sealed.tag)
            return envelope
        } catch let error as ContractError {
            throw error
        } catch {
            throw ContractError.authenticationFailed
        }
    }

    static func open(envelope: Data, key: Data, context: AADContext) throws -> Data {
        guard key.count == 32 else { throw ContractError.invalidKey }
        guard envelope.count >= 34 else { throw ContractError.invalidEnvelope }
        guard envelope[0] == UInt8(protocolVersion) else { throw ContractError.unsupportedVersion }
        guard envelope[1] == algorithm else { throw ContractError.unsupportedAlgorithm }
        let generation = envelope[2..<6].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard generation == keyGeneration else { throw ContractError.unsupportedKeyGeneration }

        let nonceData = Data(envelope[6..<18])
        let ciphertextEnd = envelope.count - 16
        let ciphertext = Data(envelope[18..<ciphertextEnd])
        let tag = Data(envelope[ciphertextEnd..<envelope.count])
        let aad = try encodeAAD(context)
        do {
            let sealed = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(sealed, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            throw ContractError.authenticationFailed
        }
    }

    static func encodeBase64(_ data: Data) -> String {
        data.base64EncodedString()
    }

    static func decodeBase64(_ value: String) throws -> Data {
        guard
            let decoded = Data(base64Encoded: value, options: []),
            decoded.base64EncodedString() == value
        else {
            throw ContractError.nonCanonicalBase64
        }
        return decoded
    }

    private static func encodeScopeContext(_ scope: Scope) throws -> Data {
        guard ["MAC_SPACE", "PHONE_SPACE", "TABLET_SPACE"].contains(scope.spaceID) else {
            throw ContractError.invalidScope
        }
        return try encodeLP([
            (1, canonicalUUID(scope.accountID)),
            (2, try utf8(scope.spaceID)),
            (3, canonicalUUID(scope.roomID)),
            (4, try scope.worldlineID.map(canonicalUUID)),
        ])
    }

    private static func derivedKey(label: String, scopeRoot: Data) throws -> Data {
        try hkdfExpand(prk: scopeRoot, info: hkdfInfo(purpose: label, context: nil), length: 32)
    }

    private static func hkdfSHA256(ikm: Data, label: String, length: Int = 32) throws -> Data {
        let protocolSalt = Data("gagaodok/e2ee/v1/hkdf-salt".utf8)
        return try hkdfExpand(
            prk: hmacSHA256(key: protocolSalt, message: ikm),
            info: hkdfInfo(purpose: label, context: nil),
            length: length
        )
    }

    private static func labeledHash(label: String, payload: Data) throws -> Data {
        let encoded = try encodeLP([
            (1, try utf8(label)),
            (2, payload),
        ])
        return Data(SHA256.hash(data: encoded))
    }

    private static func hkdfInfo(purpose: String, context: Data?) throws -> Data {
        try encodeLP([
            (1, Data(protocolVersion.bigEndianBytes)),
            (2, try utf8(purpose)),
            (3, context),
        ])
    }

    private static func hkdfExpand(prk: Data, info: Data, length: Int) throws -> Data {
        guard length >= 0, length <= 255 * 32 else { throw ContractError.invalidKey }
        var output = Data()
        var previous = Data()
        var counter: UInt8 = 1
        while output.count < length {
            var message = previous
            message.append(info)
            message.append(counter)
            previous = hmacSHA256(key: prk, message: message)
            output.append(previous)
            counter &+= 1
        }
        return output.prefix(length)
    }

    private static func hmacSHA256(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    private static func encodeLP(_ fields: [(UInt16, Data?)]) throws -> Data {
        guard fields.count <= Int(UInt16.max) else { throw ContractError.invalidText }
        var output = Data("GDK1".utf8)
        output.append(contentsOf: UInt16(fields.count).bigEndianBytes)
        var previousID: UInt16 = 0
        for (fieldID, value) in fields {
            guard fieldID > previousID else { throw ContractError.invalidText }
            previousID = fieldID
            output.append(contentsOf: fieldID.bigEndianBytes)
            guard let value else {
                output.append(0)
                output.append(contentsOf: UInt32(0).bigEndianBytes)
                continue
            }
            guard value.count <= Int(UInt32.max) else { throw ContractError.invalidText }
            output.append(1)
            output.append(contentsOf: UInt32(value.count).bigEndianBytes)
            output.append(value)
        }
        return output
    }

    private static func canonicalUUID(_ value: String) throws -> Data {
        guard let parsed = UUID(uuidString: value), parsed.uuidString == value else {
            throw ContractError.invalidIdentity
        }
        return Data(value.utf8)
    }

    private static func utf8(_ value: String) throws -> Data {
        guard let data = value.data(using: .utf8) else { throw ContractError.invalidText }
        return data
    }

    private static func ascii(_ value: String) throws -> Data {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy(\.isASCII) else {
            throw ContractError.invalidText
        }
        return Data(value.utf8)
    }
}

private extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }
}
