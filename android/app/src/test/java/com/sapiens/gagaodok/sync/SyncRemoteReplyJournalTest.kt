package com.sapiens.gagaodok.sync

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SyncRemoteReplyJournalTest {
    @get:Rule val folder = TemporaryFolder()
    private val handle = SyncRoomHandle("MAC_SPACE", "B0000000-0000-4000-8000-000000000001")
    private val reply = "E0000000-0000-4000-8000-000000000001"
    private fun operation(id: String, byte: Byte) = SyncRemoteReplyOperation(id, byteArrayOf(byte, 2, 3))

    @Test fun `reopen keeps exact bytes and stage cannot regress`() {
        val file = File(folder.newFolder(), "journal.bin")
        val first = operation("E0000000-0000-4000-8000-000000000010", 1)
        SyncRemoteReplyJournal(file).prepare(reply, handle, "PHONE_SPACE", "로컬에만", listOf(first))
        SyncRemoteReplyJournal(file).advance(reply, SyncRemoteReplyStage.TURN_CREATED)
        assertEquals(listOf(first), SyncRemoteReplyJournal(file).entry(reply)?.operations)
        assertTrue(runCatching { SyncRemoteReplyJournal(file).advance(reply, SyncRemoteReplyStage.PREPARED) }.isFailure)
    }

    @Test fun `order conflict rebuilds only unacknowledged bubbles`() {
        val journal = SyncRemoteReplyJournal(File(folder.newFolder(), "journal.bin"))
        val turn = operation("E0000000-0000-4000-8000-000000000011", 1)
        val user = operation("E0000000-0000-4000-8000-000000000012", 2)
        val ai = operation("E0000000-0000-4000-8000-000000000013", 3)
        journal.prepare(reply, handle, "PHONE_SPACE", "keep", listOf(turn, user, ai))
        val user2 = operation("E0000000-0000-4000-8000-000000000014", 4)
        val ai2 = operation("E0000000-0000-4000-8000-000000000015", 5)
        journal.rebuildForBubbleOrderConflict(reply, false, user2, ai2)
        assertEquals(listOf(turn, user2, ai2), journal.entry(reply)?.operations)
        journal.acknowledge(reply, user2.operationId)
        val ai3 = operation("E0000000-0000-4000-8000-000000000016", 6)
        journal.rebuildForBubbleOrderConflict(reply, true, null, ai3)
        assertEquals(listOf(turn, user2, ai3), journal.entry(reply)?.operations)
    }

    @Test fun `completed entry is retained until change projection observation`() {
        val journal = SyncRemoteReplyJournal(File(folder.newFolder(), "journal.bin"))
        val op = operation("E0000000-0000-4000-8000-000000000017", 7)
        journal.prepare(reply, handle, "PHONE_SPACE", "local", listOf(op))
        journal.advance(reply, SyncRemoteReplyStage.COMPLETE)
        journal.observeProjection(reply, op.operationId)
        assertNull(journal.entry(reply))
    }
}
