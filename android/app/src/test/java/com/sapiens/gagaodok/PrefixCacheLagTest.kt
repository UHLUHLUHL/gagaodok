package com.sapiens.gagaodok

import com.sapiens.gagaodok.service.CACHE_LAG_ENTRIES
import com.sapiens.gagaodok.service.ConversationCompactor
import com.sapiens.gagaodok.service.REROLL_SHRINK_MAX_ENTRIES
import com.sapiens.gagaodok.service.isRerollShrink
import com.sapiens.gagaodok.service.MINIMUM_CACHE_TOKENS
import com.sapiens.gagaodok.service.prefixCacheLagEntries
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// 캐시가 덮는 범위를 마지막 한 교환만큼 뒤로 물릴지 정합니다.
///
/// **왜 물리는가.** 예전에는 캐시가 대화 전체를 덮었습니다. 사용자가 자기 메시지를
/// 눌러 고치면 그 뒤가 잘려 나가 대화가 캐시보다 짧아지고, 그러면 캐시를 통째로
/// 버립니다(`SHRUNK`). 실측 run-9에서 캐시 재생성 65회 중 36회가 이것이었고,
/// 그 36번은 요청이 캐시 없이 전액으로 나갔습니다.
///
/// 마지막 교환을 캐시 밖에 두면, 그 교환을 다시 받아도 캐시는 그대로 살아 있습니다.
/// 대신 그 교환이 매 요청에 정가로 실립니다 — 그래서 **아무 데나 물리면 손해입니다.**
/// 손익분기는 382요청당 `SHRUNK` 6회이고, 아래 세 조건이 그 아래로 내려가는 경우를
/// 막습니다.
class PrefixCacheLagTest {

    @Test
    fun `고쳐 쓴 적 없는 방은 물리지 않는다`() {
        // 이 방은 잘려 나간 적이 없다. 물려 봐야 꼬리 값만 더 내고 얻는 것이 없다.
        assertEquals(0, prefixCacheLagEntries(entryCount = 80, laggedPrefixTokens = 30_000, shrinkProne = false))
    }

    @Test
    fun `고쳐 쓴 적 있는 방은 마지막 한 교환을 물린다`() {
        assertEquals(
            CACHE_LAG_ENTRIES,
            prefixCacheLagEntries(entryCount = 80, laggedPrefixTokens = 30_000, shrinkProne = true)
        )
    }

    @Test
    fun `물리면 최소치 아래로 떨어지는 방은 물리지 않는다`() {
        // 4,096토큰 미만은 Gemini가 캐시 생성을 거부합니다. 물리다가 그 아래로
        // 내려가면 캐시가 아예 안 만들어져, 아끼려다 방 하나를 통째로 잃습니다.
        assertEquals(
            0,
            prefixCacheLagEntries(
                entryCount = 20,
                laggedPrefixTokens = MINIMUM_CACHE_TOKENS - 1,
                shrinkProne = true
            )
        )
    }

    @Test
    fun `최소치에 딱 걸치면 물린다`() {
        assertEquals(
            CACHE_LAG_ENTRIES,
            prefixCacheLagEntries(
                entryCount = 20,
                laggedPrefixTokens = MINIMUM_CACHE_TOKENS,
                shrinkProne = true
            )
        )
    }

    @Test
    fun `물릴 만큼 대화가 길지 않으면 물리지 않는다`() {
        // 엔트리가 물릴 개수와 같거나 적으면 접두사가 비어 캐시가 성립하지 않습니다.
        assertEquals(
            0,
            prefixCacheLagEntries(
                entryCount = CACHE_LAG_ENTRIES,
                laggedPrefixTokens = 30_000,
                shrinkProne = true
            )
        )
    }

    @Test
    fun `물리는 양은 한 교환 — 사용자 한 마디와 답 한 번`() {
        // 실측: 재요청 203회 중 SHRUNK 36회(17.7%)였고, "마지막 턴만 다시 받는데
        // 그것이 캐시 생성 직후에 걸린 경우"의 이론값이 1/5.9 = 16.9%입니다.
        // 거의 일치하므로 한 교환이면 대부분을 막습니다. 더 물리면 꼬리 값만 커집니다.
        assertEquals(2, CACHE_LAG_ENTRIES)
    }

    @Test
    fun `답을 다시 받은 것과 요약이 원문을 접은 것을 가른다`() {
        // 캐시가 80엔트리를 덮고 있다고 하자.
        // 재요청: 마지막 답 하나가 잘려 79가 된다.
        assertTrue(isRerollShrink(coveredTurns = 80, newSize = 79))
        // 요약: 원문 창이 80턴에서 30턴으로 접히며 수십 개가 한꺼번에 준다.
        assertTrue(!isRerollShrink(coveredTurns = 180, newSize = 80))
    }

    @Test
    fun `요약 때문에 고쳐 쓰지 않는 방까지 표시되면 안 된다`() {
        // **이것이 이 가름의 이유다.** 요약은 50턴에 한 번 반드시 일어나므로,
        // 크기를 안 보고 표시하면 결국 모든 방이 표시된다. 그러면 답을 다시
        // 받지 않는 방도 꼬리 값을 매 요청 물면서 얻는 것이 없다.
        val 요약이_접은_양 = (ConversationCompactor.THRESHOLD_TURNS -
            ConversationCompactor.VERBATIM_WINDOW_TURNS) * 2   // 턴당 엔트리 둘
        assertTrue("요약은 재요청보다 훨씬 많이 줄인다", 요약이_접은_양 > REROLL_SHRINK_MAX_ENTRIES)
        assertTrue(!isRerollShrink(coveredTurns = 200, newSize = 200 - 요약이_접은_양))
    }

    @Test
    fun `경계값`() {
        assertTrue(isRerollShrink(coveredTurns = 50, newSize = 50 - REROLL_SHRINK_MAX_ENTRIES))
        assertTrue(!isRerollShrink(coveredTurns = 50, newSize = 50 - REROLL_SHRINK_MAX_ENTRIES - 1))
        // 줄지 않았는데 불린 경우(있으면 안 되지만)도 재요청으로 치지 않는다.
        assertTrue(isRerollShrink(coveredTurns = 50, newSize = 50))
    }
}
