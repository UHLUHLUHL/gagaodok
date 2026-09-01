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
        val outbox = SyncOutbox(File(folder.newFolder(), "outbox.bin"))
        SyncRemoteReplyCoordinator("A0000000-0000-4000-8000-000000000002", "A0000000-0000-4000-8000-000000000003", ByteArray(32) { 7 }).prepare(room, "PHONE_SPACE", "질문", "답", AIModel.GEMINI_37_FLASH, outbox)
        assertEquals(4, outbox.pending().size)
    }
}
