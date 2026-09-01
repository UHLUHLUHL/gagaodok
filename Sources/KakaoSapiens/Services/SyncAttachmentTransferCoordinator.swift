import CryptoKit
import Foundation

public struct SyncAttachmentPlan: Equatable {
    public let attachmentID: String
    public let kind: SyncAttachmentKind
    public let sourceByteSize: UInt64
    public let ciphertextByteSize: UInt64
    public let ciphertextHashHex: String
    public let ciphertext: Data
    public let wrappedFileKeyBase64: String
    public let fileNameBase64: String
    public let mimeTypeBase64: String
}

public enum SyncAttachmentError: Error, Equatable {
    case tooLarge(UInt64)
    case sizeMismatch
    case hashMismatch
    case notReady
    case decryptionFailed
    case identityNotCanonical
}

/// 첨부의 올리기·받기 순서와 검증만 갖는다.
///
/// 로컬 대화 저장소를 읽거나 쓰지 않으며, 카메라·PDF 원본 파일을 덮어쓰지
/// 않는다. 복호화 결과는 `sync/remote/attachments` 아래에만 쓴다.
public struct SyncAttachmentTransferCoordinator {
    public static let maxSourceBytes: UInt64 = 12_582_912
    public static let envelopeOverheadBytes: UInt64 = 34

    private let accountID: String
    private let masterKey: Data
    private let client: SyncWorkerClient
    private let rootDirectory: URL

    public init(accountID: String, masterKey: Data, client: SyncWorkerClient, rootDirectory: URL) {
        self.accountID = accountID
        self.masterKey = masterKey
        self.client = client
        self.rootDirectory = rootDirectory
    }

    public static func destinationPath(rootDirectory: URL, attachmentID: String) throws -> URL {
        guard let uuid = UUID(uuidString: attachmentID), uuid.uuidString == attachmentID else {
            throw SyncAttachmentError.identityNotCanonical
        }
        return rootDirectory
            .appendingPathComponent("sync/remote/attachments", isDirectory: true)
            .appendingPathComponent(attachmentID)
    }

    public func prepare(
        bytes: Data, attachmentID: String, kind: SyncAttachmentKind,
        fileName: String, mimeType: String, randomBytes: (Int) -> Data
    ) throws -> SyncAttachmentPlan {
        guard let uuid = UUID(uuidString: attachmentID), uuid.uuidString == attachmentID else {
            throw SyncAttachmentError.identityNotCanonical
        }
        let size = UInt64(bytes.count)
        // 상한을 넘으면 조용히 누락하지 않고 명시적으로 거부한다. 호출부가 알린다.
        guard size >= 1, size <= Self.maxSourceBytes else { throw SyncAttachmentError.tooLarge(size) }

        let keys = try SyncE2EE.deriveAttachmentKeys(accountMasterKey: masterKey)
        let fileKey = randomBytes(32)
        let contentAAD = try SyncE2EE.attachmentContentAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, sourceByteSize: size)
        let ciphertext = try SyncE2EE.sealAttachment(
            plaintext: bytes, key: fileKey, nonce: randomBytes(12), aad: contentAAD)
        let hash = Data(SHA256.hash(data: ciphertext))
        let wrapAAD = try SyncE2EE.attachmentWrapAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, ciphertextHash: hash)
        let wrapped = try SyncE2EE.sealAttachment(
            plaintext: fileKey, key: keys.attachmentWrapKey, nonce: randomBytes(12), aad: wrapAAD)
        let name = try SyncE2EE.sealAttachment(
            plaintext: Data(fileName.utf8), key: keys.attachmentFieldAEADKey, nonce: randomBytes(12),
            aad: try SyncE2EE.attachmentFieldAAD(
                accountID: accountID, attachmentID: attachmentID, kind: kind, field: .fileName))
        let mime = try SyncE2EE.sealAttachment(
            plaintext: Data(mimeType.utf8), key: keys.attachmentFieldAEADKey, nonce: randomBytes(12),
            aad: try SyncE2EE.attachmentFieldAAD(
                accountID: accountID, attachmentID: attachmentID, kind: kind, field: .mimeType))

        return SyncAttachmentPlan(
            attachmentID: attachmentID, kind: kind, sourceByteSize: size,
            ciphertextByteSize: UInt64(ciphertext.count),
            ciphertextHashHex: Self.hex(hash),
            ciphertext: ciphertext,
            wrappedFileKeyBase64: SyncE2EE.encodeBase64(wrapped),
            fileNameBase64: SyncE2EE.encodeBase64(name),
            mimeTypeBase64: SyncE2EE.encodeBase64(mime))
    }

    /// PUT 다음 complete.
    ///
    /// 순서를 바꾸면 다른 기기에 다운로드 불가능한 중간 상태가 노출된다. 정본
    /// 스키마도 bubble이 먼저 노출된 뒤의 중간 상태를 금지한다.
    public func upload(_ plan: SyncAttachmentPlan) async throws {
        let put = try await client.putAttachmentContent(
            attachmentID: plan.attachmentID, body: plan.ciphertext)
        guard (200..<300).contains(put.statusCode) else {
            throw SyncWorkerClientError.httpStatus(put.statusCode)
        }
        let complete = try await client.completeAttachment(attachmentID: plan.attachmentID)
        guard (200..<300).contains(complete.statusCode) else {
            throw SyncWorkerClientError.httpStatus(complete.statusCode)
        }
    }

    public func download(
        attachmentID: String, kind: SyncAttachmentKind,
        sourceByteSize: UInt64, ciphertextByteSize: UInt64,
        ciphertextHashHex: String, wrappedFileKeyBase64: String
    ) async throws -> URL {
        let destination = try Self.destinationPath(
            rootDirectory: rootDirectory, attachmentID: attachmentID)
        let response = try await client.getAttachmentContent(attachmentID: attachmentID)
        guard (200..<300).contains(response.statusCode) else {
            throw SyncWorkerClientError.httpStatus(response.statusCode)
        }
        let envelope = response.body
        guard UInt64(envelope.count) == ciphertextByteSize,
              ciphertextByteSize == sourceByteSize + Self.envelopeOverheadBytes
        else { throw SyncAttachmentError.sizeMismatch }
        let hash = Data(SHA256.hash(data: envelope))
        guard Self.hex(hash) == ciphertextHashHex.lowercased() else {
            throw SyncAttachmentError.hashMismatch
        }

        let keys = try SyncE2EE.deriveAttachmentKeys(accountMasterKey: masterKey)
        let wrapAAD = try SyncE2EE.attachmentWrapAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, ciphertextHash: hash)
        guard let wrappedEnvelope = try? SyncE2EE.decodeBase64(wrappedFileKeyBase64),
              let fileKey = try? SyncE2EE.openAttachment(
                envelope: wrappedEnvelope, key: keys.attachmentWrapKey, aad: wrapAAD)
        else { throw SyncAttachmentError.decryptionFailed }
        let contentAAD = try SyncE2EE.attachmentContentAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind,
            sourceByteSize: sourceByteSize)
        guard let plaintext = try? SyncE2EE.openAttachment(
                envelope: envelope, key: fileKey, aad: contentAAD),
              UInt64(plaintext.count) == sourceByteSize
        else { throw SyncAttachmentError.decryptionFailed }

        // 원자적 이동. 부분적으로 쓰인 파일이 완성본으로 보이지 않게 한다.
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".\(attachmentID).partial")
        try plaintext.write(to: staging, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        return destination
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
