package com.sapiens.gagaodok

import com.sapiens.gagaodok.data.CacheCreateReason
import com.sapiens.gagaodok.data.CacheDecision
import com.sapiens.gagaodok.data.CacheDropReason
import com.sapiens.gagaodok.data.CacheObservation
import com.sapiens.gagaodok.data.MeasurementPolicy
import com.sapiens.gagaodok.data.OptimizationMeasurementStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/// 캐시를 왜 다시 만들었는지 가릅니다.
///
/// **`FIRST`가 다섯 가지 원인을 뭉치고 있었습니다.** 만료된 캐시는 지역 기록에서
/// 제거되므로 다음 생성 때 "이 방에 캐시가 없다"로 보입니다. 그래서 TTL을 늘려서
/// 줄이려던 바로 그 사건이 `FIRST`로 들어갔습니다. 실측 run-7의 `FIRST` 16건이
/// 그런 상태였고, 그 때문에 30분 TTL의 효과는 아직 측정되지 않았습니다.
class CacheDropReasonTest {
    private fun tempFile() = File.createTempFile("cache-drop", ".json").also { it.delete() }

    @Test
    fun `만료로 버린 뒤의 재생성은 첫 생성과 구분된다`() {
        val store = OptimizationMeasurementStore(tempFile()) { 1_000L }
        store.start(MeasurementPolicy.current())

        // 이 방은 처음이다.
        store.observeCacheCreateReason(CacheCreateReason.from(null), "gemini-3.8-flash")
        // 만료되어 버린 뒤 다시 만든다. TTL 연장이 줄이려는 것이 이것이다.
        store.observeCacheCreateReason(CacheCreateReason.from(CacheDropReason.EXPIRED), "gemini-3.8-flash")
        store.observeCacheCreateReason(CacheCreateReason.from(CacheDropReason.EXPIRED), "gemini-3.8-flash")

        val reasons = store.state.value.activeRun!!.cache.createReasons
        assertEquals(1, reasons[CacheCreateReason.FIRST])
        assertEquals(2, reasons[CacheCreateReason.EXPIRED])
    }

    @Test
    fun `캐시 판정과 생성 이유는 Gemini 요청만 센다`() {
        // 명시적 캐시는 Gemini 규칙입니다. DeepSeek는 서버가 알아서 캐시하므로
        // 섞이면 TTL·물림 효과를 잰 숫자가 흐려집니다.
        val store = OptimizationMeasurementStore(tempFile()) { 1_000L }
        store.start(MeasurementPolicy.current())
        store.observeCacheCreateReason(CacheCreateReason.FIRST, "deepseek-flash")
        store.observeCache(CacheObservation("room-a", 5_000, CacheDecision.CREATE_SUCCESS, 4_900, model = "deepseek-flash"))
        store.observeCache(CacheObservation("room-a", 5_000, CacheDecision.CREATE_SUCCESS, 4_900, model = "gemini-3.7-flash"))

        val cache = store.state.value.activeRun!!.cache
        assertEquals(emptyMap<CacheCreateReason, Int>(), cache.createReasons)
        assertEquals(mapOf(CacheDecision.CREATE_SUCCESS to 1), cache.decisionCounts)
        assertEquals(4_900L, cache.actualCacheTokens)
    }

    @Test
    fun `편집과 축소와 모델 변경도 각각 남는다`() {
        // 셋 다 TTL과 무관합니다. 만료와 섞이면 TTL 효과가 그만큼 흐려집니다.
        assertEquals(CacheCreateReason.FINGERPRINT_CHANGED,
            CacheCreateReason.from(CacheDropReason.FINGERPRINT_CHANGED))
        assertEquals(CacheCreateReason.SHRUNK, CacheCreateReason.from(CacheDropReason.SHRUNK))
        assertEquals(CacheCreateReason.MODEL_CHANGED,
            CacheCreateReason.from(CacheDropReason.MODEL_CHANGED))
    }

    @Test
    fun `TTL 효과는 만료와 만료임박의 합으로 읽는다`() {
        // 캐시가 살아 있을 때 미리 갱신하면 `EXPIRING_SOON`, 이미 죽었으면 `EXPIRED`
        // 입니다. TTL을 늘리면 둘 다 줄어야 하므로 함께 봐야 합니다.
        assertEquals(
            setOf(CacheCreateReason.EXPIRED, CacheCreateReason.EXPIRING_SOON),
            CacheCreateReason.entries.filter { it.ttlSensitive }.toSet()
        )
    }

    @Test
    fun `버린 기록이 없으면 진짜 첫 생성이다`() {
        assertEquals(CacheCreateReason.FIRST, CacheCreateReason.from(null))
        assertNull(CacheDropReason.entries.firstOrNull { CacheCreateReason.from(it) == CacheCreateReason.FIRST })
    }
}
