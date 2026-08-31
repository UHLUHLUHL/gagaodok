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
    fun `표식은 이유까지 읽고 숫자만 오던 옛 형식도 그대로 읽는다`() {
        val withReason = PersonalAffectionProtocol.change("좋아. [[affection:+2:솔직하게 답해줘서]]")
        assertEquals(2, withReason.delta)
        assertEquals("솔직하게 답해줘서", withReason.reason)
        // 이유가 붙어도 화면에는 표식이 통째로 사라져야 합니다.
        assertEquals("좋아.", PersonalAffectionProtocol.visibleText("좋아. [[affection:+2:솔직하게 답해줘서]]"))

        val legacy = PersonalAffectionProtocol.change("좋아. [[affection:+1]]")
        assertEquals(1, legacy.delta)
        assertEquals("", legacy.reason)

        assertTrue(PersonalAffectionProtocol.change("표식 없음").isEmpty)
    }

    @Test
    fun `한 턴에 표식이 여럿이면 변화량은 더하고 이유는 처음 것을 쓴다`() {
        val change = PersonalAffectionProtocol.change(
            "[[affection:-2:약속을 어겨서]] 중간 [[affection:-2:또 다른 이유]]"
        )

        assertEquals(-3, change.delta)
        assertEquals("약속을 어겨서", change.reason)
    }

    @Test
    fun `이유는 화면 한 줄에 맞게 잘린다`() {
        val long = "가".repeat(40)
        assertEquals(24, PersonalAffectionProtocol.change("[[affection:+1:$long]]").reason.length)
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
