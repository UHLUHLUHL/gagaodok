package com.sapiens.gagaodok

import com.sapiens.gagaodok.data.CacheDecision
import com.sapiens.gagaodok.data.CacheObservation
import com.sapiens.gagaodok.data.MeasurementPolicy
import com.sapiens.gagaodok.data.OptimizationMeasurementStore
import com.sapiens.gagaodok.data.PromptTokenBreakdown
import com.sapiens.gagaodok.data.RequestObservation
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import com.sapiens.gagaodok.service.PhoneMemoryObservation
import com.sapiens.gagaodok.service.PhoneMemoryOutcome
import org.junit.Assert.assertTrue
import org.junit.Test

class OptimizationMeasurementTest {
    @Test
    fun `completed runs survive restart and a new run does not replace them`() {
        val file = tempFile()
        var now = 1_000L
        val first = OptimizationMeasurementStore(file) { now }
        first.start(MeasurementPolicy.current())
        first.observeRequest(RequestObservation("room-a", 5_000, 4_100, 200, 100))
        now = 5_000L
        first.stop()

        val restored = OptimizationMeasurementStore(file) { now }
        assertEquals(1, restored.state.value.completedRuns.size)
        assertEquals(1, restored.state.value.completedRuns.single().requests.requestCount)
        restored.start(MeasurementPolicy.current())
        assertNotNull(restored.state.value.activeRun)
        assertEquals(1, restored.state.value.completedRuns.size)
    }

    @Test
    fun `기억 갱신 결과를 종류별로 세고 유료 실패를 따로 센다`() {
        val store = OptimizationMeasurementStore(tempFile()) { 1_000L }
        store.start(MeasurementPolicy.current())

        // 전환이 구조적으로 실패하는 상황입니다. 돈은 나가고 요약 범위는 그대로입니다.
        repeat(3) {
            store.observeMemory(memoryObservation(
                PhoneMemoryOutcome.MIGRATION_NOT_SMALLER,
                migration = true, before = 350, after = 350
            ))
        }
        // 재시도 대기 때문에 그냥 돌아온 것은 실패가 아닙니다.
        store.observeMemory(memoryObservation(
            PhoneMemoryOutcome.BACKOFF_SKIPPED, migration = false, before = 350, after = 350
        ))
        store.observeMemory(memoryObservation(
            PhoneMemoryOutcome.COMMITTED, migration = false, before = 350, after = 400
        ))

        val memory = store.state.value.activeRun!!.memory
        assertEquals(5, memory.attempts)
        assertEquals(4, memory.paidAttempts)
        assertEquals(1, memory.committed)
        assertEquals(50, memory.coverageAdvanced)
        assertEquals(400, memory.lastCommittedCoverage)
        assertEquals(3, memory.migrationAttempts)
        assertEquals(3, memory.maxConsecutivePaidFailures)
        assertEquals(3, memory.outcomeCounts[PhoneMemoryOutcome.MIGRATION_NOT_SMALLER])
        assertEquals(1, memory.outcomeCounts[PhoneMemoryOutcome.BACKOFF_SKIPPED])
    }

    @Test
    fun `돈만 쓰고 요약 범위가 제자리인 상태가 드러난다`() {
        // 이것이 이 계측을 넣은 이유입니다. 최근 원문이 큰 것이 원인이 아니라
        // 기억 갱신이 진전되지 않은 결과일 수 있습니다.
        val store = OptimizationMeasurementStore(tempFile()) { 1_000L }
        store.start(MeasurementPolicy.current())

        repeat(8) {
            store.observeMemory(memoryObservation(
                PhoneMemoryOutcome.NOT_STOP, migration = false, before = 200, after = 200
            ))
        }

        val memory = store.state.value.activeRun!!.memory
        assertEquals(8, memory.paidAttempts)
        assertEquals(0, memory.coverageAdvanced)
        assertEquals(0, memory.committed)
        assertEquals(8, memory.maxConsecutivePaidFailures)
    }

    @Test
    fun `종료 사유를 사유별로 세어 예산 부족과 다른 원인을 가른다`() {
        // `NOT_STOP`만 세면 8건이 출력 한도였는지 안전 필터였는지 알 수 없습니다.
        // 처방이 정반대라 이 구분 없이는 고칠 곳을 정할 수 없습니다.
        val store = OptimizationMeasurementStore(tempFile()) { 1_000L }
        store.start(MeasurementPolicy.current())

        repeat(6) {
            store.observeMemory(memoryObservation(
                PhoneMemoryOutcome.NOT_STOP, migration = false,
                before = 250, after = 250, failureDetail = "MAX_TOKENS"
            ))
        }
        store.observeMemory(memoryObservation(
            PhoneMemoryOutcome.NOT_STOP, migration = false,
            before = 250, after = 250, failureDetail = "SAFETY"
        ))
        // 사유가 없는 갈래는 집계를 어지럽히지 않습니다.
        store.observeMemory(memoryObservation(
            PhoneMemoryOutcome.COMMITTED, migration = false, before = 250, after = 300
        ))

        val memory = store.state.value.activeRun!!.memory
        assertEquals(6, memory.failureDetails["MAX_TOKENS"])
        assertEquals(1, memory.failureDetails["SAFETY"])
        assertEquals(2, memory.failureDetails.size)
    }

    @Test
    fun `해석 단계별 실패를 따로 세어 어디를 고칠지 가른다`() {
        val store = OptimizationMeasurementStore(tempFile()) { 1_000L }
        store.start(MeasurementPolicy.current())

        listOf(
            PhoneMemoryOutcome.PARSE_FAILED,
            PhoneMemoryOutcome.RANGE_MISMATCH,
            PhoneMemoryOutcome.SEGMENT_TOO_LONG,
            PhoneMemoryOutcome.STATE_REJECTED
        ).forEach {
            store.observeMemory(memoryObservation(it, migration = false, before = 250, after = 250))
        }

        val memory = store.state.value.activeRun!!.memory
        assertEquals(4, memory.attempts)
        // 넷 다 응답을 받은 뒤이므로 요금이 나갔습니다.
        assertEquals(4, memory.paidAttempts)
        assertEquals(0, memory.committed)
        assertEquals(4, memory.outcomeCounts.size)
    }

    private fun memoryObservation(
        outcome: PhoneMemoryOutcome,
        migration: Boolean,
        before: Int,
        after: Int,
        failureDetail: String? = null
    ) = PhoneMemoryObservation(
        outcome = outcome,
        migration = migration,
        coverageBefore = before,
        coverageAfter = after,
        targetThrough = after,
        segmentCount = if (migration) 7 else 1,
        retryAfterMillis = if (outcome.advancesCoverage || !outcome.paid) 0L else 900_000L,
        failureDetail = failureDetail
    )

    @Test
    fun `inactive measurement ignores observations`() {
        val store = OptimizationMeasurementStore(tempFile()) { 1_000L }
        store.observeRequest(RequestObservation("room-a", 5_000, 0, 200, 100))
        store.observeCache(CacheObservation("room-a", 5_000, CacheDecision.CREATE_SUCCESS, 4_800))
        assertNull(store.state.value.activeRun)
        assertTrue(store.state.value.completedRuns.isEmpty())
    }

    @Test
    fun `token histogram separates official and local cache thresholds`() {
        val store = OptimizationMeasurementStore(tempFile()) { 1_000L }
        store.start(MeasurementPolicy.current())
        listOf(4_095, 4_096, 4_599, 4_600, 8_192, 16_384).forEach {
            store.observeCache(CacheObservation("room-a", it, CacheDecision.BELOW_MINIMUM))
        }
        val histogram = store.state.value.activeRun!!.cache.prefixTokenBuckets
        assertEquals(listOf(1, 2, 1, 1, 1), histogram)
    }

    @Test
    fun `stopping freezes run and exporting state does not reactivate it`() {
        val store = OptimizationMeasurementStore(tempFile()) { 1_000L }
        assertTrue(store.start(MeasurementPolicy.current()))
        assertFalse(store.start(MeasurementPolicy.current()))
        assertNotNull(store.state.value.activeRun)
        store.stop()
        assertNull(store.state.value.activeRun)
        assertEquals(1, store.state.value.completedRuns.size)
    }

    @Test
    fun `cache attempt and result count one prefix sample`() {
        val store = OptimizationMeasurementStore(tempFile()) { 1_000L }
        store.start(MeasurementPolicy.current())
        store.observeCache(CacheObservation("room-a", 5_000, CacheDecision.CREATE_ATTEMPT))
        store.observeCache(CacheObservation("room-a", 5_000, CacheDecision.CREATE_SUCCESS, 4_900))

        val cache = store.state.value.activeRun!!.cache
        assertEquals(1, cache.prefixTokenBuckets.sum())
        assertEquals(1, cache.decisionCounts[CacheDecision.CREATE_ATTEMPT])
        assertEquals(1, cache.decisionCounts[CacheDecision.CREATE_SUCCESS])
    }

    @Test
    fun `request observations accumulate prompt component estimates`() {
        val store = OptimizationMeasurementStore(tempFile()) { 1_000L }
        store.start(MeasurementPolicy.current())
        store.observeRequest(RequestObservation(
            "room-a", 6_000, 4_500, 200, 6_100,
            prompt = PromptTokenBreakdown(700, 900, 600, 3_800, 100)
        ))

        assertEquals(PromptTokenBreakdown(700, 900, 600, 3_800, 100),
            store.state.value.activeRun!!.requests.prompt)
    }

    private fun tempFile(): File = Files.createTempDirectory("gagaodok-measurement").resolve("runs.json").toFile()
}