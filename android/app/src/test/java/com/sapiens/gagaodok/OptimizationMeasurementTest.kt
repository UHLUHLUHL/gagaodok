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
