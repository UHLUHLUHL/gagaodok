package com.sapiens.gagaodok.sync

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SyncRemoteRoomAssemblerTest {
    @get:Rule val folder = TemporaryFolder()

    private val account = "A0000000-0000-4000-8000-000000000001"
    private val room = "B0000000-0000-4000-8000-000000000001"
    private val macTurn = "C0000000-0000-4000-8000-000000000001"
    private val phoneTurn = "C0000000-0000-4000-8000-000000000002"
    private val macMessage = "D0000000-0000-4000-8000-000000000001"
    private val phoneMessage = "D0000000-0000-4000-8000-000000000002"
    private val key = ByteArray(32) { (it + 1).toByte() }

    private fun entry(type: String, identity: String, projection: String) =
        SyncReplicaEntry(type, identity, projection)

    private fun seal(
        plaintext: String,
        space: String,
        entity: String,
        entityId: String,
        field: String,
        order: Long? = null,
    ): String {
        val scope = SyncE2EE.Scope(account, space, room, null)
        val keys = SyncE2EE.deriveScopeKeys(key, scope)
        return SyncE2EE.encodeBase64(
            SyncE2EE.seal(
                plaintext.toByteArray(),
                keys.fieldAEADKey,
                ByteArray(12) { (it + field.length).toByte() },
                SyncE2EE.AADContext(scope, entity, entityId, field, order, null),
            ),
        )
    }

    private fun room(space: String, origin: String, title: String = "원격 방") = entry(
        "room",
        buildJsonObject { put("space_id", space); put("room_id", room) }.toString(),
        buildJsonObject {
            put("origin_space_id", origin)
            put("title", seal(title, space, "room", room, "title"))
        }.toString(),
    )

    private fun turn(space: String, id: String, tombstone: Boolean? = false): SyncReplicaEntry {
        val projection = buildJsonObject { if (tombstone != null) put("is_tombstoned", tombstone) }
        return entry(
            "turn",
            buildJsonObject {
                put("space_id", space); put("room_id", room); put("worldline_id", JsonNull)
                put("turn_id", id)
            }.toString(),
            projection.toString(),
        )
    }

    private fun bubble(
        space: String,
        turn: String,
        message: String,
        order: Long,
        timestamp: String,
        text: String,
        tombstone: Boolean? = false,
        corrupt: Boolean = false,
    ): SyncReplicaEntry = entry(
        "bubble",
        buildJsonObject {
            put("space_id", space); put("room_id", room); put("worldline_id", JsonNull)
            put("turn_id", turn); put("message_id", message)
        }.toString(),
        buildJsonObject {
            put("bubble_order", order); put("timestamp", timestamp)
            if (tombstone != null) put("is_tombstoned", tombstone)
            put("sender", seal("나", space, "bubble", message, "sender", order))
            put("kind", seal("text", space, "bubble", message, "kind", order))
            put("text", if (corrupt) "AAAA" else seal(text, space, "bubble", message, "text", order))
        }.toString(),
    )

    private fun family() = listOf(
        room("MAC_SPACE", "MAC_SPACE"),
        room("PHONE_SPACE", "MAC_SPACE", "이어쓰기 shard"),
        turn("MAC_SPACE", macTurn),
        bubble("MAC_SPACE", macTurn, macMessage, 0, "2026-08-31T00:00:01Z", "먼저"),
        turn("PHONE_SPACE", phoneTurn),
        bubble("PHONE_SPACE", phoneTurn, phoneMessage, 0, "2026-08-31T00:00:02Z", "나중"),
    )

    private fun assembler() = SyncRemoteRoomAssembler(account, "PHONE_SPACE", key)

    @Test fun `unions two writer spaces under the authoritative origin`() {
        val snapshot = assembler().assemble(family()).single()
        assertEquals(SyncRoomHandle("MAC_SPACE", room), snapshot.handle)
        assertEquals(listOf("MAC_SPACE", "PHONE_SPACE"), snapshot.writerSpaces)
        assertEquals("원격 방", snapshot.title)
        assertEquals(listOf("먼저", "나중"), snapshot.messages.map { it.text })
        assertTrue(snapshot.contentHash.isNotEmpty())
    }

    @Test fun `rejects conflicting origin and missing authoritative origin`() {
        val conflict = family().toMutableList().also { it[1] = room("PHONE_SPACE", "TABLET_SPACE") }
        assertTrue(assembler().assemble(conflict).isEmpty())
        assertTrue(assembler().assemble(family().drop(1).filterNot { it == family()[0] }).isEmpty())
    }

    @Test fun `rejects orphan bubble and missing tombstone state`() {
        assertTrue(assembler().assemble(family().filterNot { it == family()[2] }).isEmpty())
        val missing = family().toMutableList().also { it[2] = turn("MAC_SPACE", macTurn, null) }
        assertTrue(assembler().assemble(missing).isEmpty())
    }

    @Test fun `excludes tombstoned turns and bubbles`() {
        val turnDeleted = family().toMutableList().also { it[2] = turn("MAC_SPACE", macTurn, true) }
        assertEquals(listOf("나중"), assembler().assemble(turnDeleted).single().messages.map { it.text })
        val bubbleDeleted = family().toMutableList().also {
            it[3] = bubble("MAC_SPACE", macTurn, macMessage, 0, "2026-08-31T00:00:01Z", "먼저", true)
        }
        assertEquals(listOf("나중"), assembler().assemble(bubbleDeleted).single().messages.map { it.text })
    }

    @Test fun `rejects decrypt failure instead of showing a partial room`() {
        val corrupt = family().toMutableList().also {
            it[3] = bubble("MAC_SPACE", macTurn, macMessage, 0, "2026-08-31T00:00:01Z", "먼저", corrupt = true)
        }
        assertTrue(assembler().assemble(corrupt).isEmpty())
    }

    @Test fun `sorts by timestamp then writer space then order`() {
        val rows = family().toMutableList().also {
            it[3] = bubble("MAC_SPACE", macTurn, macMessage, 2, "2026-08-31T00:00:01Z", "mac-2")
            it[5] = bubble("PHONE_SPACE", phoneTurn, phoneMessage, 0, "2026-08-31T00:00:01Z", "phone-0")
            it += bubble(
                "MAC_SPACE", macTurn, "D0000000-0000-4000-8000-000000000003", 1,
                "2026-08-31T00:00:01Z", "mac-1",
            )
        }
        assertEquals(listOf("mac-1", "mac-2", "phone-0"), assembler().assemble(rows).single().messages.map { it.text })
    }

    @Test fun `repository replaces only its own canonical file`() {
        val root = folder.newFolder("root")
        val local = File(root, "local-conversation.json").also { it.writeText("DO-NOT-TOUCH") }
        val snapshot = assembler().assemble(family()).single()
        val repository = SyncRemoteRoomRepository(root)
        repository.replace(snapshot)
        assertEquals(snapshot, repository.load(snapshot.handle))
        assertEquals("DO-NOT-TOUCH", local.readText())
        assertTrue(File(root, "sync/remote/rooms/MAC_SPACE/$room.json").isFile)
        assertEquals(snapshot, repository.list().single())
    }
}
