package com.sapiens.gagaodok.sync

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/** 방 가족이 참조하는 것을 실제로 다 갖고 있는지 판정한다. */
enum class SyncRoomFamilyGap(val wire: String) {
    UNKNOWN_ENTITY("unknown_entity"),
    MISSING_WORLDLINE("worldline_missing"),
    MISSING_ENGINE_PROFILE("engine_profile_revision_missing"),
    MISSING_PERSONA_SNAPSHOT("persona_snapshot_missing"),
    MISSING_CHECKPOINT_TURN("checkpoint_turn_missing"),
    ATTACHMENT_NOT_READY("attachment_not_ready"),
}

/** 계정 단위 pool. 방에 속하지 않고 여러 방이 함께 참조한다. */
data class SyncRoomFamilyPools(
    val engineProfiles: Set<String>,
    val personaSnapshots: Set<String>,
    val attachmentStates: Map<String, String>,
)

/**
 * 방 가족의 완결성만 판정한다. 렌더링은 assembler가 한다.
 *
 * 규칙 셋:
 *  1. 참조된 revision이 없으면 그 가족을 unsupported로 표시한다. 기본값을 지어내지 않는다.
 *  2. 모르는 entity_type은 버리지 않고 UNKNOWN_ENTITY로 올린다. 조용한 누락이
 *     "완전한 대화"처럼 보이는 것이 가장 나쁜 실패다.
 *  3. 한 가족의 결손이 다른 방으로 번지지 않는다.
 *
 * group_state에는 gap이 없다. 평문에서 그것을 가리키는 참조가 없어 "있어야 하는데
 * 없다"를 판정할 방법이 없다. 못 재는 것을 재는 척하지 않는다.
 */
class SyncCanonicalRoomSnapshotBuilder {
    companion object {
        val ROOM_SCOPED_TYPES = setOf("room", "group_state", "worldline", "turn", "bubble", "checkpoint")
        val POOL_TYPES = setOf("engine_profile", "persona_snapshot", "attachment")
        private val JSON = Json { ignoreUnknownKeys = true }

        private fun parse(text: String): JsonObject? =
            runCatching { JSON.parseToJsonElement(text).jsonObject }.getOrNull()

        private fun JsonObject.text(key: String) = this[key]?.jsonPrimitive?.contentOrNull
        private fun JsonObject.number(key: String) = this[key]?.jsonPrimitive?.longOrNull

        /** 계정 단위 pool을 모은다. 모르는 entity_type이 있으면 second가 true다. */
        fun pools(entries: List<SyncReplicaEntry>): Pair<SyncRoomFamilyPools, Boolean> {
            val engineProfiles = mutableSetOf<String>()
            val personaSnapshots = mutableSetOf<String>()
            val attachmentStates = mutableMapOf<String, String>()
            var unknown = false
            for (entry in entries) {
                val identity = parse(entry.identityJson)
                if (identity == null) { unknown = true; continue }
                when (entry.entityType) {
                    "engine_profile" -> revisionKey(identity, "engine_profile_id", "profile_revision")
                        ?.let { engineProfiles += it } ?: run { unknown = true }
                    "persona_snapshot" -> revisionKey(identity, "persona_snapshot_id", "snapshot_revision")
                        ?.let { personaSnapshots += it } ?: run { unknown = true }
                    "attachment" -> {
                        val id = identity.text("attachment_id")
                        val state = parse(entry.projectionJson)?.text("state")
                        if (id == null || state == null) unknown = true
                        else attachmentStates[id.uppercase()] = state
                    }
                    else -> if (entry.entityType !in ROOM_SCOPED_TYPES) unknown = true
                }
            }
            return SyncRoomFamilyPools(engineProfiles, personaSnapshots, attachmentStates) to unknown
        }

        private fun revisionKey(identity: JsonObject, idKey: String, revisionKey: String): String? {
            val space = identity.text("space_id") ?: return null
            val id = identity.text(idKey) ?: return null
            val revision = identity.number(revisionKey) ?: return null
            return "$space|${id.uppercase()}|$revision"
        }

        private fun revisionKeyFromProjection(
            identity: JsonObject,
            projection: JsonObject,
            idKey: String,
            revisionKey: String,
        ): String? {
            val space = identity.text("space_id") ?: return null
            val id = projection.text(idKey) ?: return null
            val revision = projection.number(revisionKey) ?: return null
            return "$space|${id.uppercase()}|$revision"
        }
    }

    /** 한 방 가족의 결손을 모은다. 정렬된 채로 돌려준다. */
    fun gaps(
        roomEntries: List<SyncReplicaEntry>,
        pools: SyncRoomFamilyPools,
        poolsHadUnknown: Boolean,
    ): List<SyncRoomFamilyGap> {
        val found = mutableSetOf<SyncRoomFamilyGap>()
        if (poolsHadUnknown) found += SyncRoomFamilyGap.UNKNOWN_ENTITY
        val worldlines = mutableSetOf<String>()
        val turnIds = mutableSetOf<String>()
        val referencedWorldlines = mutableSetOf<String>()
        val checkpointTurns = mutableSetOf<String>()

        for (entry in roomEntries) {
            val identity = parse(entry.identityJson)
            if (identity == null) { found += SyncRoomFamilyGap.UNKNOWN_ENTITY; continue }
            val projection = parse(entry.projectionJson) ?: JsonObject(emptyMap())
            when (entry.entityType) {
                "room" -> {
                    // room_ai_state_ref는 평문 보조 블록이다. 가리키는 revision이
                    // pool에 없으면 기본값으로 때우지 않고 unsupported로 올린다.
                    revisionKeyFromProjection(identity, projection, "engine_profile_id", "engine_profile_revision")
                        ?.let { if (it !in pools.engineProfiles) found += SyncRoomFamilyGap.MISSING_ENGINE_PROFILE }
                    revisionKeyFromProjection(identity, projection, "persona_snapshot_id", "persona_snapshot_revision")
                        ?.let { if (it !in pools.personaSnapshots) found += SyncRoomFamilyGap.MISSING_PERSONA_SNAPSHOT }
                }
                "worldline" -> identity.text("worldline_id")?.let { worldlines += it.uppercase() }
                "turn" -> {
                    identity.text("turn_id")?.let { turnIds += it.uppercase() }
                    identity.text("worldline_id")?.let { referencedWorldlines += it.uppercase() }
                }
                "bubble" -> {
                    identity.text("worldline_id")?.let { referencedWorldlines += it.uppercase() }
                    projection.text("attachment_ref_attachment_id")?.let {
                        // 아직 ready가 아닌 첨부를 가진 방은 이어쓰기를 열지 않는다.
                        if (pools.attachmentStates[it.uppercase()] != "ready") {
                            found += SyncRoomFamilyGap.ATTACHMENT_NOT_READY
                        }
                    }
                }
                "checkpoint" -> {
                    identity.text("worldline_id")?.let { referencedWorldlines += it.uppercase() }
                    for (key in listOf("first_turn_id", "last_turn_id")) {
                        projection.text(key)?.let { checkpointTurns += it.uppercase() }
                    }
                }
                "group_state" -> Unit
                // 계정 단위 pool이다. 방 목록에 섞여 들어와도 모르는 것으로 치지 않는다.
                "engine_profile", "persona_snapshot", "attachment" -> Unit
                else -> found += SyncRoomFamilyGap.UNKNOWN_ENTITY
            }
        }

        if ((referencedWorldlines - worldlines).isNotEmpty()) found += SyncRoomFamilyGap.MISSING_WORLDLINE
        if ((checkpointTurns - turnIds).isNotEmpty()) found += SyncRoomFamilyGap.MISSING_CHECKPOINT_TURN
        return found.sortedBy { it.wire }
    }
}
