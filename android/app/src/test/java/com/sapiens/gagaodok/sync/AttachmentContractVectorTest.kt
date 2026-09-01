package com.sapiens.gagaodok.sync

import java.io.File
import java.security.MessageDigest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Swift가 만든 계약 벡터를 Kotlin이 그대로 재현하는지 본다.
 *
 * 하나라도 어긋나면 벡터를 고쳐 맞추지 않는다. 벡터가 정답이고, 어긋난 쪽은
 * label 문자열·field 순서·UUID 인코딩 중 하나다.
 */
class AttachmentContractVectorTest {
    private fun unhex(value: String) = ByteArray(value.length / 2) {
        value.substring(it * 2, it * 2 + 2).toInt(16).toByte()
    }

    private fun loadRoot(): Map<String, JsonElement> {
        val workingDirectory = System.getProperty("user.dir") ?: error("working directory missing")
        val fixture = generateSequence(File(workingDirectory)) { it.parentFile }
            .map { File(it, "tools/fixtures/e2ee_contract_vectors.json") }
            .firstOrNull(File::isFile)
            ?: error("repository E2EE fixture not found")
        return Json.parseToJsonElement(fixture.readText()).jsonObject
    }

    private val root = loadRoot()
    private val vector = root.getValue("attachment").jsonObject
    private fun str(key: String) = vector.getValue(key).jsonPrimitive.content
    private fun int(key: String) = str(key).toInt()
    private fun masterKey() =
        unhex(root.getValue("recovery").jsonObject.getValue("account_master_key_hex").jsonPrimitive.content)

    @Test
    fun derivesTheAccountScopedAttachmentKeys() {
        val keys = SyncE2EE.deriveAttachmentKeys(masterKey())
        assertArrayEquals(unhex(str("attachment_root_key_hex")), keys.attachmentRootKey)
        assertArrayEquals(unhex(str("attachment_wrap_key_hex")), keys.attachmentWrapKey)
        assertArrayEquals(unhex(str("attachment_field_aead_key_hex")), keys.attachmentFieldAeadKey)
    }

    @Test
    fun reproducesTheContentEnvelopeAndItsThirtyFourByteOverhead() {
        val aad = SyncE2EE.attachmentContentAad(
            str("account_id"),
            str("attachment_id"),
            SyncE2EE.AttachmentKind.ATTACHMENT,
            int("source_byte_size").toLong(),
        )
        assertArrayEquals(unhex(str("content_aad_hex")), aad)
        val envelope = unhex(str("content_envelope_hex"))
        assertEquals(int("source_byte_size") + 34, envelope.size)
        assertArrayEquals(
            unhex(str("content_plaintext_hex")),
            SyncE2EE.openAttachment(envelope, unhex(str("file_key_hex")), aad),
        )
    }

    @Test
    fun unwrapsTheFileKeyAndRejectsASwappedObject() {
        val keys = SyncE2EE.deriveAttachmentKeys(masterKey())
        val envelope = unhex(str("content_envelope_hex"))
        val hash = MessageDigest.getInstance("SHA-256").digest(envelope)
        assertArrayEquals(unhex(str("ciphertext_hash_hex")), hash)

        val aad = SyncE2EE.attachmentWrapAad(
            str("account_id"), str("attachment_id"), SyncE2EE.AttachmentKind.ATTACHMENT, hash,
        )
        assertArrayEquals(unhex(str("wrap_aad_hex")), aad)
        assertArrayEquals(
            unhex(str("file_key_hex")),
            SyncE2EE.openAttachment(unhex(str("wrapped_file_key_envelope_hex")), keys.attachmentWrapKey, aad),
        )

        val tampered = hash.copyOf()
        tampered[0] = (tampered[0].toInt() xor 1).toByte()
        val tamperedAad = SyncE2EE.attachmentWrapAad(
            str("account_id"), str("attachment_id"), SyncE2EE.AttachmentKind.ATTACHMENT, tampered,
        )
        var rejected = false
        try {
            SyncE2EE.openAttachment(
                unhex(str("wrapped_file_key_envelope_hex")), keys.attachmentWrapKey, tamperedAad,
            )
        } catch (error: Exception) {
            rejected = true
        }
        assertTrue("a swapped object still unwrapped the file key", rejected)
    }

    @Test
    fun separatesFileNameAndMimeTypeAad() {
        val name = SyncE2EE.attachmentFieldAad(
            str("account_id"), str("attachment_id"),
            SyncE2EE.AttachmentKind.ATTACHMENT, SyncE2EE.AttachmentField.FILE_NAME,
        )
        val mime = SyncE2EE.attachmentFieldAad(
            str("account_id"), str("attachment_id"),
            SyncE2EE.AttachmentKind.ATTACHMENT, SyncE2EE.AttachmentField.MIME_TYPE,
        )
        assertArrayEquals(unhex(str("file_name_aad_hex")), name)
        assertFalse(name.contentEquals(mime))
    }
}
