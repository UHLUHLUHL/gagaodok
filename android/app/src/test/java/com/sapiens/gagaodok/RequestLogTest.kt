package com.sapiens.gagaodok

import com.sapiens.gagaodok.data.MeasurementPolicy
import com.sapiens.gagaodok.data.MeasurementWorkload
import com.sapiens.gagaodok.data.OptimizationMeasurementStore
import com.sapiens.gagaodok.data.RequestObservation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/// 요청마다 시각과 토큰을 한 줄씩 남기는 기록입니다.
///
/// 간격을 구간으로만 세면 요청의 **순서**가 사라집니다. 캐시 수명은 마지막 요청이 아니라
/// 캐시를 만든 시각부터 흐르므로, 어떤 TTL이 싼지는 실제 순서를 다시 돌려 봐야 알 수 있습니다.
class RequestLogTest {

    private var now = 1_000_000L
    private fun store(file: File = File.createTempFile("request-log", ".json"), limit: Int = 100) =
        OptimizationMeasurementStore(file, limit) { now }.also { it.start(MeasurementPolicy.current()) }

    private fun chat(input: Int, cached: Int, sentAt: Long?, explicit: Boolean? = null) = RequestObservation(
        roomKey = "room-a", inputTokens = input, cachedInputTokens = cached, outputTokens = 50,
        estimatedPromptTokens = input, sentAtMillis = sentAt, explicitCache = explicit
    )

    @Test
    fun `요청마다 보낸 시각과 토큰을 순서대로 남긴다`() {
        val s = store()
        s.observeRequest(chat(27_000, 0, sentAt = 100L, explicit = false))
        s.observeRequest(chat(27_500, 24_000, sentAt = 200L, explicit = true))
        val log = s.state.value.activeRun!!.requestLog
        assertEquals(listOf(100L, 200L), log.map { it.atMillis })
        assertEquals(listOf(0, 24_000), log.map { it.cachedInputTokens })
        assertEquals(27_500, log[1].inputTokens)
        assertEquals(50, log[1].outputTokens)
        assertEquals("room-a", log[1].roomKey)
        assertEquals(true, log[1].explicitCache)
        assertEquals(MeasurementWorkload.CHAT, log[1].workload)
    }

    @Test
    fun `보낸 시각을 모르면 기록하는 시각을 쓴다`() {
        now = 5_000L
        val s = store()
        s.observeRequest(chat(1, 0, sentAt = null))
        val entry = s.state.value.activeRun!!.requestLog.single()
        assertEquals(5_000L, entry.atMillis)
        assertNull("붙였는지 모르면 모른다고 둔다", entry.explicitCache)
    }

    @Test
    fun `기억 요청도 같은 줄에 남아 요약 시점을 알 수 있다`() {
        val s = store()
        s.observeRequest(chat(1, 0, sentAt = 1L).copy(workload = MeasurementWorkload.MEMORY))
        assertEquals(MeasurementWorkload.MEMORY, s.state.value.activeRun!!.requestLog.single().workload)
    }

    @Test
    fun `응답 숫자를 못 받은 요청도 시각은 남긴다`() {
        val s = store()
        s.observeRequest(chat(0, 0, sentAt = 7L).copy(unreported = true))
        val entry = s.state.value.activeRun!!.requestLog.single()
        assertTrue(entry.unreported)
        assertEquals(7L, entry.atMillis)
    }

    @Test
    fun `상한을 넘으면 오래된 줄부터 버리고 버린 수를 센다`() {
        val s = store(limit = 5)
        repeat(5 + 3) { s.observeRequest(chat(1, 0, sentAt = it.toLong())) }
        val run = s.state.value.activeRun!!
        assertEquals(5, run.requestLog.size)
        assertEquals(3L, run.requestLog.first().atMillis)
        assertEquals(3, run.requestLogDropped)
        assertEquals("합계는 버린 줄까지 센다", 8, run.requests.requestCount)
    }

    @Test
    fun `다시 읽어도 기록이 그대로다`() {
        val file = File.createTempFile("request-log-reload", ".json")
        store(file).observeRequest(chat(27_000, 24_000, sentAt = 42L, explicit = true))
        val reloaded = OptimizationMeasurementStore(file) { now }.state.value.activeRun!!.requestLog.single()
        assertEquals(42L, reloaded.atMillis)
        assertEquals(24_000, reloaded.cachedInputTokens)
        assertEquals(true, reloaded.explicitCache)
    }

    @Test
    fun `기록 칸이 없는 옛 파일도 읽는다`() {
        val file = File.createTempFile("old-log", ".json")
        file.writeText("""{"activeRun":{"id":10,"startedAtMillis":1,"policy":{}}}""")
        val run = OptimizationMeasurementStore(file) { 1L }.state.value.activeRun!!
        assertTrue(run.requestLog.isEmpty())
        assertEquals(0, run.requestLogDropped)
    }

    @Test
    fun `측정 중이 아니면 남기지 않는다`() {
        val file = File.createTempFile("idle-log", ".json")
        val s = OptimizationMeasurementStore(file) { now }
        s.observeRequest(chat(1, 0, sentAt = 1L))
        assertNull(s.state.value.activeRun)
    }
}
