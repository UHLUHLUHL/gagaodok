import Foundation

@main
enum E2EEContractVectorTests {
    private struct Vector {
        let accountID: String
        let spaceID: String
        let roomID: String
        let entityType: String
        let entityID: String
        let fieldPath: String
        let fieldKey: Data
        let nonce: Data
        let plaintext: Data
        let aad: Data
        let envelope: Data
        let envelopeBase64: String
        let scopeRootKey: Data
    }

    static func main() throws {
        try producesAndOpensCanonicalFieldEnvelope()
        try rejectsAADOrEnvelopeIdentityDrift()
        try rejectsUnsupportedHeaderBeforeAuthentication()
        try rejectsNonCanonicalBase64()
        print("Swift E2EE contract vectors: 4 passed")
    }

    private static func producesAndOpensCanonicalFieldEnvelope() throws {
        let vector = try loadVector()
        let scope = SyncE2EE.Scope(
            accountID: vector.accountID,
            spaceID: vector.spaceID,
            roomID: vector.roomID,
            worldlineID: nil
        )
        let context = SyncE2EE.AADContext(
            scope: scope,
            entityType: vector.entityType,
            entityID: vector.entityID,
            fieldPath: vector.fieldPath,
            bubbleOrder: nil,
            recoveryVersion: nil
        )

        let keys = try SyncE2EE.deriveScopeKeys(
            accountMasterKey: Data((0..<32).map(UInt8.init)),
            scope: scope
        )
        try require(keys.scopeRootKey == vector.scopeRootKey, "scope root key mismatch")
        try require(keys.fieldAEADKey == vector.fieldKey, "field key mismatch")
        try require(SyncE2EE.encodeAAD(context) == vector.aad, "AAD mismatch")

        let envelope = try SyncE2EE.seal(
            plaintext: vector.plaintext,
            key: vector.fieldKey,
            nonce: vector.nonce,
            context: context
        )
        try require(envelope == vector.envelope, "envelope mismatch")
        try require(SyncE2EE.encodeBase64(envelope) == vector.envelopeBase64, "Base64 mismatch")
        try require(SyncE2EE.decodeBase64(vector.envelopeBase64) == vector.envelope, "Base64 decode mismatch")
        try require(
            SyncE2EE.open(envelope: vector.envelope, key: vector.fieldKey, context: context)
                == vector.plaintext,
            "plaintext mismatch"
        )
    }

    private static func rejectsAADOrEnvelopeIdentityDrift() throws {
        let vector = try loadVector()
        let scope = SyncE2EE.Scope(
            accountID: vector.accountID,
            spaceID: vector.spaceID,
            roomID: vector.roomID,
            worldlineID: nil
        )
        let mutations = [
            SyncE2EE.AADContext(scope: scope, entityType: "turn", entityID: vector.entityID, fieldPath: vector.fieldPath, bubbleOrder: nil, recoveryVersion: nil),
            SyncE2EE.AADContext(scope: scope, entityType: vector.entityType, entityID: vector.roomID + "X", fieldPath: vector.fieldPath, bubbleOrder: nil, recoveryVersion: nil),
            SyncE2EE.AADContext(scope: scope, entityType: vector.entityType, entityID: vector.entityID, fieldPath: "status_message", bubbleOrder: nil, recoveryVersion: nil),
            SyncE2EE.AADContext(scope: scope, entityType: vector.entityType, entityID: vector.entityID, fieldPath: vector.fieldPath, bubbleOrder: 0, recoveryVersion: nil),
        ]

        for mutation in mutations {
            try expectError(.authenticationFailed) {
                _ = try SyncE2EE.open(envelope: vector.envelope, key: vector.fieldKey, context: mutation)
            }
        }
    }

    private static func rejectsUnsupportedHeaderBeforeAuthentication() throws {
        let vector = try loadVector()
        let context = SyncE2EE.AADContext(
            scope: .init(accountID: vector.accountID, spaceID: vector.spaceID, roomID: vector.roomID, worldlineID: nil),
            entityType: vector.entityType,
            entityID: vector.entityID,
            fieldPath: vector.fieldPath,
            bubbleOrder: nil,
            recoveryVersion: nil
        )

        var wrongAlgorithm = vector.envelope
        wrongAlgorithm[1] = 2
        try expectError(.unsupportedAlgorithm) {
            _ = try SyncE2EE.open(envelope: wrongAlgorithm, key: vector.fieldKey, context: context)
        }

        var wrongGeneration = vector.envelope
        wrongGeneration[5] = 2
        try expectError(.unsupportedKeyGeneration) {
            _ = try SyncE2EE.open(envelope: wrongGeneration, key: vector.fieldKey, context: context)
        }
    }

    private static func rejectsNonCanonicalBase64() throws {
        for spelling in ["AQ", "__8=", " AQ==", "AQ==\n"] {
            try expectError(.nonCanonicalBase64) {
                _ = try SyncE2EE.decodeBase64(spelling)
            }
        }
    }

    private static func loadVector() throws -> Vector {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("tools")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("e2ee_contract_vectors.json")
        guard
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
            let field = root["field_aead"] as? [String: Any],
            let derivation = root["key_derivation"] as? [String: Any]
        else {
            throw TestError.invalidVector("root")
        }
        return Vector(
            accountID: try string("account_id", in: field),
            spaceID: try string("space_id", in: field),
            roomID: try string("room_id", in: field),
            entityType: try string("entity_type", in: field),
            entityID: try string("entity_id", in: field),
            fieldPath: try string("field_path", in: field),
            fieldKey: try Data(hex: string("field_aead_key_hex", in: field)),
            nonce: try Data(hex: string("nonce_hex", in: field)),
            plaintext: try Data(hex: string("plaintext_hex", in: field)),
            aad: try Data(hex: string("aad_hex", in: field)),
            envelope: try Data(hex: string("envelope_hex", in: field)),
            envelopeBase64: try string("envelope_base64", in: field),
            scopeRootKey: try Data(hex: string("scope_root_key", in: derivation))
        )
    }

    private static func string(_ key: String, in object: [String: Any]) throws -> String {
        guard let value = object[key] as? String else {
            throw TestError.invalidVector(key)
        }
        return value
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestError.failed(message) }
    }

    private static func expectError(
        _ expected: SyncE2EE.ContractError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw TestError.failed("expected \(expected)")
        } catch let error as SyncE2EE.ContractError {
            try require(error == expected, "expected \(expected), got \(error)")
        }
    }
}

private extension Data {
    init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else { throw TestError.invalidHex }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { throw TestError.invalidHex }
            bytes.append(byte)
            index = end
        }
        self.init(bytes)
    }
}

private enum TestError: Error {
    case invalidHex
    case invalidVector(String)
    case failed(String)
}
