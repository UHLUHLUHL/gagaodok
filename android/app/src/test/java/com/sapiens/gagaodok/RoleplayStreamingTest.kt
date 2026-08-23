package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.MessageKind
import com.sapiens.gagaodok.service.GeneratedMessageBubble
import com.sapiens.gagaodok.service.RoleplayParser
import com.sapiens.gagaodok.service.StreamBubbleSink
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RoleplayStreamingTest {
    @Test
    fun `새 상황극의 첫 묘사는 뒤따르는 따옴표 대사를 기다려 나레이션이 된다`() = runBlocking {
        val emitted = mutableListOf<GeneratedMessageBubble>()
        val sink = classificationSink(emitted)

        sink.consume("그가 잠시 시선을 피한다.\n\n")
        assertTrue(emitted.isEmpty())

        sink.consume("\"왜 그렇게 봐?\"")
        sink.finish()

        assertEquals(
            listOf(
                MessageKind.NARRATION to "그가 잠시 시선을 피한다.",
                MessageKind.SPEECH to "왜 그렇게 봐?"
            ),
            emitted.map { it.kind to it.text }
        )
    }

    @Test
    fun `일반 채팅의 첫 문단은 다음 문단이 평문으로 시작하면 바로 나온다`() = runBlocking {
        val emitted = mutableListOf<GeneratedMessageBubble>()
        val sink = classificationSink(emitted)

        sink.consume("오늘 뭐 했어?\n\n그냥 궁금해서")

        assertEquals(
            listOf(MessageKind.SPEECH to "오늘 뭐 했어?"),
            emitted.map { it.kind to it.text }
        )

        sink.finish()
        assertEquals(
            listOf(
                MessageKind.SPEECH to "오늘 뭐 했어?",
                MessageKind.SPEECH to "그냥 궁금해서"
            ),
            emitted.map { it.kind to it.text }
        )
    }

    private fun classificationSink(
        emitted: MutableList<GeneratedMessageBubble>,
        roleplayEstablished: Boolean = false
    ) = StreamBubbleSink(
        roleplayEstablished = roleplayEstablished,
        makeBubbles = { paragraph, roleplay ->
            val classified = RoleplayParser.classify(paragraph, roleplay)
            listOf(GeneratedMessageBubble(classified.text, kind = classified.kind))
        },
        onBubble = { emitted += it }
    )
}
