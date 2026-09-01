import Foundation
import CryptoKit

/// 12MB 상한을 한 번의 AES-GCM 호출로 처리할 때의 최고 메모리를 재기 위한 도구다.
/// 암호 규격 §9.2가 "아직 측정하지 않았다"고 남긴 자리를 채운다.
@main struct Measure {
    static func main() throws {
        let size = 12_582_912
        let account = "11111111-1111-4111-8111-111111111111"
        let attachment = "70000000-0000-4000-8000-000000000001"
        let bytes = Data(count: size)
        let fileKey = Data(repeating: 0x40, count: 32)
        let aad = try SyncE2EE.attachmentContentAAD(
            accountID: account, attachmentID: attachment, kind: .attachment,
            sourceByteSize: UInt64(size))
        let sealed = try SyncE2EE.sealAttachment(
            plaintext: bytes, key: fileKey, nonce: Data(repeating: 0x01, count: 12), aad: aad)
        let opened = try SyncE2EE.openAttachment(envelope: sealed, key: fileKey, aad: aad)
        print("source=\(size) sealed=\(sealed.count) opened=\(opened.count)")
    }
}
