package com.sapiens.gagaodok

import com.sapiens.gagaodok.data.MeasurementPolicy
import com.sapiens.gagaodok.data.OptimizationMeasurementStore
import com.sapiens.gagaodok.data.PromptTokenBreakdown
import com.sapiens.gagaodok.service.ConversationDigest
import com.sapiens.gagaodok.service.ConversationSegment
import com.sapiens.gagaodok.service.MemoryCheckpoint
import com.sapiens.gagaodok.service.MemoryItem
import com.sapiens.gagaodok.service.PrefixCache
import com.sapiens.gagaodok.service.ThreeLayerMemory
import com.sapiens.gagaodok.service.cacheLeaseTokenHours
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/// 계측을 계층별로 가르는 장치들입니다. **동작은 바꾸지 않고 재는 자만 고칩니다.**
///
/// 고치기 전에는 세 가지를 볼 수 없었습니다.
///   - M2(사건 기억)가 얼마나 자랐는지 — `digestTokens`에 M3와 뭉쳐 있었다
///   - M3가 3,000토큰 상한에 얼마나 가까운지 — 닿으면 `loop:`가 실제로 버려진다
///   - 캐시가 죽은 뒤 사용자가 얼마 만에 돌아오는지 — TTL을 정할 근거가 없었다
class DigestPartsAndGapTest {

    private fun item(key: String, text: String) =
        MemoryItem(key = key, text = text, evidenceTurnId = "t1", setAtTurn = 50)

    private fun digest(segmentCount: Int, withCheckpoint: Boolean): ConversationDigest {
        val segments = (1..segmentCount).map { i ->
            ConversationSegment(
                firstTurn = (i - 1) * 50 + 1,
                lastTurn = i * 50,
                text = "구간 $i 사건 기록",
                memory = if (withCheckpoint && i == segmentCount) MemoryCheckpoint(
                    items = listOf(item("place", "카페"), item("boundary:spoiler", "결말은 말하지 않는다")),
                    throughTurnId = "t$i",
                    sourceHash = "h$i",
                    rendererVersion = 1
                ) else null
            )
        }
        return ConversationDigest(segments = segments, memoryVersion = 2)
    }

    // ── 조각과 렌더가 어긋나지 않는다 ─────────────────────────

    @Test
    fun `조각을 이어 붙이면 렌더 결과와 글자까지 같다`() {
        // **이것이 이 장치의 안전장치다.** 토큰을 세려고 같은 문자열을 두 번
        // 조립하면 렌더가 바뀔 때 계측만 조용히 어긋난다. `render`가 `parts`로
        // 만들어지므로 이 검사가 깨지면 둘 중 하나를 고친 것이다.
        for (n in 1..3) for (cp in listOf(true, false)) {
            val d = digest(n, cp)
            assertEquals(ThreeLayerMemory.render(d), ThreeLayerMemory.parts(d).text)
        }
    }

    @Test
    fun `상태 checkpoint가 없으면 M3 조각이 비어 있다`() {
        val p = ThreeLayerMemory.parts(digest(2, withCheckpoint = false))
        assertEquals("", p.state)
        assertEquals("", p.stateHeader)
        assertTrue(p.events.isNotEmpty())
    }

    @Test
    fun `사건이 늘면 M2 조각만 자란다`() {
        val small = ThreeLayerMemory.parts(digest(1, true))
        val large = ThreeLayerMemory.parts(digest(4, true))
        assertTrue("사건 조각은 자란다", large.events.length > small.events.length)
        assertEquals("상태 조각은 그대로다", small.state, large.state)
    }

    @Test
    fun `규칙이 늘면 M3 조각만 자란다`() {
        val base = digest(2, true)
        val more = base.copy(segments = base.segments.dropLast(1) + base.segments.last().let { s ->
            s.copy(memory = s.memory!!.copy(items = s.memory!!.items + item("loop:greeting", "인사를 반복하지 않는다")))
        })
        val a = ThreeLayerMemory.parts(base)
        val b = ThreeLayerMemory.parts(more)
        assertEquals("사건 조각은 그대로다", a.events, b.events)
        assertTrue("상태 조각은 자란다", b.state.length > a.state.length)
    }

    // ── 합계가 어긋나지 않는다 ─────────────────────────────

    @Test
    fun `계층 합계는 더해도 계층별로 유지된다`() {
        val a = PromptTokenBreakdown(digestTokens = 100, digestEventTokens = 70, digestStateTokens = 20, digestOverheadTokens = 10)
        val sum = a.adding(a)
        assertEquals(200, sum.digestTokens)
        assertEquals(140, sum.digestEventTokens)
        assertEquals(40, sum.digestStateTokens)
        assertEquals(20, sum.digestOverheadTokens)
        assertEquals("셋의 합이 합계다", sum.digestTokens,
            sum.digestEventTokens + sum.digestStateTokens + sum.digestOverheadTokens)
    }

    // ── 요청 간격 ─────────────────────────────────────────

    private fun store(): OptimizationMeasurementStore =
        OptimizationMeasurementStore(File.createTempFile("gap", ".json")) { 1_000L }
            .also { it.start(MeasurementPolicy.current()) }

    @Test
    fun `간격을 구간별로 센다`() {
        val s = store()
        val now = 10_000_000L
        s.observeRequestGap(now - 60_000L, now)        // 1분
        s.observeRequestGap(now - 7 * 60_000L, now)    // 7분
        s.observeRequestGap(now - 20 * 60_000L, now)   // 20분
        s.observeRequestGap(now - 90 * 60_000L, now)   // 90분
        val g = s.state.value.activeRun!!.requestGaps
        assertEquals(1, g.withinFiveMinutes)
        assertEquals(1, g.fiveToTenMinutes)
        assertEquals(1, g.tenToThirtyMinutes)
        assertEquals(1, g.overThirtyMinutes)
        assertEquals(0, g.unknown)
    }

    @Test
    fun `앱을 다시 켠 뒤 첫 요청은 모름으로 센다`() {
        // **모르는 것을 "오래됐다"로 세면 안 된다.** 직전 시각은 메모리에만 있어
        // 재시작하면 사라진다. 그것을 30분 초과로 세면 TTL 판단이 틀어진다.
        val s = store()
        s.observeRequestGap(null, 10_000_000L)
        val g = s.state.value.activeRun!!.requestGaps
        assertEquals(1, g.unknown)
        assertEquals(0, g.overThirtyMinutes)
    }

    @Test
    fun `경계값은 짧은 쪽에 넣는다`() {
        val s = store()
        val now = 10_000_000L
        s.observeRequestGap(now - 5 * 60_000L, now)
        s.observeRequestGap(now - 30 * 60_000L, now)
        val g = s.state.value.activeRun!!.requestGaps
        assertEquals("정확히 5분은 5분 이내", 1, g.withinFiveMinutes)
        assertEquals("정확히 30분은 30분 이내", 1, g.tenToThirtyMinutes)
        assertEquals(0, g.overThirtyMinutes)
    }

    @Test
    fun `시계가 거꾸로 가면 모름으로 센다`() {
        val s = store()
        s.observeRequestGap(10_000_000L, 9_000_000L)
        assertEquals(1, s.state.value.activeRun!!.requestGaps.unknown)
    }

    // ── 만료 캐시의 보관량 ─────────────────────────────────

    @Test
    fun `만료된 캐시는 만료 시각까지만 적는다`() {
        // 앱이 꺼진 사이 만료된 캐시다. 끝난 시각은 앱을 다시 켠 지금이 아니라
        // **만료 시각**이다. `now`로 재면 꺼져 있던 시간까지 요금으로 적힌다.
        val created = 1_000_000L
        val cache = PrefixCache(
            name = "cachedContents/x", coveredTurns = 10, fingerprint = "f",
            expiresAtMillis = created + 1_800_000L, tokenCount = 27_000, createdAtMillis = created
        )
        val settled = cacheLeaseTokenHours(cache, cache.expiresAtMillis)
        assertEquals(13_500.0, settled, 1e-9)

        val muchLater = created + 24 * 3_600_000L
        assertTrue("지금 시각으로 재면 과대 계상된다", cacheLeaseTokenHours(cache, muchLater) > settled * 40)
    }
}
