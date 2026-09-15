package com.sapiens.gagaodok

import com.sapiens.gagaodok.service.PrefixCache
import com.sapiens.gagaodok.service.cacheLeaseTokenHours
import org.junit.Assert.assertEquals
import org.junit.Test

/// 캐시가 살아 있던 시간을 보관량으로 적습니다.
///
/// **캐시의 85%가 정산 없이 사라지고 있었습니다.** 정산은 `refreshPrefixCache`가
/// 이전 캐시를 교체할 때 한 곳에서만 일어났는데, 실측 run-9의 생성 74회 중
/// 교체는 11회(15%)뿐이었습니다. 나머지 63회(SHRUNK 39·EXPIRED 15·FIRST 9)는
/// `dropCache`로 버려졌고 그 캐시들이 산 시간은 어디에도 안 적혔습니다.
///
/// 실제 청구서(2026-09-02~09-15 폰)와 대조하면 그 차이가 보입니다.
///   장부 1,006,906 토큰·시간 / 청구 1,539,742 → **65%밖에 안 셌습니다.**
///   같은 기간 다른 세 항목(입력·캐시읽기·출력)은 99~100%로 맞습니다.
class CacheLeaseAccountingTest {

    private fun cache(createdAtMillis: Long, tokenCount: Int) = PrefixCache(
        name = "cachedContents/x",
        coveredTurns = 10,
        fingerprint = "f",
        expiresAtMillis = createdAtMillis + 1_800_000,
        tokenCount = tokenCount,
        createdAtMillis = createdAtMillis
    )

    @Test
    fun `산 시간만큼 적는다`() {
        // 30분 산 27,000토큰짜리 캐시 = 13,500 토큰·시간.
        val hours = cacheLeaseTokenHours(cache(createdAtMillis = 1_000_000L, tokenCount = 27_000), now = 1_000_000L + 1_800_000L)
        assertEquals(13_500.0, hours, 1e-9)
    }

    @Test
    fun `만든 시각을 모르면 적지 않는다`() {
        // 이 버전 이전에 저장된 캐시에는 `createdAtMillis`가 없습니다(0).
        // 지어내는 것보다 빠뜨리는 편이 낫습니다.
        assertEquals(0.0, cacheLeaseTokenHours(cache(createdAtMillis = 0L, tokenCount = 27_000), now = 9_999_999L), 0.0)
    }

    @Test
    fun `크기를 모르면 적지 않는다`() {
        assertEquals(0.0, cacheLeaseTokenHours(cache(createdAtMillis = 1_000L, tokenCount = 0), now = 9_999_999L), 0.0)
    }

    @Test
    fun `캐시가 없으면 적지 않는다`() {
        assertEquals(0.0, cacheLeaseTokenHours(null, now = 9_999_999L), 0.0)
    }

    @Test
    fun `시계가 거꾸로 가도 음수를 적지 않는다`() {
        // 기기 시각이 뒤로 조정되면 음수가 나옵니다. 그대로 더하면 장부가 줄어듭니다.
        assertEquals(0.0, cacheLeaseTokenHours(cache(createdAtMillis = 5_000_000L, tokenCount = 27_000), now = 1_000_000L), 0.0)
    }
}
