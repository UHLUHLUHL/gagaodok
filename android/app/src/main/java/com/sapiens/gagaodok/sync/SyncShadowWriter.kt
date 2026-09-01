package com.sapiens.gagaodok.sync

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.Locale
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** One bubble to write, before it is sealed. */
data class SyncShadowOutgoingBubble(
    val messageId: String,
    val turnId: String,
    val sender: String,
    val kind: String,
    val text: String,
    val timestampRfc3339: String,
)

/** Counts and a digest for what was queued. Never any text. */
data class SyncShadowWriteManifest(
    val roomId: String,
    val spaceId: String,
    val turnCount: Int,
    val bubbleCount: Int,
    val contentHash: String,
    val operationCount: Int,
    val worldlineId: String?,
)

/**
 * Writing this device's own rows, for the other devices to read.
 *
 * A device may only write rows in the space it is registered in — the Worker
 * refuses anything else — so this never touches the Mac's rows. What it
 * produces is the reverse direction of the same one-way copy: rows owned here,
 * readable everywhere.
 *
 * The digest is computed the same way the Mac computes it, from bubble identity
 * and order alone, so the two sides can agree on what arrived without either
 * showing a line.
 */
class SyncShadowWriter(
    private val accountId: String,
    private val deviceId: String,
    private val originSpaceId: String,
    private val writerSpaceId: String,
    private val masterKey: ByteArray,
    private val randomBytes: (Int) -> ByteArray = { count ->
        ByteArray(count).also { SecureRandom().nextBytes(it) }
    },
    private val newOperationId: () -> String = {
        java.util.UUID.randomUUID().toString().uppercase(Locale.ROOT)
    },
    /**
     * `created_at` on the request envelope — provenance for the operation
     * itself, not the bubble's own time, which travels as bubble metadata.
     * Injected so a test run is reproducible.
     */
    private val now: () -> String = {
        java.time.Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS).toString()
    },
) {

    fun write(
        roomId: String,
        title: String,
        bubbles: List<SyncShadowOutgoingBubble>,
        outbox: SyncOutbox,
        startingBubbleOrder: Long = 0,
        /**
         * The room's active worldline, for a group room that has one.
         *
         * It is part of the scope and of every AAD, so a row written under one
         * worldline cannot be opened under another — and a reader deriving with
         * null for a row that has one decrypts nothing.
         */
        worldlineId: String? = null,
    ): SyncShadowWriteManifest {
        val room = roomId.uppercase(Locale.ROOT)
        val worldline = worldlineId?.uppercase(Locale.ROOT)
        val scope = SyncE2EE.Scope(accountId, writerSpaceId, room, worldline)
        val keys = SyncE2EE.deriveScopeKeys(masterKey, scope)
        // A room row carries no worldline in its identity, so every reader
        // derives its key with null. Sealing the title under the worldline
        // scope would produce a title nobody — including this device after a
        // reinstall — could ever open.
        val roomScope = SyncE2EE.Scope(accountId, writerSpaceId, room, null)
        val roomKeys =
            if (worldline == null) keys else SyncE2EE.deriveScopeKeys(masterKey, roomScope)

        var operations = 0
        // A room row has no worldline component in its identity — its
        // worldline-scoped rows do — so the room is written once either way.
        enqueue(outbox, roomOperation(room, title, roomScope, roomKeys)); operations += 1

        val seenTurns = LinkedHashSet<String>()
        var order = startingBubbleOrder
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(room.toByteArray(Charsets.UTF_8))

        for (bubble in bubbles) {
            val turn = bubble.turnId.uppercase(Locale.ROOT)
            if (seenTurns.add(turn)) {
                enqueue(outbox, turnOperation(room, turn, bubble.timestampRfc3339, worldline))
                operations += 1
            }
            enqueue(outbox, bubbleOperation(room, bubble, order, scope, keys, worldline))
            operations += 1
            digest.update(bubble.messageId.uppercase(Locale.ROOT).toByteArray(Charsets.UTF_8))
            digest.update(bigEndian(order))
            order += 1
        }

        return SyncShadowWriteManifest(
            roomId = room,
            spaceId = writerSpaceId,
            turnCount = seenTurns.size,
            bubbleCount = bubbles.size,
            contentHash = digest.digest().joinToString("") { "%02x".format(it) },
            operationCount = operations,
            worldlineId = worldline,
        )
    }

    private fun roomOperation(
        room: String,
        title: String,
        scope: SyncE2EE.Scope,
        keys: SyncE2EE.ScopeKeys,
    ): JsonObject = body("create_room", "room") {
        put("target", target(room))
        put("metadata_set", buildJsonObject { put("origin_space_id", originSpaceId) })
        put(
            "set",
            buildJsonObject {
                put("title", seal(title, keys, aad(scope, "room", room, "title", null)))
            },
        )
    }

    private fun turnOperation(
        room: String,
        turn: String,
        createdAt: String,
        worldline: String?,
    ): JsonObject =
        body("create_turn", "turn") {
            put("target", target(room, worldline) { put("turn_id", turn) })
            // Who made the turn and when. Both are NOT NULL in D1 and neither
            // can be recovered from a sealed body.
            put(
                "metadata_set",
                buildJsonObject {
                    put("created_by_device_id", deviceId)
                    put("created_at", createdAt)
                },
            )
            put("set", buildJsonObject { })
        }

    private fun bubbleOperation(
        room: String,
        bubble: SyncShadowOutgoingBubble,
        order: Long,
        scope: SyncE2EE.Scope,
        keys: SyncE2EE.ScopeKeys,
        worldline: String?,
    ): JsonObject {
        val message = bubble.messageId.uppercase(Locale.ROOT)
        return body("create_bubble", "bubble") {
            put(
                "target",
                target(room, worldline) {
                    put("turn_id", bubble.turnId.uppercase(Locale.ROOT))
                    put("message_id", message)
                },
            )
            put("bubble_order", order)
            put("metadata_set", buildJsonObject { put("timestamp", bubble.timestampRfc3339) })
            put(
                "set",
                buildJsonObject {
                    // The field names are the wire names, which is what the
                    // reader sees; the `_enc` spelling is D1's column and
                    // belongs nowhere near a request.
                    put("sender", seal(bubble.sender, keys, aad(scope, "bubble", message, "sender", order)))
                    put("kind", seal(bubble.kind, keys, aad(scope, "bubble", message, "kind", order)))
                    put("text", seal(bubble.text, keys, aad(scope, "bubble", message, "text", order)))
                },
            )
        }
    }

    private fun aad(
        scope: SyncE2EE.Scope,
        entityType: String,
        entityId: String,
        field: String,
        order: Long?,
    ) = SyncE2EE.AADContext(scope, entityType, entityId, field, order, null)

    private fun seal(text: String, keys: SyncE2EE.ScopeKeys, context: SyncE2EE.AADContext): String =
        Base64.getEncoder().encodeToString(
            SyncE2EE.seal(text.toByteArray(Charsets.UTF_8), keys.fieldAEADKey, randomBytes(12), context)
        )

    private fun target(
        room: String,
        worldline: String? = null,
        extra: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {},
    ) = buildJsonObject {
        put("space_id", writerSpaceId)
        put("room_id", room)
        if (worldline == null) put("worldline_id", JsonNull) else put("worldline_id", worldline)
        extra()
    }

    private fun body(
        op: String,
        entityType: String,
        fill: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit,
    ): JsonObject = buildJsonObject {
        put("protocol_version", 1)
        put("operation_id", newOperationId())
        put("device_id", deviceId)
        put("op", op)
        put("entity_type", entityType)
        put("metadata_clear", buildJsonArray { })
        put("clear", buildJsonArray { })
        put("created_at", now())
        fill()
    }

    private fun enqueue(outbox: SyncOutbox, operation: JsonObject) {
        val id = (operation.getValue("operation_id") as JsonPrimitive).content
        outbox.enqueue(id, operation.toString().toByteArray(Charsets.UTF_8))
    }

    private fun bigEndian(value: Long): ByteArray =
        ByteArray(8) { index -> ((value ushr ((7 - index) * 8)) and 0xff).toByte() }
}
