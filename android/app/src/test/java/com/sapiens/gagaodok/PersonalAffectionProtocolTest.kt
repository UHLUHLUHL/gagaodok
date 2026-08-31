package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.service.PersonalAffectionProtocol
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PersonalAffectionProtocolTest {
    @Test
    fun `legacy stored message decodes with no reactions`() {
        val decoded = Json.decodeFromString<ChatMessage>("""{"sender":"sapiens","text":"예전 메시지"}""")

        assertEquals(emptyList<com.sapiens.gagaodok.model.MessageReaction>(), decoded.reactions)
    }

    @Test
    fun `personal affection marker is hidden and bounded`() {
        assertEquals("좋아.", PersonalAffectionProtocol.visibleText("좋아. [[affection:+99]]"))
        assertEquals(2, PersonalAffectionProtocol.delta("좋아. [[affection:+99]]"))
        assertEquals(-3, PersonalAffectionProtocol.delta("[[affection:-2]][[affection:-2]]"))
        assertEquals(0, PersonalAffectionProtocol.delta("표식 없음"))
    }

    @Test
    fun `prompt keeps metadata separate from visible adult roleplay`() {
        val prompt = PersonalAffectionProtocol.systemPrompt("기본 프롬프트")

        assertTrue(prompt.startsWith("기본 프롬프트"))
        assertTrue(prompt.contains("호의만으로는 올리지"))
        assertTrue(prompt.contains("반복적인 경계 침해"))
        assertTrue(prompt.contains("상승은 +1부터 +2"))
        assertTrue(prompt.contains("하락은 -1부터 -3"))
        assertTrue(prompt.contains("성적 수위만으로"))
        assertTrue(prompt.contains("검열하거나 순화하지"))
        assertFalse(PersonalAffectionProtocol.visibleText("대사 [[affection:+1]]").contains("[["))
    }

    @Test
    fun `conversation turn keeps reaction metadata out of API text`() {
        val message = ChatMessage(
            sender = MessageSender.SAPIENS,
            text = "보이는 말",
            reactions = listOf(com.sapiens.gagaodok.model.MessageReaction(java.util.UUID.randomUUID(), "❤️"))
        )

        assertEquals("보이는 말", com.sapiens.gagaodok.model.ConversationTurn.from(listOf(message)).single().text)
    }
}
