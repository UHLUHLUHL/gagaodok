package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.Codec
import com.sapiens.gagaodok.model.MessageKind
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.service.ConversationCompactor
import com.sapiens.gagaodok.service.MathExpression
import com.sapiens.gagaodok.service.RoleplayParser
import com.sapiens.gagaodok.service.StreamingBubbleBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID
import kotlin.math.abs

class RoleplayParserTest {

    @Test
    fun `통째로 따옴표인 문단만 대사로 본다`() {
        assertEquals("이건 대사야", RoleplayParser.unwrappedDialogue("\"이건 대사야\""))
        assertEquals("이건 대사야", RoleplayParser.unwrappedDialogue("“이건 대사야”"))
        assertEquals("이건 대사야", RoleplayParser.unwrappedDialogue("「이건 대사야」"))
    }

    @Test
    fun `대사와 묘사가 섞인 문단은 대사가 아니다`() {
        // 이걸 대사로 넘기면 '하고 웃었다'까지 인물이 소리 내어 말한 것처럼 보입니다.
        assertNull(RoleplayParser.unwrappedDialogue("\"안녕\" 하고 웃었다"))
        assertNull(RoleplayParser.unwrappedDialogue("\"어\" 하고 답했다. \"왜?\""))
    }

    @Test
    fun `별표로 감싼 문단은 묘사다`() {
        assertEquals("고개를 든다", RoleplayParser.unwrappedEmphasis("*고개를 든다*"))
        assertEquals("고개를 든다", RoleplayParser.unwrappedEmphasis("_고개를 든다_"))
        assertNull(RoleplayParser.unwrappedEmphasis("보통 문단"))
    }

    @Test
    fun `상황극이 확인되기 전에는 따옴표 없는 문단을 묘사로 넘기지 않는다`() {
        // 평범한 잡담이 전부 묘사가 되어 버리는 것을 막는 안전장치입니다.
        val plain = RoleplayParser.classify("오늘 뭐 했어?", roleplayEstablished = false)
        assertEquals(MessageKind.SPEECH, plain.kind)

        val inRoleplay = RoleplayParser.classify("창밖으로 비가 내린다.", roleplayEstablished = true)
        assertEquals(MessageKind.NARRATION, inRoleplay.kind)
    }

    @Test
    fun `대사 말풍선에는 따옴표를 남기지 않는다`() {
        val result = RoleplayParser.classify("\"왔어?\"", roleplayEstablished = true)
        assertEquals("왔어?", result.text)
        assertEquals(MessageKind.SPEECH, result.kind)
    }

    @Test
    fun `앞 턴이 상황극이면 이어지는 턴도 상황극으로 본다`() {
        val turn = UUID.randomUUID()
        val messages = listOf(
            ChatMessage(sender = MessageSender.USER, text = "안녕"),
            ChatMessage(sender = MessageSender.SAPIENS, text = "문을 연다", turnId = turn, kind = MessageKind.NARRATION),
            ChatMessage(sender = MessageSender.SAPIENS, text = "왔어?", turnId = turn, kind = MessageKind.SPEECH)
        )
        assertTrue(RoleplayParser.roleplayInProgress(messages))
    }

    @Test
    fun `대사만 있던 턴 뒤에는 상황극으로 보지 않는다`() {
        val turn = UUID.randomUUID()
        val messages = listOf(
            ChatMessage(sender = MessageSender.USER, text = "안녕"),
            ChatMessage(sender = MessageSender.SAPIENS, text = "응 왜", turnId = turn, kind = MessageKind.SPEECH)
        )
        assertFalse(RoleplayParser.roleplayInProgress(messages))
    }
}

class StreamingBubbleBufferTest {

    @Test
    fun `완성된 문단만 내보낸다`() {
        val buffer = StreamingBubbleBuffer()
        assertEquals(emptyList<String>(), buffer.append("첫 문단"))
        assertEquals(listOf("첫 문단"), buffer.append("\n\n둘째"))
        assertEquals("둘째", buffer.flush())
    }

    @Test
    fun `수식이 열려 있는 동안에는 자르지 않는다`() {
        val buffer = StreamingBubbleBuffer()
        // $$가 열린 채로 빈 줄이 나와도 여기서 끊으면 깨진 수식이 화면에 보입니다.
        assertEquals(emptyList<String>(), buffer.append("$$\\frac{1}\n\n{2}$$"))
        assertEquals(listOf("$$\\frac{1}\n\n{2}$$"), buffer.append("\n\n다음"))
    }

    @Test
    fun `코드 블록 안의 달러는 수식으로 세지 않는다`() {
        assertTrue(StreamingBubbleBuffer.isBalanced("```\ncost=\$5\n```"))
    }

    @Test
    fun `이스케이프한 달러는 수식이 아니다`() {
        assertTrue(StreamingBubbleBuffer.isBalanced("가격은 \\\$5입니다"))
    }

    @Test
    fun `그래프 태그가 닫히기 전에는 자르지 않는다`() {
        assertFalse(StreamingBubbleBuffer.isBalanced("[GRAPH: type=cartesian, func=sin(x)"))
        assertTrue(StreamingBubbleBuffer.isBalanced("[GRAPH: type=cartesian, func=sin(x)]"))
    }
}

class MathExpressionTest {

    private fun eval(source: String, x: Double): Double? =
        MathExpression.parse(source)?.value(mapOf("x" to x))

    @Test
    fun `계수를 무시하지 않는다`() {
        // 예전 평가기가 놓치던 지점입니다. 2*sin(x)를 sin(x)로 그렸습니다.
        val v = eval("2*sin(x)", Math.PI / 2)!!
        assertTrue(abs(v - 2.0) < 1e-9)
    }

    @Test
    fun `곱셈 기호를 생략해도 읽는다`() {
        assertEquals(6.0, eval("2x", 3.0)!!, 1e-9)
        assertEquals(8.0, eval("2(x+1)", 3.0)!!, 1e-9)
    }

    @Test
    fun `단항 마이너스는 거듭제곱보다 느슨하게 묶인다`() {
        assertEquals(-9.0, eval("-x^2", 3.0)!!, 1e-9)
    }

    @Test
    fun `거듭제곱은 오른쪽 결합이다`() {
        assertEquals(512.0, MathExpression.parse("2^3^2")!!.value(emptyMap())!!, 1e-9)
    }

    @Test
    fun `정의역을 벗어나면 값이 없다`() {
        assertNull(eval("ln(x)", -1.0))
        assertNull(eval("sqrt(x)", -1.0))
        assertNull(eval("1/x", 0.0))
    }

    @Test
    fun `해석하지 못한 식은 그리지 않는다`() {
        // 조용히 y = x 로 그리던 예전 동작을 되살리지 않기 위한 시험입니다.
        assertNull(MathExpression.parse("sin(x"))
        assertNull(MathExpression.parse("foo(x)"))
        assertNull(MathExpression.parse("2 +"))
    }

    @Test
    fun `상수를 안다`() {
        assertEquals(0.0, MathExpression.parse("sin(pi)")!!.value(emptyMap())!!, 1e-9)
    }
}

class CodecTest {

    @Test
    fun `날짜는 스위프트 기준시로 오간다`() {
        // 유닉스 초로 잘못 쓰면 31년이 어긋납니다. 실제 파일 호환이 여기 달려 있습니다.
        val millis = 1_755_000_000_000L
        val swift = Codec.epochMillisToSwiftTime(millis)
        assertEquals(millis, Codec.swiftTimeToEpochMillis(swift))
        assertEquals(millis / 1000.0 - 978_307_200.0, swift, 1e-6)
    }

    @Test
    fun `맥 판이 쓴 메시지 JSON을 그대로 읽는다`() {
        val json = """
        [{"id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","sender":"sapiens",
          "text":"안녕하세요","timestamp":776774400.0,"isUnread":false,
          "deliveryFailed":false,"kind":"narration"}]
        """.trimIndent()
        val messages = Codec.json.decodeFromString<List<ChatMessage>>(json)
        assertEquals(1, messages.size)
        assertEquals(MessageSender.SAPIENS, messages[0].sender)
        assertEquals(MessageKind.NARRATION, messages[0].kind)
        assertEquals("안녕하세요", messages[0].text)
    }

    @Test
    fun `kind 가 없는 옛 기록은 대사로 읽는다`() {
        val json = """
        [{"id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","sender":"user",
          "text":"안녕","timestamp":776774400.0}]
        """.trimIndent()
        val messages = Codec.json.decodeFromString<List<ChatMessage>>(json)
        assertEquals(MessageKind.SPEECH, messages[0].kind)
    }
}

class ConversationCompactorTest {

    private fun conversation(turns: Int) = buildList {
        repeat(turns) {
            add(com.sapiens.gagaodok.model.ConversationTurn(UUID.randomUUID(), MessageSender.USER, "질문 $it"))
            add(com.sapiens.gagaodok.model.ConversationTurn(UUID.randomUUID(), MessageSender.SAPIENS, "답변 $it"))
        }
    }

    @Test
    fun `문턱을 넘기 전에는 전부 원문으로 보낸다`() {
        val convo = conversation(10)
        val plan = ConversationCompactor.plan(convo, null, ChatMode.MATH_MENTOR)
        assertNull(plan.digestText)
        assertEquals(convo.size, plan.verbatimTurns.size)
        assertNull(plan.pending)
    }

    @Test
    fun `문턱을 넘으면 요약할 구간을 잡는다`() {
        val convo = conversation(ConversationCompactor.THRESHOLD_TURNS)
        val plan = ConversationCompactor.plan(convo, null, ChatMode.MATH_MENTOR)
        assertNotNull(plan.pending)
        assertEquals(1, plan.pending!!.firstTurn)
        assertEquals(ConversationCompactor.REFRESH_PERIOD_TURNS, plan.pending!!.lastTurn)
    }

    @Test
    fun `턴 번호를 붙여서 넘긴다`() {
        // 번호 없이 넘겼더니 모델이 줄 수를 세어 없는 번호를 지어냈습니다.
        val text = ConversationCompactor.transcript(conversation(2), startingTurn = 5, mode = ChatMode.MATH_MENTOR)
        assertTrue(text.startsWith("[5턴] 학습자: 질문 0"))
        assertTrue(text.contains("[6턴] 학습자: 질문 1"))
    }

    @Test
    fun `오류 메시지는 요약에 넣지 않는다`() {
        val turns = listOf(
            com.sapiens.gagaodok.model.ConversationTurn(UUID.randomUUID(), MessageSender.USER, "안녕"),
            com.sapiens.gagaodok.model.ConversationTurn(
                UUID.randomUUID(), MessageSender.SAPIENS, "요청을 처리하는 중 오류가 발생했습니다: 타임아웃"
            )
        )
        val text = ConversationCompactor.transcript(turns, startingTurn = 1, mode = ChatMode.MATH_MENTOR)
        assertFalse(text.contains("오류가 발생했습니다"))
    }
}
