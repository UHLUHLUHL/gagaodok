package com.sapiens.gagaodok.sync

import com.sapiens.gagaodok.model.AIModel
import java.time.Instant
import java.util.UUID

/** Produces a durable, encrypted continuation; runtime delivery stays separate. */
class SyncRemoteReplyCoordinator(
    private val accountId: String,
    private val deviceId: String,
    private val masterKey: ByteArray,
    /**
     * journal은 선택이 아니다.
     *
     * "기록 먼저, 발송 나중"이 durable 계약인데 기본값이 있으면 그 계약이 호출
     * 규약이 아니라 관행이 된다. 새 호출부가 생기는 순간 조용히 깨진다.
     */
    private val journal: SyncRemoteReplyJournal,
) {
    fun prepare(room: SyncRemoteRoomSnapshot, writerSpaceId: String, userText: String, assistantText: String, model: AIModel, outbox: SyncOutbox): String {
        require(room.continuationCapability == SyncRemoteContinuationCapability.CHATBOT) { "unsupported room" }
        require(model == AIModel.GEMINI_37_FLASH) { "unsupported model" }
        val turn = UUID.randomUUID().toString().uppercase()
        val time = Instant.now().toString()
        val writer = SyncShadowWriter(accountId, deviceId, room.handle.originSpaceId, writerSpaceId, masterKey)
        val plan = writer.prepare(
            roomId = room.handle.roomId, title = room.title,
            bubbles = listOf(
                SyncShadowOutgoingBubble(UUID.randomUUID().toString().uppercase(), turn, "나", "speech", userText, time),
                SyncShadowOutgoingBubble(UUID.randomUUID().toString().uppercase(), turn, "사피엔스", "speech", assistantText, time),
            ),
            startingBubbleOrder = 1,
            includeRoom = writerSpaceId !in room.writerSpaces,
            continuationCapability = if (writerSpaceId !in room.writerSpaces) "chatbot" else null,
        )
        val replyId = UUID.randomUUID().toString().uppercase()
        journal.prepare(
            replyId, room.handle, writerSpaceId, userText,
            plan.operations.map { SyncRemoteReplyOperation(it.operationId, it.rawBody) },
        )
        plan.operations.forEach { outbox.enqueue(it.operationId, it.rawBody) }
        return replyId
    }
}
