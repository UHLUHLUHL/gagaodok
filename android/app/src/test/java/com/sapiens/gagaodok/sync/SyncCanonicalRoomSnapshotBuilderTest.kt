package com.sapiens.gagaodok.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Swift `SyncCanonicalRoomSnapshotBuilderTests`와 같은 14가지를 확인한다. */
class SyncCanonicalRoomSnapshotBuilderTest {
    private val account = "11111111-1111-4111-8111-111111111111"
    private val master = ByteArray(32) { 0x33 }
    private val room = "10000000-0000-4000-8000-000000000001"
    private val otherRoom = "10000000-0000-4000-8000-000000000002"
    private val turn = "30000000-0000-4000-8000-000000000001"
    private val message = "20000000-0000-4000-8000-000000000001"
    private val otherMessage = "20000000-0000-4000-8000-000000000002"
    private val attachment = "70000000-0000-4000-8000-000000000001"
    private val profile = "50000000-0000-4000-8000-000000000001"
    private val persona = "60000000-0000-4000-8000-000000000001"
    private val worldline = "40000000-0000-4000-8000-000000000001"

    private fun jsonOf(pairs: List<Pair<String, String>>) =
        pairs.joinToString(",", "{", "}") { (k, v) -> "\"$k\":$v" }

    private fun quoted(value: String?) = if (value == null) "null" else "\"$value\""

    private fun entry(type: String, identity: String, projection: String) =
        SyncReplicaEntry(type, identity, projection)

    /** MAC이 만든 방을 PHONE이 읽는 상황. 노출 정책상 보이는 조합이다. */
    private fun sealed(text: String, roomId: String, entity: String, id: String, field: String, order: Long?): String {
        val scope = SyncE2EE.Scope(account, "MAC_SPACE", roomId, null)
        val keys = SyncE2EE.deriveScopeKeys(master, scope)
        val envelope = SyncE2EE.seal(
            text.toByteArray(Charsets.UTF_8),
            keys.fieldAEADKey,
            ByteArray(12) { 0x07 },
            SyncE2EE.AADContext(scope, entity, id, field, order, null),
        )
        return SyncE2EE.encodeBase64(envelope)
    }

    private fun roomEntry(roomId: String, aiState: List<Pair<String, String>> = emptyList()) = entry(
        "room",
        jsonOf(listOf("space_id" to quoted("MAC_SPACE"), "room_id" to quoted(roomId))),
        jsonOf(
            listOf(
                "origin_space_id" to quoted("MAC_SPACE"),
                "title" to quoted(sealed("합성 방", roomId, "room", roomId, "title", null)),
            ) + aiState,
        ),
    )

    private fun turnEntry(roomId: String, turnId: String, worldlineId: String? = null) = entry(
        "turn",
        jsonOf(
            listOf(
                "space_id" to quoted("MAC_SPACE"), "room_id" to quoted(roomId),
                "worldline_id" to quoted(worldlineId), "turn_id" to quoted(turnId),
            ),
        ),
        jsonOf(listOf("is_tombstoned" to "false")),
    )

    private fun bubbleEntry(roomId: String, turnId: String, messageId: String, attachmentRef: String? = null) = entry(
        "bubble",
        jsonOf(
            listOf(
                "space_id" to quoted("MAC_SPACE"), "room_id" to quoted(roomId),
                "worldline_id" to "null", "turn_id" to quoted(turnId), "message_id" to quoted(messageId),
            ),
        ),
        jsonOf(
            listOf(
                "bubble_order" to "1",
                "timestamp" to quoted("2026-01-01T00:00:00Z"),
                "is_tombstoned" to "false",
                "sender" to quoted(sealed("나", roomId, "bubble", messageId, "sender", 1)),
                "kind" to quoted(sealed("speech", roomId, "bubble", messageId, "kind", 1)),
                "text" to quoted(sealed("안녕", roomId, "bubble", messageId, "text", 1)),
            ) + (attachmentRef?.let { listOf("attachment_ref_attachment_id" to quoted(it)) } ?: emptyList()),
        ),
    )

    private fun attachmentEntry(state: String) = entry(
        "attachment",
        jsonOf(listOf("attachment_id" to quoted(attachment))),
        jsonOf(listOf("state" to quoted(state), "kind" to quoted("attachment"))),
    )

    private val builder = SyncCanonicalRoomSnapshotBuilder()
    private val assembler = SyncRemoteRoomAssembler(account, "PHONE_SPACE", master)
    private fun gapsOf(entries: List<SyncReplicaEntry>): List<SyncRoomFamilyGap> {
        val (pools, unknown) = SyncCanonicalRoomSnapshotBuilder.pools(entries)
        return builder.gaps(entries, pools, unknown)
    }

    private val base by lazy { listOf(roomEntry(room), turnEntry(room, turn), bubbleEntry(room, turn, message)) }

    @Test fun `a complete family reports no gap`() {
        assertTrue(gapsOf(base).isEmpty())
    }

    @Test fun `a missing engine profile revision is reported and clears when supplied`() {
        val withRef = listOf(
            roomEntry(room, listOf("engine_profile_id" to quoted(profile), "engine_profile_revision" to "3")),
            turnEntry(room, turn), bubbleEntry(room, turn, message),
        )
        assertEquals(listOf(SyncRoomFamilyGap.MISSING_ENGINE_PROFILE), gapsOf(withRef))

        // 같은 revision을 넣으면 gap이 사라진다. 위 판정이 우연이 아님을 확인한다.
        val profileRow = entry(
            "engine_profile",
            jsonOf(
                listOf(
                    "space_id" to quoted("MAC_SPACE"), "engine_profile_id" to quoted(profile),
                    "profile_revision" to "3",
                ),
            ),
            jsonOf(listOf("compaction_compat_tag" to quoted("x"))),
        )
        assertTrue(gapsOf(withRef + profileRow).isEmpty())
    }

    @Test fun `a missing persona snapshot revision is reported`() {
        val withRef = listOf(
            roomEntry(room, listOf("persona_snapshot_id" to quoted(persona), "persona_snapshot_revision" to "2")),
            turnEntry(room, turn), bubbleEntry(room, turn, message),
        )
        assertEquals(listOf(SyncRoomFamilyGap.MISSING_PERSONA_SNAPSHOT), gapsOf(withRef))
    }

    @Test fun `an attachment that is not ready blocks the family`() {
        val allocated = listOf(
            roomEntry(room), turnEntry(room, turn),
            bubbleEntry(room, turn, message, attachment), attachmentEntry("allocated"),
        )
        assertEquals(listOf(SyncRoomFamilyGap.ATTACHMENT_NOT_READY), gapsOf(allocated))

        val ready = listOf(
            roomEntry(room), turnEntry(room, turn),
            bubbleEntry(room, turn, message, attachment), attachmentEntry("ready"),
        )
        assertTrue(gapsOf(ready).isEmpty())
    }

    @Test fun `a referenced named worldline that is absent is reported`() {
        val entries = listOf(roomEntry(room), turnEntry(room, turn, worldline))
        assertEquals(listOf(SyncRoomFamilyGap.MISSING_WORLDLINE), gapsOf(entries))
    }

    @Test fun `an unknown entity type is raised instead of dropped`() {
        val stray = entry(
            "gemini_cache",
            jsonOf(listOf("space_id" to quoted("MAC_SPACE"), "room_id" to quoted(room))),
            jsonOf(listOf("x" to "1")),
        )
        val snapshots = assembler.assemble(base + stray)
        assertEquals(1, snapshots.size)
        assertTrue(snapshots[0].unsupportedReason!!.contains("unknown_entity"))
    }

    @Test fun `a broken family blocks only itself`() {
        val broken = listOf(
            roomEntry(room), turnEntry(room, turn),
            bubbleEntry(room, turn, message, attachment), attachmentEntry("allocated"),
        )
        val healthy = listOf(
            roomEntry(otherRoom), turnEntry(otherRoom, turn), bubbleEntry(otherRoom, turn, otherMessage),
        )
        val mixed = assembler.assemble(broken + healthy)
        assertEquals(2, mixed.size)
        assertEquals("attachment_not_ready", mixed.first { it.handle.roomId == room }.unsupportedReason)
        assertNull(mixed.first { it.handle.roomId == otherRoom }.unsupportedReason)
    }

    @Test fun `a bubble carries its attachment reference and state`() {
        val ready = listOf(
            roomEntry(room), turnEntry(room, turn),
            bubbleEntry(room, turn, message, attachment), attachmentEntry("ready"),
        )
        val carried = assembler.assemble(ready)[0].messages[0]
        assertEquals(attachment, carried.attachmentId)
        assertEquals("ready", carried.attachmentState)
        assertEquals(
            SyncAttachmentDisplayState.READY,
            SyncAttachmentDisplayState.state(carried.attachmentState!!, null),
        )
    }
}
