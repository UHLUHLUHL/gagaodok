package com.sapiens.gagaodok.sync

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.UUID
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

internal object SyncE2EE {
    private const val PROTOCOL_VERSION = 1
    private const val ALGORITHM = 1
    private const val KEY_GENERATION = 1L
    private val MAGIC = "GDK1".toByteArray(StandardCharsets.US_ASCII)
    private val VALID_SPACES = setOf("MAC_SPACE", "PHONE_SPACE", "TABLET_SPACE")

    data class Scope(
        val accountId: String,
        val spaceId: String,
        val roomId: String,
        val worldlineId: String?,
    )

    data class AADContext(
        val scope: Scope,
        val entityType: String,
        val entityId: String,
        val fieldPath: String?,
        val bubbleOrder: Long?,
        val recoveryVersion: Long?,
    )

    data class ScopeKeys(
        val scopeRootKey: ByteArray,
        val fieldAEADKey: ByteArray,
        val checkpointAEADKey: ByteArray,
        val attachmentWrapKey: ByteArray,
        val compatTagKey: ByteArray,
    )

    enum class ContractError {
        INVALID_ACCOUNT_MASTER_KEY,
        INVALID_KEY,
        INVALID_NONCE,
        INVALID_ENVELOPE,
        INVALID_IDENTITY,
        INVALID_SCOPE,
        INVALID_TEXT,
        UNSUPPORTED_VERSION,
        UNSUPPORTED_ALGORITHM,
        UNSUPPORTED_KEY_GENERATION,
        AUTHENTICATION_FAILED,
        NON_CANONICAL_BASE64,
    }

    class ContractException(val contractError: ContractError) : Exception(contractError.name)

    fun deriveScopeKeys(accountMasterKey: ByteArray, scope: Scope): ScopeKeys {
        requireContract(accountMasterKey.size == 32, ContractError.INVALID_ACCOUNT_MASTER_KEY)
        val context = encodeScopeContext(scope)
        val scopePrk = hmacSha256(
            "gagaodok/e2ee/v1/hkdf-salt".toByteArray(StandardCharsets.UTF_8),
            accountMasterKey,
        )
        val scopeRoot = hkdfExpand(
            scopePrk,
            hkdfInfo("gagaodok/e2ee/v1/scope-root", context),
            32,
        )
        return ScopeKeys(
            scopeRootKey = scopeRoot,
            fieldAEADKey = derivedKey("gagaodok/e2ee/v1/field-aead", scopeRoot),
            checkpointAEADKey = derivedKey("gagaodok/e2ee/v1/checkpoint-aead", scopeRoot),
            attachmentWrapKey = derivedKey("gagaodok/e2ee/v1/attachment-wrap", scopeRoot),
            compatTagKey = derivedKey("gagaodok/e2ee/v1/compat-tag", scopeRoot),
        )
    }

    fun encodeAAD(context: AADContext): ByteArray {
        val bubbleOrder = context.bubbleOrder?.also {
            requireContract(it >= 0, ContractError.INVALID_IDENTITY)
        }
        val recoveryVersion = context.recoveryVersion?.also {
            requireContract(it in 0..0xffff_ffffL, ContractError.INVALID_IDENTITY)
        }
        return encodeLP(
            listOf(
                1 to uint16(PROTOCOL_VERSION),
                2 to uint32(KEY_GENERATION),
                3 to canonicalUuid(context.scope.accountId),
                4 to utf8(context.scope.spaceId),
                5 to canonicalUuid(context.scope.roomId),
                6 to context.scope.worldlineId?.let(::canonicalUuid),
                7 to ascii(context.entityType),
                8 to utf8(context.entityId),
                9 to context.fieldPath?.let(::utf8),
                10 to bubbleOrder?.let(::uint64),
                11 to recoveryVersion?.let(::uint32),
                12 to byteArrayOf(ALGORITHM.toByte()),
            ),
        )
    }

    fun seal(
        plaintext: ByteArray,
        key: ByteArray,
        nonce: ByteArray,
        context: AADContext,
    ): ByteArray {
        requireContract(key.size == 32, ContractError.INVALID_KEY)
        requireContract(nonce.size == 12, ContractError.INVALID_NONCE)
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD(encodeAAD(context))
            byteArrayOf(PROTOCOL_VERSION.toByte(), ALGORITHM.toByte()) +
                uint32(KEY_GENERATION) + nonce + cipher.doFinal(plaintext)
        } catch (error: ContractException) {
            throw error
        } catch (error: Exception) {
            throw ContractException(ContractError.AUTHENTICATION_FAILED)
        }
    }

    fun open(envelope: ByteArray, key: ByteArray, context: AADContext): ByteArray {
        requireContract(key.size == 32, ContractError.INVALID_KEY)
        requireContract(envelope.size >= 34, ContractError.INVALID_ENVELOPE)
        requireContract(
            envelope[0].toInt() and 0xff == PROTOCOL_VERSION,
            ContractError.UNSUPPORTED_VERSION,
        )
        requireContract(
            envelope[1].toInt() and 0xff == ALGORITHM,
            ContractError.UNSUPPORTED_ALGORITHM,
        )
        val generation = ByteBuffer.wrap(envelope, 2, 4).order(ByteOrder.BIG_ENDIAN).int.toLong() and 0xffff_ffffL
        requireContract(generation == KEY_GENERATION, ContractError.UNSUPPORTED_KEY_GENERATION)

        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                SecretKeySpec(key, "AES"),
                GCMParameterSpec(128, envelope.copyOfRange(6, 18)),
            )
            cipher.updateAAD(encodeAAD(context))
            cipher.doFinal(envelope.copyOfRange(18, envelope.size))
        } catch (error: ContractException) {
            throw error
        } catch (error: AEADBadTagException) {
            throw ContractException(ContractError.AUTHENTICATION_FAILED)
        } catch (error: Exception) {
            throw ContractException(ContractError.AUTHENTICATION_FAILED)
        }
    }

    fun encodeBase64(data: ByteArray): String = Base64.getEncoder().encodeToString(data)

    fun decodeBase64(value: String): ByteArray {
        val decoded = try {
            Base64.getDecoder().decode(value)
        } catch (error: IllegalArgumentException) {
            throw ContractException(ContractError.NON_CANONICAL_BASE64)
        }
        requireContract(encodeBase64(decoded) == value, ContractError.NON_CANONICAL_BASE64)
        return decoded
    }

    private fun encodeScopeContext(scope: Scope): ByteArray {
        requireContract(scope.spaceId in VALID_SPACES, ContractError.INVALID_SCOPE)
        return encodeLP(
            listOf(
                1 to canonicalUuid(scope.accountId),
                2 to utf8(scope.spaceId),
                3 to canonicalUuid(scope.roomId),
                4 to scope.worldlineId?.let(::canonicalUuid),
            ),
        )
    }

    private fun derivedKey(label: String, scopeRoot: ByteArray): ByteArray =
        hkdfExpand(scopeRoot, hkdfInfo(label, null), 32)

    private fun hkdfInfo(purpose: String, context: ByteArray?): ByteArray = encodeLP(
        listOf(
            1 to uint16(PROTOCOL_VERSION),
            2 to utf8(purpose),
            3 to context,
        ),
    )

    private fun hkdfExpand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        requireContract(length in 0..(255 * 32), ContractError.INVALID_KEY)
        val output = ByteArrayOutputStream()
        var previous = byteArrayOf()
        var counter = 1
        while (output.size() < length) {
            previous = hmacSha256(prk, previous + info + byteArrayOf(counter.toByte()))
            output.write(previous)
            counter += 1
        }
        return output.toByteArray().copyOf(length)
    }

    private fun hmacSha256(key: ByteArray, message: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(message)
    }

    private fun encodeLP(fields: List<Pair<Int, ByteArray?>>): ByteArray {
        requireContract(fields.size <= 0xffff, ContractError.INVALID_TEXT)
        val output = ByteArrayOutputStream()
        output.write(MAGIC)
        output.write(uint16(fields.size))
        var previousId = 0
        fields.forEach { (fieldId, value) ->
            requireContract(fieldId in 1..0xffff && fieldId > previousId, ContractError.INVALID_TEXT)
            previousId = fieldId
            output.write(uint16(fieldId))
            if (value == null) {
                output.write(0)
                output.write(uint32(0))
            } else {
                output.write(1)
                output.write(uint32(value.size.toLong()))
                output.write(value)
            }
        }
        return output.toByteArray()
    }

    private fun canonicalUuid(value: String): ByteArray {
        val parsed = try {
            UUID.fromString(value)
        } catch (error: IllegalArgumentException) {
            throw ContractException(ContractError.INVALID_IDENTITY)
        }
        requireContract(parsed.toString().uppercase() == value, ContractError.INVALID_IDENTITY)
        return ascii(value)
    }

    private fun utf8(value: String): ByteArray {
        return try {
            val encoder = StandardCharsets.UTF_8.newEncoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            val buffer = encoder.encode(java.nio.CharBuffer.wrap(value))
            ByteArray(buffer.remaining()).also(buffer::get)
        } catch (error: Exception) {
            throw ContractException(ContractError.INVALID_TEXT)
        }
    }

    private fun ascii(value: String): ByteArray {
        requireContract(value.isNotEmpty() && value.all { it.code in 0..0x7f }, ContractError.INVALID_TEXT)
        return value.toByteArray(StandardCharsets.US_ASCII)
    }

    private fun uint16(value: Int): ByteArray {
        requireContract(value in 0..0xffff, ContractError.INVALID_TEXT)
        return ByteBuffer.allocate(2).order(ByteOrder.BIG_ENDIAN).putShort(value.toShort()).array()
    }

    private fun uint32(value: Long): ByteArray {
        requireContract(value in 0..0xffff_ffffL, ContractError.INVALID_TEXT)
        return ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(value.toInt()).array()
    }

    private fun uint64(value: Long): ByteArray {
        requireContract(value >= 0, ContractError.INVALID_TEXT)
        return ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN).putLong(value).array()
    }

    private fun requireContract(condition: Boolean, error: ContractError) {
        if (!condition) throw ContractException(error)
    }
}
