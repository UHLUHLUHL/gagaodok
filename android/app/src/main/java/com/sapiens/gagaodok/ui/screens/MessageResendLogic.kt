package com.sapiens.gagaodok.ui.screens

import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.MessageSender
import java.util.UUID

internal enum class MessageUserAction { EDIT, RESEND, NONE }

internal object MessageResendLogic {
    fun actionFor(message: ChatMessage): MessageUserAction = when {
        message.sender != MessageSender.USER -> MessageUserAction.NONE
        message.text.isNotBlank() -> MessageUserAction.EDIT
        message.attachment != null -> MessageUserAction.RESEND
        else -> MessageUserAction.NONE
    }

    fun truncateFrom(
        messages: List<ChatMessage>,
        messageId: UUID,
        replacementText: String?
    ): List<ChatMessage> {
        val index = messages.indexOfFirst { it.id == messageId }
        if (index < 0) return messages
        val truncated = messages.take(index + 1).toMutableList()
        val original = truncated[index]
        val replacement = replacementText?.trim()
        truncated[index] = if (replacement == null) {
            original.copy(deliveryFailed = false)
        } else {
            original.copy(
                text = replacement,
                canonicalText = replacement,
                deliveryFailed = false
            )
        }
        return truncated
    }
}
