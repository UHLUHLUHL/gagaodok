package com.sapiens.gagaodok.sync

import com.sapiens.gagaodok.model.AIModel
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SyncRemoteReplyCoordinatorTest {
    @get:Rule val folder = TemporaryFolder()
    @Test fun `chatbot reply queues encrypted writer shard turn and two bubbles`() {
        val room = SyncRemoteRoomSnapshot(SyncRoomHandle("MAC_SPACE", "A0000000-0000-4000-8000-000000000001"), "합성", listOf("MAC_SPACE"), emptyList(), "x", SyncRemoteContinuationCapability.CHATBOT)
        val root = folder.newFolder()
        val outbox = SyncOutbox(File(root, "outbox.bin"))
        // journal은 이제 필수 인자다. "기록 먼저, 발송 나중"이 호출 규약이다.
        val journal = SyncRemoteReplyJournal(File(root, "remote-replies.bin"))
        SyncRemoteReplyCoordinator("A0000000-0000-4000-8000-000000000002", "A0000000-0000-4000-8000-000000000003", ByteArray(32) { 7 }, journal).prepare(room, "PHONE_SPACE", "질문", "답", AIModel.GEMINI_37_FLASH, outbox)
        assertEquals(4, outbox.pending().size)
    }

    @Test fun `reply is journaled before its encrypted operations are exposed to delivery`() {
        val room = SyncRemoteRoomSnapshot(SyncRoomHandle("MAC_SPACE", "A0000000-0000-4000-8000-000000000001"), "합성", listOf("MAC_SPACE"), emptyList(), "x", SyncRemoteContinuationCapability.CHATBOT)
        val directory = folder.newFolder()
        val outbox = SyncOutbox(File(directory, "outbox.bin"))
        val journal = SyncRemoteReplyJournal(File(directory, "remote-replies.bin"))
        val coordinator = SyncRemoteReplyCoordinator(
            "A0000000-0000-4000-8000-000000000002", "A0000000-0000-4000-8000-000000000003", ByteArray(32) { 7 }, journal,
        )
        val replyId = coordinator.prepare(room, "PHONE_SPACE", "질문", "답", AIModel.GEMINI_37_FLASH, outbox)
        val entry = journal.entry(replyId)!!
        assertEquals(4, entry.operations.size)
        assertEquals(outbox.pending().map { it.operationId }, entry.operations.map { it.operationId })
    }
}
