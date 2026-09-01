package com.sapiens.gagaodok.sync

import java.io.File
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SyncRoomExposurePolicyTest {
    @get:Rule val folder = TemporaryFolder()

    @Test fun `pins all nine origin and viewer cells`() {
        val spaces = listOf("MAC_SPACE", "PHONE_SPACE", "TABLET_SPACE")
        val visible = setOf("MAC_SPACE>PHONE_SPACE", "TABLET_SPACE>MAC_SPACE", "TABLET_SPACE>PHONE_SPACE")
        spaces.forEach { origin ->
            spaces.forEach { viewer ->
                assertEquals(
                    "$origin -> $viewer",
                    "$origin>$viewer" in visible,
                    SyncRoomExposurePolicy.isVisible(origin, viewer),
                )
            }
        }
        assertFalse(SyncRoomExposurePolicy.isVisible("UNKNOWN", "PHONE_SPACE"))
        assertFalse(SyncRoomExposurePolicy.isVisible("MAC_SPACE", "UNKNOWN"))
    }

    @Test fun `catalog refresh and open leave local conversation files unchanged`() {
        val root = folder.newFolder("root")
        val list = File(root, "rooms_list.json").also { it.writeText("LOCAL-LIST") }
        val messages = File(root, "room_B0000000-0000-4000-8000-000000000001_messages.json")
            .also { it.writeText("LOCAL-MESSAGES") }
        val before = listOf(hash(list), hash(messages))
        val snapshot = SyncRemoteRoomSnapshot(
            SyncRoomHandle("MAC_SPACE", "B0000000-0000-4000-8000-000000000001"),
            "원격 방",
            listOf("MAC_SPACE"),
            listOf(
                SyncRemoteBubble(
                    "MAC_SPACE", "C0000000-0000-4000-8000-000000000001",
                    "D0000000-0000-4000-8000-000000000001", 0,
                    "2026-08-31T00:00:00Z", "상대", "text", "합성 메시지",
                ),
            ),
            "synthetic-hash",
        )
        val repository = SyncRemoteRoomRepository(root)
        repository.replace(snapshot)
        val catalog = SyncRemoteRoomCatalog(repository, "PHONE_SPACE")
        val visible = catalog.refresh()
        assertEquals(listOf(snapshot), visible)
        assertEquals(snapshot, catalog.open(snapshot.handle))
        assertEquals(before, listOf(hash(list), hash(messages)))
    }

    private fun hash(file: File): String = MessageDigest.getInstance("SHA-256")
        .digest(file.readBytes()).joinToString("") { "%02x".format(it) }
}
