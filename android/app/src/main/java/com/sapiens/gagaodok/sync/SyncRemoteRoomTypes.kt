package com.sapiens.gagaodok.sync

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
enum class SyncRemoteContinuationCapability { CHATBOT, UNSUPPORTED }

@Serializable
data class SyncRoomHandle(
    @SerialName("origin_space_id") val originSpaceId: String,
    @SerialName("room_id") val roomId: String,
)

@Serializable
data class SyncRemoteBubble(
    @SerialName("writer_space_id") val writerSpaceId: String,
    @SerialName("turn_id") val turnId: String,
    @SerialName("message_id") val messageId: String,
    @SerialName("bubble_order") val bubbleOrder: Long,
    val timestamp: String,
    val sender: String,
    val kind: String,
    val text: String,
    @SerialName("speaker_ref") val speakerRef: String? = null,
    val reactions: String? = null,
    /** 첨부 참조. 없으면 null이다. */
    @SerialName("attachment_id") val attachmentId: String? = null,
    /** 첨부의 서버 상태. SyncAttachmentDisplayState가 이것으로 화면 상태를 정한다. */
    @SerialName("attachment_state") val attachmentState: String? = null,
)

@Serializable
data class SyncRemoteRoomSnapshot(
    val handle: SyncRoomHandle,
    val title: String,
    @SerialName("writer_spaces") val writerSpaces: List<String>,
    val messages: List<SyncRemoteBubble>,
    @SerialName("content_hash") val contentHash: String,
    @SerialName("continuation_capability") val continuationCapability: SyncRemoteContinuationCapability? = null,
    /** 비어 있지 않으면 이어쓰기가 막힌다. 옛 projection에는 없다. */
    @SerialName("unsupported_reason") val unsupportedReason: String? = null,
)
