package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.Codec
import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.model.PersonaStyle
import com.sapiens.gagaodok.service.ANALYZE_INSTRUCTION
import com.sapiens.gagaodok.service.RepetitionAdvice
import com.sapiens.gagaodok.service.repetitionAdvice
import com.sapiens.gagaodok.service.withRepetitionGuidance
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CompanionPersonaGuidanceTest {

    @Test
    fun `챗봇 말투는 대표 문구보다 구조와 빈도 구분을 우선한다`() {
        val prompt = PersonaStyle(
            description = "레제",
            samples = listOf(
                "덴지 군은 말이야, 오늘은 괜찮아.",
                "덴지 군은 말이야, 오늘은 괜찮아.",
                "알겠어."
            ),
            styleGuide = "- 문장 구조: 짧게 끊는다",
            isEnabled = true
        ).promptSection("레제", ChatMode.COMPANION).orEmpty()

        assertTrue(prompt.contains("문장 구조"))
        assertTrue(prompt.contains("항상"))
        assertTrue(prompt.contains("가끔"))
        assertTrue(prompt.contains("그대로 복사하지 않는다"))
        assertEquals(1, prompt.lines().count { it == "- 덴지 군은 말이야, 오늘은 괜찮아." })
    }

    @Test
    fun `말투 분석 지침은 표본 중복과 빈도를 명시한다`() {
        assertTrue(ANALYZE_INSTRUCTION.contains("항상"))
        assertTrue(ANALYZE_INSTRUCTION.contains("자주"))
        assertTrue(ANALYZE_INSTRUCTION.contains("가끔"))
        assertTrue(ANALYZE_INSTRUCTION.contains("드물게"))
        assertTrue(ANALYZE_INSTRUCTION.contains("중복"))
    }

    @Test
    fun `반복 제어 지침은 억제 표현을 요청 가변 영역으로 만든다`() {
        val advice = repetitionAdvice(listOf("덴지 군은 말이야, 오늘은 피곤해.", "덴지 군은 말이야, 그래도 왔어."))
        val prompt = advice.promptSection()

        assertNotNull(prompt)
        assertTrue(prompt!!.contains("덴지 군은 말이야"))
        assertTrue(prompt.contains("이번 답변"))
    }

    @Test
    fun `최근 챗봇 답변의 같은 시작 표현만 이번 요청에서 피한다`() {
        val advice = advice(
            listOf(
                "덴지 군은 말이야, 오늘은 좀 피곤해.",
                "그건 그렇고 점심은 먹었어?",
                "덴지 군은 말이야, 네가 걱정돼.",
                "그래도 네 옆에 있을게."
            )
        )

        assertTrue(advice.phrases.contains("덴지 군은 말이야"))
        assertFalse(advice.phrases.contains("그건 그렇고"))
    }

    @Test
    fun `한 번만 나온 표현은 억제하지 않는다`() {
        val advice = advice(listOf("응", "그래", "오늘은 괜찮아.", "정말 괜찮아."))

        assertFalse(advice.phrases.contains("응"))
    }

    @Test
    fun `짧은 시작어도 최근 답변에서 반복되면 억제한다`() {
        val advice = advice(listOf("응", "오늘은 바빴어.", "응", "그래도 괜찮아."))

        assertTrue(advice.phrases.contains("응"))
    }

    @Test
    fun `사용자가 직접 저장한 표현은 최근 반복이 없어도 포함한다`() {
        val advice = advice(
            listOf("오늘은 조용하네."),
            explicit = listOf("덴지 군은 말이야", "덴지 군은 말이야")
        )

        assertEquals(listOf("덴지 군은 말이야"), advice.phrases)
    }

    private fun advice(answers: List<String>, explicit: List<String> = emptyList()): RepetitionAdvice {
        return repetitionAdvice(answers, explicit)
    }

    @Test
    fun `동적 지침은 원래 대화나 저장할 메시지를 바꾸지 않는다`() {
        val original = listOf(
            ConversationTurn(java.util.UUID.randomUUID(), MessageSender.USER, "오늘 어땠어?"),
            ConversationTurn(java.util.UUID.randomUUID(), MessageSender.SAPIENS, "그냥 그랬어.")
        )
        val guided = original.withRepetitionGuidance(RepetitionAdvice(listOf("덴지 군은 말이야")))

        assertTrue(guided.first().text.contains("덴지 군은 말이야"))
        assertTrue(guided.first().text.contains("오늘 어땠어?"))
        assertTrue(original.last().text == "그냥 그랬어.")
    }

    @Test
    fun `기존 말투 JSON은 새 방별 억제 목록을 빈 목록으로 읽는다`() {
        val oldJson = """
            {"description":"레제","samples":["안녕"],"styleGuide":"- 문장 끝맺음: 반말","isEnabled":true}
        """.trimIndent()

        val persona = Codec.json.decodeFromString<PersonaStyle>(oldJson)

        assertTrue(persona.isEnabled)
        assertTrue(persona.suppressedExpressions.isEmpty())
        assertTrue(Codec.json.encodeToString(persona).contains("suppressedExpressions"))
    }

    @Test
    fun `멘토 모드의 기존 말투 지침은 챗봇 보정 문구를 받지 않는다`() {
        val prompt = PersonaStyle(
            samples = listOf("정답은 2입니다."),
            isEnabled = true
        ).promptSection("사피엔스", ChatMode.MATH_MENTOR).orEmpty()

        assertFalse(prompt.contains("이번 답변의 변주"))
        assertFalse(prompt.contains("항상 쓰지 말고"))
    }
}
