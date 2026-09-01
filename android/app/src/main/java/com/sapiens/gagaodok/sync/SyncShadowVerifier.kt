package com.sapiens.gagaodok.sync

import java.util.Base64
import java.security.MessageDigest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * What this device could actually make of the shadow it pulled.
 *
 * Counts and one digest. No decrypted line is kept, returned or logged: the
 * question this answers is "did every bubble arrive and can this device read
 * it", not "what does the conversation say".
 */
data class SyncShadowVerification(
    val roomId: String,
    val bubbleCount: Int,
    val turnCount: Int,
    /** Bubbles whose sealed fields opened with this account's key. */
    val decryptedCount: Int,
    /**
     * The same digest the writing device computes — bubble identity and order
     * only. Equal digests on two devices mean the same bubbles arrived in the
     * same order, without either screen showing a word of the conversation.
     */
    val contentHash: String,
    /**
     * Why the first unreadable bubble did not open, in non-secret terms.
     *
     * Present only to tell apart the failures that look identical from
     * outside: a wrong account, a key that is not this account's, and a row
     * whose shape the reader did not expect all produce the same "0 opened".
     */
    val diagnostic: String,
) {
    val allDecrypted: Boolean get() = bubbleCount > 0 && decryptedCount == bubbleCount
}

class SyncShadowVerifyException(val reason: Reason) : Exception(reason.name) {
    enum class Reason { SECRETS_UNAVAILABLE, MALFORMED_REPLICA, ROOM_ABSENT }
}

/**
 * Proving that a bubble written on another device can be read on this one.
 *
 * The replica is opaque on purpose — `SyncReplicaStore` keeps ciphertext and
 * never learns a key. This is the one place that opens it, and it opens into
 * local variables that go out of scope immediately.
 *
 * A bubble counts as decrypted only when every sealed field it carries opens
 * under the AAD built from that row's own identity and `bubble_order`. That is
 * what makes the number mean something: a row moved to a different order,
 * re-attributed to another room, or written outside this account cannot be
 * made to open, so it cannot be counted.
 */
object SyncShadowVerifier {

    fun verify(
        replica: SyncReplicaStore,
        accountId: String,
        writerSpaceId: String,
        roomId: String,
        loadSecrets: () -> SyncSecretLoadResult,
    ): SyncShadowVerification {
        val available = loadSecrets() as? SyncSecretLoadResult.Available
            ?: throw SyncShadowVerifyException(SyncShadowVerifyException.Reason.SECRETS_UNAVAILABLE)
        val masterKey = available.secrets.accountMasterKey

        val wanted = roomId.uppercase()
        val bubbles = mutableListOf<Bubble>()
        val turns = mutableSetOf<String>()

        for (entry in replica.snapshot()) {
            val identity = decode(entry.identityJson)
            if (text(identity, "room_id")?.uppercase() != wanted ||
                text(identity, "space_id") != writerSpaceId
            ) continue
            when (entry.entityType) {
                "turn" -> text(identity, "turn_id")?.let { turns.add(it.uppercase()) }
                "bubble" -> bubbles.add(readBubble(identity, decode(entry.projectionJson), wanted))
                else -> continue
            }
        }
        if (bubbles.isEmpty() && turns.isEmpty()) {
            throw SyncShadowVerifyException(SyncShadowVerifyException.Reason.ROOM_ABSENT)
        }

        // The writing device hashed in the order it sent. Sorting by
        // bubble_order reproduces that from rows which may have arrived across
        // several pages in any order.
        bubbles.sortBy { it.order }

        var decrypted = 0
        var firstFailure: String? = null
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(wanted.toByteArray(Charsets.UTF_8))
        for (bubble in bubbles) {
            val outcome = opens(bubble, accountId, masterKey)
            if (outcome == null) decrypted += 1 else if (firstFailure == null) firstFailure = outcome
            digest.update(bubble.messageId.toByteArray(Charsets.UTF_8))
            digest.update(bigEndian(bubble.order))
        }

        return SyncShadowVerification(
            roomId = wanted,
            bubbleCount = bubbles.size,
            turnCount = turns.size,
            decryptedCount = decrypted,
            contentHash = digest.digest().joinToString("") { "%02x".format(it) },
            // The account and space are identifiers, not secrets, and seeing
            // them is the whole point: a wrong account is invisible otherwise.
            diagnostic = "acct=" + accountId.take(8) +
                " space=" + (bubbles.firstOrNull()?.spaceId ?: "-") +
                " " + (firstFailure ?: "opened"),
        )
    }

    private data class Bubble(
        val roomId: String,
        val messageId: String,
        val worldlineId: String?,
        val spaceId: String,
        val order: Long,
        /** Field path to sealed envelope, for whichever fields this row has. */
        val sealed: Map<String, String>,
    )

    private fun readBubble(identity: JsonObject, projection: JsonObject, roomId: String): Bubble {
        val messageId = text(identity, "message_id")
            ?: throw SyncShadowVerifyException(SyncShadowVerifyException.Reason.MALFORMED_REPLICA)
        val order = number(projection, "bubble_order")
            ?: throw SyncShadowVerifyException(SyncShadowVerifyException.Reason.MALFORMED_REPLICA)
        val sealed = buildMap {
            for (field in SEALED_FIELDS) {
                text(projection, field)?.let { put(field, it) }
            }
        }
        return Bubble(
            roomId = roomId,
            messageId = messageId.uppercase(),
            // `worldline_key` is the storage key and never reaches the wire;
            // the nullable `worldline_id` does. Reading the storage name found
            // nothing and happened to agree with the null-worldline rows this
            // phase writes — and would have silently mis-derived the key for
            // any row that actually had one.
            worldlineId = text(identity, "worldline_id"),
            spaceId = text(identity, "space_id")
                ?: throw SyncShadowVerifyException(SyncShadowVerifyException.Reason.MALFORMED_REPLICA),
            order = order,
            sealed = sealed,
        )
    }

    /**
     * The bubble's sealed fields, named as they appear on the wire.
     *
     * The Worker strips the `_enc` suffix when it projects a row, so the
     * column is `text_enc` in D1 and the field is `text` here. Looking for the
     * column name finds nothing and reads as "this bubble had nothing sealed",
     * which is indistinguishable from a genuinely empty row.
     */
    private val SEALED_FIELDS = listOf("sender", "kind", "text", "speaker_ref", "reactions")

    /** Null when the bubble opened; otherwise a short, non-secret reason. */
    private fun opens(bubble: Bubble, accountId: String, masterKey: ByteArray): String? {
        // A bubble with nothing sealed proves nothing about this device's key,
        // so it is not a success.
        if (bubble.sealed.isEmpty()) return "fail=no-sealed-field"
        val scope = SyncE2EE.Scope(
            accountId = accountId,
            // The originating space, taken from the row itself: a bubble the
            // Mac wrote derives its key under MAC_SPACE no matter which device
            // is reading it.
            spaceId = bubble.spaceId,
            roomId = bubble.roomId,
            worldlineId = bubble.worldlineId,
        )
        val keys = runCatching { SyncE2EE.deriveScopeKeys(masterKey, scope) }
            .getOrElse { return "fail=derive keylen=" + masterKey.size }
        for ((field, envelope) in bubble.sealed) {
            val bytes = runCatching { Base64.getDecoder().decode(envelope) }
                .getOrElse { return "fail=base64 field=" + field }
            val opened = runCatching {
                SyncE2EE.open(
                    envelope = bytes,
                    key = keys.fieldAEADKey,
                    context = SyncE2EE.AADContext(
                        scope = scope,
                        entityType = "bubble",
                        entityId = bubble.messageId,
                        fieldPath = field,
                        bubbleOrder = bubble.order,
                        recoveryVersion = null,
                    ),
                )
            }.getOrElse { return "fail=open field=" + field + " keylen=" + masterKey.size }
            // Opened plaintext is never kept. Its length is the only thing
            // read, and only to refuse an empty forgery.
            if (opened.isEmpty()) return "fail=empty field=" + field
        }
        return null
    }

    private fun bigEndian(value: Long): ByteArray =
        ByteArray(8) { index -> ((value ushr ((7 - index) * 8)) and 0xff).toByte() }

    private fun decode(raw: String): JsonObject = runCatching {
        Json.parseToJsonElement(raw) as JsonObject
    }.getOrElse {
        throw SyncShadowVerifyException(SyncShadowVerifyException.Reason.MALFORMED_REPLICA)
    }

    private fun text(source: JsonObject, key: String): String? {
        val element = source[key] ?: return null
        if (element is JsonNull) return null
        val primitive = element as? JsonPrimitive ?: return null
        if (!primitive.isString) return primitive.content
        return primitive.content
    }

    private fun number(source: JsonObject, key: String): Long? {
        val element = source[key] as? JsonPrimitive ?: return null
        return element.content.toLongOrNull()
    }
}
