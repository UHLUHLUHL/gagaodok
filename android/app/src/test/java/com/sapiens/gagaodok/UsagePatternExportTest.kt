package com.sapiens.gagaodok

import com.sapiens.gagaodok.data.ModelTokenUsage
import com.sapiens.gagaodok.data.MeasurementLedger
import com.sapiens.gagaodok.data.MeasurementPolicy
import com.sapiens.gagaodok.data.MeasurementRequests
import com.sapiens.gagaodok.data.MeasurementRun
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.Codec
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.service.UsagePatternExport
import com.sapiens.gagaodok.service.buildUsagePatternExport
import com.sapiens.gagaodok.service.buildOptimizationExport
import kotlinx.serialization.decodeFromString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class UsagePatternExportTest {
    private val roomId = UUID.fromString("11111111-1111-1111-1111-111111111111")
    private val base = 1_700_000_000_000L

    @Test
    fun `내보낸 통계에는 대화 원문과 방 식별 정보와 절대 시각이 없다`() {
        val room = ChatRoom(
            id = roomId,
            title = "비밀 레제방",
            modeIdentifier = ChatMode.COMPANION.rawValue
        )
        val messages = listOf(
            message(MessageSender.USER, "절대 내보내면 안 되는 내 이야기", base),
            message(MessageSender.SAPIENS, "캐릭터의 비밀 답변", base + 10_000)
        )

        val json = buildUsagePatternExport(
            rooms = listOf(room),
            messagesByRoom = mapOf(roomId to messages),
            usageByRoom = emptyMap()
        )

        assertFalse(json.contains("절대 내보내면 안 되는 내 이야기"))
        assertFalse(json.contains("캐릭터의 비밀 답변"))
        assertFalse(json.contains("비밀 레제방"))
        assertFalse(json.contains(roomId.toString(), ignoreCase = true))
        assertFalse(json.contains(base.toString()))
        assertTrue(json.contains("room-1"))
    }

    @Test
    fun `5분 연속 사용 뒤 15분 안의 재사용 가능성을 세션별로 계산한다`() {
        val room = ChatRoom(id = roomId, modeIdentifier = ChatMode.COMPANION.rawValue)
        val userMinutes = listOf(0L, 4L, 8L, 40L, 44L)
        val messages = userMinutes.map { minute ->
            message(MessageSender.USER, "내용 $minute", base + minute * 60_000)
        }

        val export = Codec.json.decodeFromString<UsagePatternExport>(
            buildUsagePatternExport(listOf(room), mapOf(roomId to messages), emptyMap())
        )
        val stats = export.rooms.single()

        assertEquals(listOf(3, 2), stats.sessionUserTurns)
        assertEquals(2, stats.cacheTiming.eligibleWindows)
        assertEquals(1, stats.cacheTiming.windowsWithReuse)
        assertEquals(1, stats.cacheTiming.potentialHits)
        assertEquals(listOf(1, 0), stats.cacheTiming.hitCounts)
    }

    @Test
    fun `말풍선이 갈린 챗봇 답변은 한 논리 턴으로 센다`() {
        val turnId = UUID.fromString("22222222-2222-2222-2222-222222222222")
        val room = ChatRoom(id = roomId)
        val messages = listOf(
            message(MessageSender.USER, "질문", base),
            message(MessageSender.SAPIENS, "첫 말풍선", base + 1_000, turnId),
            message(MessageSender.SAPIENS, "둘째 말풍선", base + 2_000, turnId)
        )

        val export = Codec.json.decodeFromString<UsagePatternExport>(
            buildUsagePatternExport(listOf(room), mapOf(roomId to messages), emptyMap())
        )

        assertEquals(1, export.rooms.single().assistantTurns)
    }

    @Test
    fun `기존 사용량은 방 이름 없이 모델별 합계만 포함한다`() {
        val room = ChatRoom(id = roomId, title = "노출되면 안 되는 이름")
        val usage = ModelTokenUsage(
            inputTokens = 10_000,
            cachedInputTokens = 4_000,
            cacheCreateTokens = 5_000,
            outputTokens = 2_000,
            requestCount = 7,
            cacheStorageTokenHours = 1_250.0
        )

        val export = Codec.json.decodeFromString<UsagePatternExport>(
            buildUsagePatternExport(
                listOf(room),
                emptyMap(),
                mapOf(roomId to mapOf(AIModel.GEMINI_37_FLASH to usage))
            )
        )
        val model = export.rooms.single().models.single()

        assertEquals("gemini-3.7-flash", model.model)
        assertEquals(10_000, model.inputTokens)
        assertEquals(4_000, model.cachedInputTokens)
        assertEquals(5_000, model.cacheCreateTokens)
        assertEquals(7, model.requestCount)
    }

    @Test
    fun `v2 측정 내보내기는 회차 기간만 남기고 내부 시각과 방 키를 제거한다`() {
        val secretStart = 1_700_123_456_789L
        val room = ChatRoom(id = roomId, title = "내 비밀방", modeIdentifier = ChatMode.COMPANION.rawValue)
        val ledger = MeasurementLedger(completedRuns = listOf(
            MeasurementRun(
                id = 7,
                startedAtMillis = secretStart,
                endedAtMillis = secretStart + 5_000,
                policy = MeasurementPolicy.current(),
                requests = MeasurementRequests(requestCount = 3, inputTokens = 9_000),
                roomRequestCounts = mapOf(roomId.toString() to 3)
            )
        ))
        val json = buildOptimizationExport(
            rooms = listOf(room),
            messagesByRoom = mapOf(roomId to listOf(message(MessageSender.USER, "비밀 대화", secretStart + 1_000))),
            usageByRoom = emptyMap(),
            ledger = ledger,
            nowMillis = secretStart + 10_000
        )

        assertTrue(json.contains("\"schemaVersion\":2"))
        assertTrue(json.contains("\"durationMillis\":5000"))
        assertTrue(json.contains("\"run\":\"run-1\""))
        assertFalse(json.contains(secretStart.toString()))
        assertFalse(json.contains(roomId.toString(), ignoreCase = true))
        assertFalse(json.contains("내 비밀방"))
        assertFalse(json.contains("비밀 대화"))
    }

    private fun message(
        sender: MessageSender,
        text: String,
        timestamp: Long,
        turnId: UUID? = null
    ) = ChatMessage(sender = sender, text = text, timestamp = timestamp, turnId = turnId)
}
