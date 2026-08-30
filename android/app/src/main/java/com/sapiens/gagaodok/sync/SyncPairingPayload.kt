package com.sapiens.gagaodok.sync

import java.net.URI
import java.util.Base64

/**
 * The thing a joining device scans.
 *
 * It carries the address, the account being joined, the session, and the
 * `pairing_secret` — and nothing else. No device token, no master key, no claim
 * secret, no recovery phrase. Whoever holds this payload can attempt to join,
 * so it is shown on screen and never written to a URL, the clipboard, or a log:
 * a URL would make a scanner open a browser, leaving the secret in a history
 * somewhere.
 */
class SyncPairingPayload private constructor(
    val baseUrl: String,
    val accountId: String,
    val sessionId: String,
    val pairingSecret: ByteArray,
) {
    class PayloadException(val reason: Reason) : Exception() {
        enum class Reason { MALFORMED, NOT_CANONICAL, UNSUPPORTED_VERSION }
    }

    /**
     * Canonical bytes. The field set is fixed and ascending, so this is a
     * function of the values alone — which is what makes the decoder's
     * re-encode check meaningful.
     */
    fun encoded(): ByteArray {
        val fields = listOf(
            1 to uint32(VERSION),
            2 to baseUrl.toByteArray(Charsets.US_ASCII),
            3 to accountId.toByteArray(Charsets.US_ASCII),
            4 to sessionId.toByteArray(Charsets.US_ASCII),
            5 to pairingSecret,
        )
        val out = java.io.ByteArrayOutputStream()
        out.write(MAGIC)
        out.write(uint16(fields.size))
        for ((id, value) in fields) {
            out.write(uint16(id))
            out.write(1)
            out.write(uint32(value.size.toLong()))
            out.write(value)
        }
        return out.toByteArray()
    }

    /** Base64URL without padding, which is what a QR actually carries. */
    fun encodedText(): String = Base64.getUrlEncoder().withoutPadding().encodeToString(encoded())

    override fun equals(other: Any?): Boolean =
        other is SyncPairingPayload && encoded().contentEquals(other.encoded())

    override fun hashCode(): Int = encoded().contentHashCode()

    companion object {
        private val MAGIC = "GDP1".toByteArray(Charsets.US_ASCII)
        private const val VERSION = 1L
        private const val FIELD_COUNT = 5
        private val UUID = Regex("[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}")

        fun create(
            baseUrl: String,
            accountId: String,
            sessionId: String,
            pairingSecret: ByteArray,
        ): SyncPairingPayload {
            if (pairingSecret.size != 32) throw malformed()
            val uri = runCatching { URI(baseUrl) }.getOrNull()
            if (uri?.scheme != "https" || uri.host.isNullOrEmpty() ||
                uri.query != null || uri.fragment != null
            ) {
                throw malformed()
            }
            if (!UUID.matches(accountId) || !UUID.matches(sessionId)) throw malformed()
            return SyncPairingPayload(baseUrl, accountId, sessionId, pairingSecret)
        }

        fun decode(text: String): SyncPairingPayload {
            if (text.contains('=') || text.contains('+') || text.contains('/')) throw malformed()
            val bytes = runCatching { Base64.getUrlDecoder().decode(text) }.getOrNull() ?: throw malformed()
            val payload = decode(bytes)
            // Re-encoding is the whole canonicality check: trailing bytes, a
            // missing field, reordered fields, a lowercase UUID and a padded or
            // otherwise non-canonical Base64 spelling all fail right here.
            if (!payload.encoded().contentEquals(bytes) || payload.encodedText() != text) {
                throw PayloadException(PayloadException.Reason.NOT_CANONICAL)
            }
            return payload
        }

        fun decode(bytes: ByteArray): SyncPairingPayload {
            if (bytes.size <= 6 || !bytes.copyOfRange(0, 4).contentEquals(MAGIC)) throw malformed()
            if (readUInt16(bytes, 4) != FIELD_COUNT) throw malformed()

            var offset = 6
            val fields = LinkedHashMap<Int, ByteArray>()
            while (offset < bytes.size) {
                if (offset + 7 > bytes.size) throw malformed()
                val id = readUInt16(bytes, offset)
                if (bytes[offset + 2].toInt() != 1) throw malformed()
                val length = readUInt32(bytes, offset + 3)
                offset += 7
                if (length < 0 || offset + length > bytes.size) throw malformed()
                if (fields.containsKey(id)) throw malformed()
                fields[id] = bytes.copyOfRange(offset, offset + length)
                offset += length
            }
            if (offset != bytes.size || fields.keys.toList() != listOf(1, 2, 3, 4, 5)) throw malformed()

            val version = fields[1] ?: throw malformed()
            if (version.size != 4) throw malformed()
            if (readUInt32(version, 0).toLong() != VERSION) {
                throw PayloadException(PayloadException.Reason.UNSUPPORTED_VERSION)
            }
            return create(
                baseUrl = String(fields[2]!!, Charsets.US_ASCII),
                accountId = String(fields[3]!!, Charsets.US_ASCII),
                sessionId = String(fields[4]!!, Charsets.US_ASCII),
                pairingSecret = fields[5]!!,
            )
        }

        private fun malformed() = PayloadException(PayloadException.Reason.MALFORMED)

        private fun uint16(value: Int) =
            byteArrayOf(((value shr 8) and 0xff).toByte(), (value and 0xff).toByte())

        private fun uint32(value: Long) = byteArrayOf(
            ((value shr 24) and 0xff).toByte(),
            ((value shr 16) and 0xff).toByte(),
            ((value shr 8) and 0xff).toByte(),
            (value and 0xff).toByte(),
        )

        private fun readUInt16(bytes: ByteArray, offset: Int) =
            ((bytes[offset].toInt() and 0xff) shl 8) or (bytes[offset + 1].toInt() and 0xff)

        private fun readUInt32(bytes: ByteArray, offset: Int): Int {
            var value = 0
            for (index in 0 until 4) value = (value shl 8) or (bytes[offset + index].toInt() and 0xff)
            return value
        }
    }
}
