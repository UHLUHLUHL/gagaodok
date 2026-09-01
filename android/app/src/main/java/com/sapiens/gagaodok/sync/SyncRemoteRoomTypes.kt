package com.sapiens.gagaodok.sync

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

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
)

@Serializable
data class SyncRemoteRoomSnapshot(
    val handle: SyncRoomHandle,
    val title: String,
    @SerialName("writer_spaces") val writerSpaces: List<String>,
    val messages: List<SyncRemoteBubble>,
    @SerialName("content_hash") val contentHash: String,
)
