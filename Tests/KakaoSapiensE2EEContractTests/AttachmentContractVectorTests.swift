import Foundation
import CryptoKit

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}
private func unhex(_ string: String) -> Data {
    var out = Data(); var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        out.append(UInt8(string[index..<next], radix: 16)!); index = next
    }
    return out
}

@main private struct Runner {
    static func main() throws {
        let url = URL(fileURLWithPath: "tools/fixtures/e2ee_contract_vectors.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let vector = root["attachment"] as! [String: Any]
        let master = unhex((root["recovery"] as! [String: Any])["account_master_key_hex"] as! String)
        let accountID = vector["account_id"] as! String
        let attachmentID = vector["attachment_id"] as! String
        let kind = SyncAttachmentKind(rawValue: vector["kind"] as! String)!

        let keys = try SyncE2EE.deriveAttachmentKeys(accountMasterKey: master)
        try check(keys.attachmentRootKey == unhex(vector["attachment_root_key_hex"] as! String),
                  "attachment root key drifted")
        try check(keys.attachmentWrapKey == unhex(vector["attachment_wrap_key_hex"] as! String),
                  "attachment wrap key drifted")
        try check(keys.attachmentFieldAEADKey == unhex(vector["attachment_field_aead_key_hex"] as! String),
                  "attachment field key drifted")

        let contentAAD = try SyncE2EE.attachmentContentAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind,
            sourceByteSize: UInt64(vector["source_byte_size"] as! Int))
        try check(contentAAD == unhex(vector["content_aad_hex"] as! String), "content AAD drifted")

        let envelope = unhex(vector["content_envelope_hex"] as! String)
        let opened = try SyncE2EE.openAttachment(
            envelope: envelope, key: unhex(vector["file_key_hex"] as! String), aad: contentAAD)
        try check(opened == unhex(vector["content_plaintext_hex"] as! String), "content did not round-trip")
        try check(envelope.count == (vector["source_byte_size"] as! Int) + 34, "envelope overhead is not 34")

        let hash = Data(SHA256.hash(data: envelope))
        try check(hash == unhex(vector["ciphertext_hash_hex"] as! String), "ciphertext hash drifted")

        let wrapAAD = try SyncE2EE.attachmentWrapAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, ciphertextHash: hash)
        try check(wrapAAD == unhex(vector["wrap_aad_hex"] as! String), "wrap AAD drifted")
        let fileKey = try SyncE2EE.openAttachment(
            envelope: unhex(vector["wrapped_file_key_envelope_hex"] as! String),
            key: keys.attachmentWrapKey, aad: wrapAAD)
        try check(fileKey == unhex(vector["file_key_hex"] as! String), "file key did not unwrap")

        // 다른 object로 바꿔치기하면 열쇠가 안 맞아야 한다.
        var tampered = hash; tampered[0] ^= 0x01
        let tamperedAAD = try SyncE2EE.attachmentWrapAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, ciphertextHash: tampered)
        var swapRejected = false
        do {
            _ = try SyncE2EE.openAttachment(
                envelope: unhex(vector["wrapped_file_key_envelope_hex"] as! String),
                key: keys.attachmentWrapKey, aad: tamperedAAD)
        } catch { swapRejected = true }
        try check(swapRejected, "a swapped object still unwrapped the file key")

        let nameAAD = try SyncE2EE.attachmentFieldAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, field: .fileName)
        try check(nameAAD == unhex(vector["file_name_aad_hex"] as! String), "file_name AAD drifted")
        let mimeAAD = try SyncE2EE.attachmentFieldAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, field: .mimeType)
        try check(nameAAD != mimeAAD, "file_name and mime_type share an AAD")

        print("12 attachment contract vector checks passed")
    }
}
