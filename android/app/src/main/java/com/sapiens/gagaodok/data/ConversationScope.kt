package com.sapiens.gagaodok.data

import java.util.UUID

data class ConversationScope(
    val roomId: UUID,
    val worldlineId: UUID? = null
) {
    private val roomToken get() = roomId.toString().uppercase()
    private val worldlineToken get() = worldlineId?.toString()?.uppercase()

    val messageFileName: String
        get() = worldlineToken?.let { "room_${roomToken}_worldline_${it}_messages.json" }
            ?: "room_${roomToken}_messages.json"

    val digestFileName: String
        get() = worldlineToken?.let { "room_${roomToken}_worldline_${it}_digest.json" }
            ?: "room_${roomToken}_digest.json"

    val aiConversationId: UUID
        get() = worldlineId ?: roomId
}
