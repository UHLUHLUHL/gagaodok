import Foundation
import CryptoKit

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
private func unhex(_ string: String) -> Data {
    var out = Data(); var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        out.append(UInt8(string[index..<next], radix: 16)!); index = next
    }
    return out
}

@main struct Generate {
    static func main() throws {
        let masterKey = unhex(CommandLine.arguments[1])
        let accountID = "11111111-1111-4111-8111-111111111111"
        let attachmentID = "70000000-0000-4000-8000-000000000001"
        let kind = SyncAttachmentKind.attachment
        let plaintext = Data((0..<96).map { UInt8($0) })
        let fileKey = Data(repeating: 0x40, count: 32)
        let contentNonce = unhex("000102030405060708090a0b")
        let wrapNonce = unhex("0c0d0e0f1011121314151617")

        let keys = try SyncE2EE.deriveAttachmentKeys(accountMasterKey: masterKey)
        let contentAAD = try SyncE2EE.attachmentContentAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind,
            sourceByteSize: UInt64(plaintext.count))
        let content = try SyncE2EE.sealAttachment(
            plaintext: plaintext, key: fileKey, nonce: contentNonce, aad: contentAAD)
        let ciphertextHash = Data(SHA256.hash(data: content))
        let wrapAAD = try SyncE2EE.attachmentWrapAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind,
            ciphertextHash: ciphertextHash)
        let wrapped = try SyncE2EE.sealAttachment(
            plaintext: fileKey, key: keys.attachmentWrapKey, nonce: wrapNonce, aad: wrapAAD)
        let nameAAD = try SyncE2EE.attachmentFieldAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, field: .fileName)

        let vector: [String: Any] = [
            "account_id": accountID,
            "attachment_id": attachmentID,
            "kind": kind.rawValue,
            "source_byte_size": plaintext.count,
            "ciphertext_byte_size": content.count,
            "attachment_root_key_hex": hex(keys.attachmentRootKey),
            "attachment_field_aead_key_hex": hex(keys.attachmentFieldAEADKey),
            "attachment_wrap_key_hex": hex(keys.attachmentWrapKey),
            "content_aad_hex": hex(contentAAD),
            "content_nonce_hex": hex(contentNonce),
            "content_plaintext_hex": hex(plaintext),
            "content_envelope_hex": hex(content),
            "ciphertext_hash_hex": hex(ciphertextHash),
            "file_key_hex": hex(fileKey),
            "wrap_aad_hex": hex(wrapAAD),
            "wrap_nonce_hex": hex(wrapNonce),
            "wrapped_file_key_envelope_hex": hex(wrapped),
            "file_name_aad_hex": hex(nameAAD),
        ]
        let json = try JSONSerialization.data(withJSONObject: vector, options: [.sortedKeys])
        print(String(data: json, encoding: .utf8)!)
    }
}
