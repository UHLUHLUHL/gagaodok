package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.model.Codec
import com.sapiens.gagaodok.ui.screens.ConversationBinding
import com.sapiens.gagaodok.ui.screens.GroupResponseBuffer
import kotlinx.serialization.decodeFromString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class ConversationTurnTest {
    @Test
    fun `same AI turn merges different speakers and preserves canonical text once`() {
        val turnId = UUID.randomUUID()
        val firstSpeaker = UUID.randomUUID()
        val secondSpeaker = UUID.randomUUID()
        val messages = listOf(
            ChatMessage(sender = MessageSender.SAPIENS, text = "안녕", turnId = turnId, canonicalText = "원문 [[speaker:$firstSpeaker]]", speakerRoomId = firstSpeaker),
            ChatMessage(sender = MessageSender.SAPIENS, text = "왜 불렀어?", turnId = turnId, speakerRoomId = secondSpeaker)
        )

        assertEquals(listOf("원문 [[speaker:$firstSpeaker]]"), ConversationTurn.from(messages).map { it.text })
    }

    @Test
    fun `personal messages keep a null speaker by default`() {
        assertNull(ChatMessage(sender = MessageSender.SAPIENS, text = "개인방").speakerRoomId)
    }

    @Test
    fun `legacy JSON without speaker decodes as null`() {
        val message = Codec.json.decodeFromString<ChatMessage>("""{"sender":"sapiens","text":"기록"}""")
        assertNull(message.speakerRoomId)
    }

    @Test
    fun `captured conversation binding rejects a later room or worldline`() {
        val roomId = UUID.randomUUID()
        val worldlineId = UUID.randomUUID()
        val binding = ConversationBinding(roomId, worldlineId)

        assertEquals(true, binding.matches(roomId, worldlineId))
        assertEquals(false, binding.matches(roomId, UUID.randomUUID()))
        assertEquals(false, binding.matches(UUID.randomUUID(), worldlineId))
    }

    @Test
    fun `group response buffer owns its request snapshot`() {
        val history = listOf(ChatMessage(sender = MessageSender.USER, text = "A"))
        val buffer = GroupResponseBuffer(history)
        buffer.append(ChatMessage(sender = MessageSender.SAPIENS, text = "A 응답"))

        assertEquals(listOf("A", "A 응답"), buffer.messages.map { it.text })
        assertEquals(listOf("A"), history.map { it.text })
    }

    @Test
    fun `partial group response preserves raw speaker markers when stream stops`() {
        val turnId = UUID.randomUUID()
        val buffer = GroupResponseBuffer(emptyList())
        buffer.append(ChatMessage(sender = MessageSender.SAPIENS, text = "보이는 대사", turnId = turnId))
        val raw = "[[speaker:${UUID.randomUUID()}]] 보이는 대사"

        assertTrue(buffer.preserveCanonical(turnId, raw))

        assertEquals(raw, buffer.messages.single().canonicalText)
        assertEquals(listOf(raw), ConversationTurn.from(buffer.messages).map { it.text })
    }
}
