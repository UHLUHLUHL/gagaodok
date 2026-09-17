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

    private fun chat(
        input: Int, cached: Int, sentAt: Long?, explicit: Boolean? = null,
        model: String? = "gemini-3.8-flash"
    ) = RequestObservation(
        roomKey = "room-a", inputTokens = input, cachedInputTokens = cached, outputTokens = 50,
        estimatedPromptTokens = input, sentAtMillis = sentAt, explicitCache = explicit,
        model = model
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
    fun `한 회차에서 모델별로 나눠 센다`() {
        val s = store()
        s.observeRequest(chat(27_000, 24_000, sentAt = 1L, explicit = true))
        s.observeRequest(chat(20_000, 19_000, sentAt = 2L, explicit = false, model = "deepseek-flash"))
        s.observeRequest(chat(21_000, 20_000, sentAt = 3L, explicit = false, model = "deepseek-flash"))
        val run = s.state.value.activeRun!!
        assertEquals(listOf("gemini-3.8-flash", "deepseek-flash", "deepseek-flash"), run.requestLog.map { it.model })
        assertEquals(1, run.byModel["gemini-3.8-flash"]!!.requests.requestCount)
        assertEquals(24_000L, run.byModel["gemini-3.8-flash"]!!.requests.cachedInputTokens)
        val deepSeek = run.byModel["deepseek-flash"]!!
        assertEquals(2, deepSeek.requests.requestCount)
        assertEquals(39_000L, deepSeek.requests.cachedInputTokens)
        assertEquals(2, deepSeek.requestsByWorkload[MeasurementWorkload.CHAT]!!.requestCount)
        // 기존 합계는 Gemini만 센다. 진행 중인 Gemini 회차를 앞 회차와 견줄 수 있어야 한다.
        assertEquals(1, run.requests.requestCount)
        assertEquals(24_000L, run.requests.cachedInputTokens)
        assertEquals(1, run.requestsByWorkload[MeasurementWorkload.CHAT]!!.requestCount)
        assertEquals(mapOf("room-a" to 1), run.roomRequestCounts)
    }

    @Test
    fun `모델을 모르는 요청은 Gemini 합계에만 들어간다`() {
        val s = store()
        s.observeRequest(chat(1, 0, sentAt = 1L, model = null))
        val run = s.state.value.activeRun!!
        assertNull(run.requestLog.single().model)
        assertTrue(run.byModel.isEmpty())
        assertEquals(1, run.requests.requestCount)
    }

    @Test
    fun `모델 칸이 없는 진행 중 장부를 읽고 이어 적어도 옛 줄이 남는다`() {
        // 10회차처럼 모델 칸이 생기기 전에 시작된 회차입니다.
        val file = File.createTempFile("old-model-log", ".json")
        file.writeText(
            """{"activeRun":{"id":10,"startedAtMillis":1,"policy":{},""" +
                """"requests":{"requestCount":1},""" +
                """"requestLog":[{"atMillis":5,"roomKey":"room-a","inputTokens":9,"explicitCache":true}]}}"""
        )
        val s = OptimizationMeasurementStore(file) { now }
        val before = s.state.value.activeRun!!
        assertNull("옛 줄의 모델은 모름", before.requestLog.single().model)
        assertTrue(before.byModel.isEmpty())

        s.observeRequest(chat(2, 0, sentAt = 6L, model = "deepseek-flash"))
        val reloaded = OptimizationMeasurementStore(file) { now }.state.value.activeRun!!
        assertEquals(10, reloaded.id)
        assertEquals(listOf(null, "deepseek-flash"), reloaded.requestLog.map { it.model })
        assertEquals(9, reloaded.requestLog.first().inputTokens)
        assertEquals("DeepSeek는 기존 합계에 더하지 않는다", 1, reloaded.requests.requestCount)
        assertEquals(1, reloaded.byModel["deepseek-flash"]!!.requests.requestCount)
    }

    @Test
    fun `모르는 모델은 파일에 칸을 만들지 않는다`() {
        val file = File.createTempFile("null-model-log", ".json")
        store(file).observeRequest(chat(1, 0, sentAt = 1L, model = null))
        val text = file.readText()
        assertTrue(text.contains("\"requestLog\""))
        assertTrue("null은 쓰지 않는다(맥과 같은 모양)", !text.contains("\"model\""))
    }

    @Test
    fun `측정 중이 아니면 남기지 않는다`() {
        val file = File.createTempFile("idle-log", ".json")
        val s = OptimizationMeasurementStore(file) { now }
        s.observeRequest(chat(1, 0, sentAt = 1L))
        assertNull(s.state.value.activeRun)
    }
}
