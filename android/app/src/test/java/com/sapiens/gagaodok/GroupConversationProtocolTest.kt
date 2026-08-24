package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.MessageKind
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.model.PersonaStyle
import com.sapiens.gagaodok.model.PersonaSampleEvidence
import com.sapiens.gagaodok.model.RoomProfile
import com.sapiens.gagaodok.service.GroupConversationProtocol
import com.sapiens.gagaodok.service.RoleplayParser
import com.sapiens.gagaodok.service.selectRuntimePersonaSamples
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class GroupConversationProtocolTest {
    private val firstId = UUID.fromString("11111111-1111-1111-1111-111111111111")
    private val secondId = UUID.fromString("22222222-2222-2222-2222-222222222222")
    private val foreignId = UUID.fromString("33333333-3333-3333-3333-333333333333")
    private val protocol = GroupConversationProtocol(listOf(room(firstId, "하나"), room(secondId, "둘")))

    @Test
    fun `표식 응답은 화자와 하트를 화면 문장으로 안전하게 변환한다`() {
        val raw = """
            "[[speaker:11111111-1111-1111-1111-111111111111]] 안녕."

            *둘 사이에 잠깐 정적이 흐른다.*

            "[[speaker:22222222-2222-2222-2222-222222222222]][[heart:22222222-2222-2222-2222-222222222222:+2]] 왜 불렀어?"
        """.trimIndent()
        val bubbles = raw.split("\n\n").map { RoleplayParser.classify(it, roleplayEstablished = true) }
        val first = protocol.parseBubble(bubbles[0].text, bubbles[0].kind, null)
        val narration = protocol.parseBubble(bubbles[1].text, bubbles[1].kind, first.speakerRoomId)
        val second = protocol.parseBubble(bubbles[2].text, bubbles[2].kind, narration.speakerRoomId)

        assertEquals(firstId, first.speakerRoomId)
        assertNull(narration.speakerRoomId)
        assertEquals(secondId, second.speakerRoomId)
        assertEquals("안녕.", first.visibleText)
        assertEquals("둘 사이에 잠깐 정적이 흐른다.", narration.visibleText)
        assertEquals("왜 불렀어?", second.visibleText)
        assertFalse(listOf(first, narration, second).any { it.visibleText.contains("[[") })
        assertEquals(mapOf(secondId to 2), protocol.heartDeltas(raw))
    }

    @Test
    fun `reaction-only participant stays invisible in text and attaches to target bubble`() {
        val parsed = protocol.parseBubble(
            "[[speaker:$firstId]] 반가워. [[react:$secondId:❤️]]",
            MessageKind.SPEECH,
            null
        )

        assertEquals("반가워.", parsed.visibleText)
        assertEquals(firstId, parsed.speakerRoomId)
        assertEquals(listOf(com.sapiens.gagaodok.service.PlannedReaction(secondId, "❤️")), parsed.reactions)
    }

    @Test
    fun `unmarked speech inherits and first speech falls back while foreign ids stay hidden`() {
        val inherited = protocol.parseBubble("계속 말할게.", MessageKind.SPEECH, secondId)
        val fallback = protocol.parseBubble("처음이야.", MessageKind.SPEECH, null)
        val foreign = protocol.parseBubble("[[speaker:$foreignId]][[heart:$foreignId:+9]] 숨겨.", MessageKind.SPEECH, firstId)

        assertEquals(secondId, inherited.speakerRoomId)
        assertEquals(firstId, fallback.speakerRoomId)
        assertEquals(firstId, foreign.speakerRoomId)
        assertEquals("숨겨.", foreign.visibleText)
        assertTrue(protocol.heartDeltas("[[heart:$foreignId:+9]]").isEmpty())
    }

    @Test
    fun `repeated allowed heart markers aggregate signed values`() {
        assertEquals(
            mapOf(firstId to -1, secondId to 3),
            protocol.heartDeltas("[[heart:$firstId:+2]][[heart:$firstId:-3]][[heart:$secondId:+3]]")
        )
    }

    @Test
    fun `heart changes are bounded per participant per turn`() {
        assertEquals(
            mapOf(firstId to 3, secondId to -3),
            protocol.heartDeltas("[[heart:$firstId:+99]][[heart:$secondId:-20]]")
        )
    }

    @Test
    fun `composite persona contains every participant and protocol even disabled styles`() {
        val persona = protocol.persona
        val prompt = persona.promptSection("단톡방", companionRepetitionControlEnabled = false).orEmpty()

        assertTrue(persona.isEnabled)
        assertTrue(prompt.contains(firstId.toString()))
        assertTrue(prompt.contains(secondId.toString()))
        assertTrue(prompt.contains("[[speaker:<ROOM_UUID>]]"))
        assertTrue(prompt.contains("[[heart:<ROOM_UUID>:+N|-N]]"))
        assertEquals(emptyList<String>(), persona.suppressedExpressions)
    }

    @Test
    fun `composite keeps style samples only from enabled participants`() {
        val enabled = room(firstId, "하나").copy(profile = RoomProfile(
            name = "하나",
            persona = PersonaStyle(styleGuide = "활성 규칙", samples = listOf("활성 예시"), isEnabled = true)
        ))
        val disabled = room(secondId, "둘").copy(profile = RoomProfile(
            name = "둘",
            persona = PersonaStyle(styleGuide = "비활성 규칙", samples = listOf("비활성 예시"), isEnabled = false)
        ))

        val persona = GroupConversationProtocol(listOf(enabled, disabled)).persona
        assertTrue(persona.styleGuide.contains("활성 규칙"))
        assertFalse(persona.styleGuide.contains("비활성 규칙"))
        assertEquals(listOf("하나 ($firstId): 활성 예시"), persona.samples)
    }

    @Test
    fun `group system prompt is plural and contains protocol without singular room persona wording`() {
        val prompt = protocol.systemPrompt("하나와 둘")

        assertTrue(prompt.startsWith(com.sapiens.gagaodok.model.ChatMode.COMPANION.stableSystemPrompt))
        assertTrue(prompt.contains(firstId.toString()))
        assertTrue(prompt.contains(secondId.toString()))
        assertTrue(prompt.contains("[[speaker:<ROOM_UUID>]]"))
        assertTrue(prompt.contains("모든 참여자"))
        assertTrue(prompt.contains("반응만"))
        assertTrue(prompt.contains("앞서 보낸 말"))
        assertFalse(prompt.contains("이 대화에서 당신의 이름은"))
        assertFalse(prompt.contains("는 아래 인물이다"))
    }

    @Test
    fun `suppressed expressions are unioned even when a style is disabled`() {
        val first = room(firstId, "하나").copy(profile = RoomProfile(
            name = "하나", persona = PersonaStyle(isEnabled = false, suppressedExpressions = listOf("반복"))
        ))
        val second = room(secondId, "둘").copy(profile = RoomProfile(
            name = "둘", persona = PersonaStyle(isEnabled = true, suppressedExpressions = listOf("반복", "금지"))
        ))
        assertEquals(listOf("반복", "금지"), GroupConversationProtocol(listOf(first, second)).persona.suppressedExpressions)
    }

    @Test
    fun `enabled samples use the runtime selector in both composite and prompt`() {
        val samples = (1..10).map { "선택 후보 $it" } + "선택 후보 1"
        val evidence = samples.map { PersonaSampleEvidence(text = it, sourceUrl = "https://example.com/$it") }
        val enabled = room(firstId, "하나").copy(profile = RoomProfile(
            name = "하나", persona = PersonaStyle(
                samples = samples, sampleEvidence = evidence, isEnabled = true
            )
        ))
        val disabled = room(secondId, "둘").copy(profile = RoomProfile(
            name = "둘", persona = PersonaStyle(samples = listOf("숨긴 비활성 예시"), isEnabled = false)
        ))
        val expected = selectRuntimePersonaSamples(samples, evidence)
        val protocol = GroupConversationProtocol(listOf(enabled, disabled))

        assertEquals(expected.map { "하나 ($firstId): $it" }, protocol.persona.samples)
        assertTrue(protocol.persona.samples.size <= 8)
        assertFalse(protocol.systemPrompt("테스트").contains("숨긴 비활성 예시"))
        expected.forEach { assertTrue(protocol.systemPrompt("테스트").contains(it)) }
        assertTrue(protocol.systemPrompt("테스트").contains("견본일 뿐"))
    }

    /// 응답이 오기 전에도 캐릭터 한 명이 입력 중으로 보여야 합니다. 그 한 명을 고르는 규칙입니다.
    @Test
    fun `첫 화자는 이름을 부른 사람, 없으면 직전 화자를 따른다`() {
        val history = listOf(
            ChatMessage(sender = MessageSender.SAPIENS, text = "먼저 말했어.", speakerRoomId = secondId),
            ChatMessage(sender = MessageSender.USER, text = "둘아, 이건 어때?")
        )

        // 1. 사용자가 이름을 부르면 그 사람이 답할 차례입니다.
        assertEquals(secondId, protocol.guessFirstSpeaker(history, "둘아, 이건 어때?"))
        assertEquals(firstId, protocol.guessFirstSpeaker(history, "하나야, 이건 어때?"))
        // 2. 이름이 없으면 직전에 말한 사람이 이어서 말한다고 봅니다.
        assertEquals(secondId, protocol.guessFirstSpeaker(history, "다들 어떻게 생각해?"))
        // 3. 그것도 없으면 첫 참여자입니다. 어떤 경우에도 참여자 중 한 명이어야 합니다.
        assertEquals(firstId, protocol.guessFirstSpeaker(emptyList(), "안녕?"))
    }

    /// 방을 나간 사람이 남긴 기록을 그대로 믿으면 참여자가 아닌 사람이 입력 중으로 뜹니다.
    @Test
    fun `참여자가 아닌 직전 화자는 추측에 쓰지 않는다`() {
        val history = listOf(
            ChatMessage(sender = MessageSender.SAPIENS, text = "지나간 사람.", speakerRoomId = foreignId)
        )

        assertEquals(firstId, protocol.guessFirstSpeaker(history, "다들 어때?"))
    }

    private fun room(id: UUID, name: String) = ChatRoom(
        id = id,
        profile = RoomProfile(
            name = name,
            persona = PersonaStyle(description = "$name 설명", samples = listOf("$name 예시"), isEnabled = false)
        )
    )
}
