package com.sapiens.gagaodok.sync

import java.io.File
import java.security.MessageDigest
import java.util.UUID

data class SyncAttachmentPlan(
    val attachmentId: String,
    val kind: SyncE2EE.AttachmentKind,
    val sourceByteSize: Long,
    val ciphertextByteSize: Long,
    val ciphertextHashHex: String,
    val ciphertext: ByteArray,
    val wrappedFileKeyBase64: String,
    val fileNameBase64: String,
    val mimeTypeBase64: String,
)

class SyncAttachmentException(val reason: String) : Exception(reason)

/**
 * 첨부의 올리기·받기 순서와 검증만 갖는다.
 *
 * 로컬 대화 저장소를 읽거나 쓰지 않으며, 카메라·PDF 원본 파일을 덮어쓰지 않는다.
 * 복호화 결과는 sync/remote/attachments 아래에만 쓴다.
 */
class SyncAttachmentTransferCoordinator(
    private val accountId: String,
    private val masterKey: ByteArray,
    private val client: SyncWorkerClient,
    private val rootDirectory: File,
) {
    companion object {
        const val MAX_SOURCE_BYTES = 12_582_912L
        const val ENVELOPE_OVERHEAD_BYTES = 34L

        fun destinationFile(rootDirectory: File, attachmentId: String): File {
            if (attachmentId != runCatching { UUID.fromString(attachmentId).toString().uppercase() }.getOrNull()) {
                throw SyncAttachmentException("identity_not_canonical")
            }
            return File(File(rootDirectory, "sync/remote/attachments"), attachmentId)
        }

        private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    }

    fun prepare(
        bytes: ByteArray,
        attachmentId: String,
        kind: SyncE2EE.AttachmentKind,
        fileName: String,
        mimeType: String,
        randomBytes: (Int) -> ByteArray,
    ): SyncAttachmentPlan {
        if (attachmentId != runCatching { UUID.fromString(attachmentId).toString().uppercase() }.getOrNull()) {
            throw SyncAttachmentException("identity_not_canonical")
        }
        val size = bytes.size.toLong()
        // 상한을 넘으면 조용히 누락하지 않고 명시적으로 거부한다. 호출부가 알린다.
        if (size < 1 || size > MAX_SOURCE_BYTES) throw SyncAttachmentException("too_large")

        val keys = SyncE2EE.deriveAttachmentKeys(masterKey)
        val fileKey = randomBytes(32)
        val contentAad = SyncE2EE.attachmentContentAad(accountId, attachmentId, kind, size)
        val ciphertext = SyncE2EE.sealAttachment(bytes, fileKey, randomBytes(12), contentAad)
        val hash = MessageDigest.getInstance("SHA-256").digest(ciphertext)
        val wrapAad = SyncE2EE.attachmentWrapAad(accountId, attachmentId, kind, hash)
        val wrapped = SyncE2EE.sealAttachment(fileKey, keys.attachmentWrapKey, randomBytes(12), wrapAad)
        val name = SyncE2EE.sealAttachment(
            fileName.toByteArray(Charsets.UTF_8), keys.attachmentFieldAeadKey, randomBytes(12),
            SyncE2EE.attachmentFieldAad(accountId, attachmentId, kind, SyncE2EE.AttachmentField.FILE_NAME),
        )
        val mime = SyncE2EE.sealAttachment(
            mimeType.toByteArray(Charsets.UTF_8), keys.attachmentFieldAeadKey, randomBytes(12),
            SyncE2EE.attachmentFieldAad(accountId, attachmentId, kind, SyncE2EE.AttachmentField.MIME_TYPE),
        )
        return SyncAttachmentPlan(
            attachmentId = attachmentId,
            kind = kind,
            sourceByteSize = size,
            ciphertextByteSize = ciphertext.size.toLong(),
            ciphertextHashHex = hex(hash),
            ciphertext = ciphertext,
            wrappedFileKeyBase64 = SyncE2EE.encodeBase64(wrapped),
            fileNameBase64 = SyncE2EE.encodeBase64(name),
            mimeTypeBase64 = SyncE2EE.encodeBase64(mime),
        )
    }

    /**
     * PUT 다음 complete.
     *
     * 순서를 바꾸면 다른 기기에 다운로드 불가능한 중간 상태가 노출된다.
     */
    fun upload(plan: SyncAttachmentPlan) {
        client.putAttachmentContent(plan.attachmentId, plan.ciphertext)
        client.completeAttachment(plan.attachmentId)
    }

    fun download(
        attachmentId: String,
        kind: SyncE2EE.AttachmentKind,
        sourceByteSize: Long,
        ciphertextByteSize: Long,
        ciphertextHashHex: String,
        wrappedFileKeyBase64: String,
    ): File {
        val destination = destinationFile(rootDirectory, attachmentId)
        val envelope = client.getAttachmentContent(attachmentId).body
        if (envelope.size.toLong() != ciphertextByteSize ||
            ciphertextByteSize != sourceByteSize + ENVELOPE_OVERHEAD_BYTES
        ) {
            throw SyncAttachmentException("size_mismatch")
        }
        val hash = MessageDigest.getInstance("SHA-256").digest(envelope)
        if (hex(hash) != ciphertextHashHex.lowercase()) throw SyncAttachmentException("hash_mismatch")

        val keys = SyncE2EE.deriveAttachmentKeys(masterKey)
        val fileKey = try {
            SyncE2EE.openAttachment(
                SyncE2EE.decodeBase64(wrappedFileKeyBase64),
                keys.attachmentWrapKey,
                SyncE2EE.attachmentWrapAad(accountId, attachmentId, kind, hash),
            )
        } catch (error: Exception) {
            throw SyncAttachmentException("decryption_failed")
        }
        val plaintext = try {
            SyncE2EE.openAttachment(
                envelope, fileKey,
                SyncE2EE.attachmentContentAad(accountId, attachmentId, kind, sourceByteSize),
            )
        } catch (error: Exception) {
            throw SyncAttachmentException("decryption_failed")
        }
        if (plaintext.size.toLong() != sourceByteSize) throw SyncAttachmentException("decryption_failed")

        // 원자적 이동. 부분적으로 쓰인 파일이 완성본으로 보이지 않게 한다.
        destination.parentFile?.mkdirs()
        val staging = File(destination.parentFile, ".$attachmentId.partial")
        staging.writeBytes(plaintext)
        if (!staging.renameTo(destination)) {
            destination.delete()
            if (!staging.renameTo(destination)) throw SyncAttachmentException("rename_failed")
        }
        return destination
    }
}
