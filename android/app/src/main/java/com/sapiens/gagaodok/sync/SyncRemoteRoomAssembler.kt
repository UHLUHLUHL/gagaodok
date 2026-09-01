package com.sapiens.gagaodok.sync

import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Instant
import java.time.format.DateTimeParseException
import java.util.Locale
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/** Strictly assembles remote writer shards without ever receiving a ChatStore. */
class SyncRemoteRoomAssembler(
    private val accountId: String,
    private val registeredSpaceId: String,
    private val masterKey: ByteArray,
) {
    private data class RoomRow(val space: String, val origin: String, val projection: JsonObject, val extensions: JsonArray)
    private data class TurnKey(val space: String, val turn: String)
    private data class BubbleRow(
        val space: String,
        val turn: String,
        val message: String,
        val order: Long,
        val timestamp: String,
        val instant: Instant,
        val projection: JsonObject,
        val tombstoned: Boolean,
        val attachmentId: String?,
    )

    fun assemble(entries: List<SyncReplicaEntry>): List<SyncRemoteRoomSnapshot> {
        if (registeredSpaceId !in SPACES || masterKey.size != 32) return emptyList()
        // 예전에는 여기서 room·turn·bubble만 통과시켰다. 나머지 6종은 분기에 닿기
        // 전에 걸러져 조용히 버려졌고, "지원하지 않음" 표시조차 뜨지 않았다.
        val (pools, poolsHadUnknown) = SyncCanonicalRoomSnapshotBuilder.pools(entries)
        var strayUnknown = poolsHadUnknown
        val families = sortedMapOf<String, MutableList<SyncReplicaEntry>>()
        for (entry in entries) {
            if (entry.entityType in SyncCanonicalRoomSnapshotBuilder.POOL_TYPES) continue
            if (entry.entityType !in SyncCanonicalRoomSnapshotBuilder.ROOM_SCOPED_TYPES) {
                strayUnknown = true; continue
            }
            val identity = parseObject(entry.identityJson)
            val room = identity?.let { canonicalUuid(it["room_id"]?.jsonPrimitive?.contentOrNull) }
            if (room == null) { strayUnknown = true; continue }
            families.getOrPut(room) { mutableListOf() } += entry
        }
        val builder = SyncCanonicalRoomSnapshotBuilder()
        return families.mapNotNull { (room, family) ->
            val snapshot = assembleFamily(room, family, pools) ?: return@mapNotNull null
            // 한 가족의 결손은 그 가족만 막는다. 다른 방으로 번지지 않는다.
            val gaps = builder.gaps(family, pools, strayUnknown)
            if (gaps.isEmpty()) snapshot
            else snapshot.copy(unsupportedReason = gaps.joinToString(",") { it.wire })
        }
    }

    private fun assembleFamily(
        roomId: String,
        entries: List<SyncReplicaEntry>,
        pools: SyncRoomFamilyPools,
    ): SyncRemoteRoomSnapshot? {
        val rooms = mutableListOf<RoomRow>()
        val turns = mutableMapOf<TurnKey, Boolean>()
        val bubbles = mutableListOf<BubbleRow>()
        for (entry in entries) {
            val identity = parseObject(entry.identityJson) ?: return null
            val projection = parseObject(entry.projectionJson) ?: return null
            when (entry.entityType) {
                "room" -> {
                    if (identity.keys != setOf("space_id", "room_id")) return null
                    val space = identity.text("space_id") ?: return null
                    val origin = projection.text("origin_space_id") ?: return null
                    if (space !in SPACES || origin !in SPACES || identity.uuid("room_id") != roomId) return null
                    if (projection.text("title") == null) return null
                    rooms += RoomRow(space, origin, projection, projection["extensions"] as? JsonArray ?: JsonArray(emptyList()))
                }
                "turn" -> {
                    if (identity.keys != setOf("space_id", "room_id", "worldline_id", "turn_id")) return null
                    val space = identity.text("space_id") ?: return null
                    val turn = identity.uuid("turn_id") ?: return null
                    val tombstoned = projection["is_tombstoned"]?.jsonPrimitive?.booleanOrNull ?: return null
                    val key = TurnKey(space, turn)
                    if (space !in SPACES || identity.uuid("room_id") != roomId || identity["worldline_id"] !is JsonNull) return null
                    if (turns.put(key, tombstoned) != null) return null
                }
                "bubble" -> {
                    if (identity.keys != setOf("space_id", "room_id", "worldline_id", "turn_id", "message_id")) return null
                    val space = identity.text("space_id") ?: return null
                    val turn = identity.uuid("turn_id") ?: return null
                    val message = identity.uuid("message_id") ?: return null
                    val order = projection["bubble_order"]?.jsonPrimitive?.longOrNull
                        ?.takeIf { it in 0..MAX_SAFE_INTEGER } ?: return null
                    val timestamp = projection.text("timestamp") ?: return null
                    val instant = try { Instant.parse(timestamp) } catch (_: DateTimeParseException) { return null }
                    val tombstoned = projection["is_tombstoned"]?.jsonPrimitive?.booleanOrNull ?: return null
                    if (space !in SPACES || identity.uuid("room_id") != roomId || identity["worldline_id"] !is JsonNull) return null
                    bubbles += BubbleRow(
                        space, turn, message, order, timestamp, instant, projection, tombstoned,
                        projection.text("attachment_ref_attachment_id")?.uppercase(),
                    )
                }
                // 렌더링에는 쓰지 않는다. 완결성 판정은 builder가 따로 한다.
                "group_state", "worldline", "checkpoint" -> Unit
                else -> return null
            }
        }

        val origins = rooms.map { it.origin }.toSet()
        if (origins.size != 1) return null
        val origin = origins.single()
        if (origin == registeredSpaceId || rooms.count { it.space == origin } != 1) return null
        if (rooms.any { !originAllows(origin, it.space) }) return null
        val writerSpaces = rooms.map { it.space }.toSet()
        if (turns.keys.any { it.space !in writerSpaces } || bubbles.any { it.space !in writerSpaces }) return null
        val originRoom = rooms.single { it.space == origin }
        val title = open(originRoom.projection["title"], origin, roomId, "room", roomId, "title", null) ?: return null

        val seenMessages = mutableSetOf<String>()
        val dated = mutableListOf<Pair<Instant, SyncRemoteBubble>>()
        for (bubble in bubbles) {
            val parentDeleted = turns[TurnKey(bubble.space, bubble.turn)] ?: return null
            if (!seenMessages.add("${bubble.space}:${bubble.message}")) return null
            if (parentDeleted || bubble.tombstoned) continue
            val sender = open(bubble.projection["sender"], bubble.space, roomId, "bubble", bubble.message, "sender", bubble.order) ?: return null
            val kind = open(bubble.projection["kind"], bubble.space, roomId, "bubble", bubble.message, "kind", bubble.order) ?: return null
            val text = open(bubble.projection["text"], bubble.space, roomId, "bubble", bubble.message, "text", bubble.order) ?: return null
            val speaker = optionalOpen(bubble.projection["speaker_ref"], bubble.space, roomId, bubble.message, "speaker_ref", bubble.order) ?: return null
            val reactions = optionalOpen(bubble.projection["reactions"], bubble.space, roomId, bubble.message, "reactions", bubble.order) ?: return null
            dated += bubble.instant to SyncRemoteBubble(
                bubble.space, bubble.turn, bubble.message, bubble.order, bubble.timestamp,
                sender, kind, text, speaker.second, reactions.second,
                bubble.attachmentId,
                bubble.attachmentId?.let { pools.attachmentStates[it] },
            )
        }
        val messages = dated.sortedWith(
            compareBy<Pair<Instant, SyncRemoteBubble>> { it.first }
                .thenBy { it.second.writerSpaceId }
                .thenBy { it.second.bubbleOrder },
        ).map { it.second }
        val capabilities = rooms.mapNotNull { continuationCapability(it, roomId) }.toSet()
        if (capabilities.size > 1) return null
        return SyncRemoteRoomSnapshot(
            SyncRoomHandle(origin, roomId), title, writerSpaces.sorted(), messages,
            contentHash(roomId, messages), capabilities.singleOrNull(),
        )
    }

    private fun continuationCapability(room: RoomRow, roomId: String): SyncRemoteContinuationCapability? {
        val matches = room.extensions.filter { (it as? JsonObject)?.text("key") == "gagaodok.room.continuation_capability" }
        if (matches.size > 1) return SyncRemoteContinuationCapability.UNSUPPORTED
        val value = (matches.singleOrNull() as? JsonObject)?.get("value") ?: return null
        return when (open(value, room.space, roomId, "room", roomId, "extensions.gagaodok.room.continuation_capability", null)) {
            "chatbot" -> SyncRemoteContinuationCapability.CHATBOT
            else -> SyncRemoteContinuationCapability.UNSUPPORTED
        }
    }

    private fun open(
        value: kotlinx.serialization.json.JsonElement?,
        space: String,
        room: String,
        entity: String,
        entityId: String,
        field: String,
        order: Long?,
    ): String? = runCatching {
        val encoded = value?.jsonPrimitive?.content ?: return null
        val envelope = SyncE2EE.decodeBase64(encoded)
        val scope = SyncE2EE.Scope(accountId, space, room, null)
        val keys = SyncE2EE.deriveScopeKeys(masterKey, scope)
        val opened = SyncE2EE.open(
            envelope, keys.fieldAEADKey,
            SyncE2EE.AADContext(scope, entity, entityId, field, order, null),
        )
        val text = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(java.nio.ByteBuffer.wrap(opened)).toString()
        text.takeIf { it.isNotEmpty() }
    }.getOrNull()

    /** Pair<Boolean,String?>: present/absent plus decoded value. Null means malformed. */
    private fun optionalOpen(
        value: kotlinx.serialization.json.JsonElement?,
        space: String,
        room: String,
        entityId: String,
        field: String,
        order: Long,
    ): Pair<Boolean, String?>? {
        if (value == null || value is JsonNull) return false to null
        return true to (open(value, space, room, "bubble", entityId, field, order) ?: return null)
    }

    private fun parseObject(value: String): JsonObject? =
        runCatching { Json.parseToJsonElement(value) as JsonObject }.getOrNull()

    private fun JsonObject.text(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull
    private fun JsonObject.uuid(key: String): String? = canonicalUuid(text(key))

    private fun canonicalUuid(value: String?): String? = runCatching {
        UUID.fromString(value).toString().uppercase(Locale.ROOT).takeIf { it == value }
    }.getOrNull()

    private fun originAllows(origin: String, writer: String): Boolean = when (origin) {
        "PHONE_SPACE" -> writer == "PHONE_SPACE"
        "MAC_SPACE" -> writer == "MAC_SPACE" || writer == "PHONE_SPACE"
        "TABLET_SPACE" -> writer in SPACES
        else -> false
    }

    private fun contentHash(roomId: String, messages: List<SyncRemoteBubble>): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(roomId.toByteArray())
        messages.forEach {
            digest.update(it.writerSpaceId.toByteArray())
            digest.update(it.messageId.toByteArray())
            digest.update(java.nio.ByteBuffer.allocate(8).putLong(it.bubbleOrder).array())
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    companion object {
        private val SPACES = setOf("MAC_SPACE", "PHONE_SPACE", "TABLET_SPACE")
        private val RELEVANT = SyncCanonicalRoomSnapshotBuilder.ROOM_SCOPED_TYPES
        private const val MAX_SAFE_INTEGER = 9_007_199_254_740_991L
    }
}
