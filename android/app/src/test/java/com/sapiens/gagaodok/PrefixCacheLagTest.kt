package com.sapiens.gagaodok

import com.sapiens.gagaodok.service.CACHE_LAG_ENTRIES
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.service.ConversationCompactor
import com.sapiens.gagaodok.service.ConversationDigest
import com.sapiens.gagaodok.service.ConversationSegment
import com.sapiens.gagaodok.service.REROLL_SHRINK_MAX_ENTRIES
import com.sapiens.gagaodok.service.isRerollShrink
import com.sapiens.gagaodok.service.MINIMUM_CACHE_TOKENS
import com.sapiens.gagaodok.service.prefixCacheLagEntries
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

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
    fun `요약이 진행된 요청은 답을 다시 받은 것으로 치지 않는다`() {
        // **코덱스 검토에서 걸린 결함이다.** 예전에는 크기 차이만 봤다.
        // `coveredTurns`는 과거에 만들어진 캐시의 길이고 `newSize`는 지금 요청의
        // 길이라, 기준 시점이 다른 두 수를 빼고 있었다. 오래된 캐시 길이와 요약 뒤
        // 길이가 우연히 비슷하면 정상 요약이 재요청으로 둔갑했다.
        //
        // 이제는 요약 적용 범위가 늘었는지를 **부르는 쪽이 알려 준다.**
        assertTrue(
            !isRerollShrink(
                cacheDigestCoveredTurns = 0,    // 캐시를 만들 때는 요약이 없었고
                requestDigestCoveredTurns = 50, // 지금은 50턴까지 덮는다 = 요약이 돌았다
                coveredTurns = 63,
                newSize = 63                    // 크기만 보면 "0만 줄었다"로 보인다
            )
        )
    }

    @Test
    fun `요약이 그대로면 조금 줄어든 것은 답을 다시 받은 것이다`() {
        assertTrue(
            isRerollShrink(
                cacheDigestCoveredTurns = 50,
                requestDigestCoveredTurns = 50,
                coveredTurns = 120,
                newSize = 119
            )
        )
    }

    @Test
    fun `줄지 않았으면 답을 다시 받은 것이 아니다`() {
        // 재요청은 최소한 답 하나를 지운다. 차이 0은 재요청일 수 없다.
        assertTrue(
            !isRerollShrink(
                cacheDigestCoveredTurns = 50,
                requestDigestCoveredTurns = 50,
                coveredTurns = 63,
                newSize = 63
            )
        )
    }

    @Test
    fun `요약 진행 여부를 모르는 옛 캐시는 크기로 가른다`() {
        // 이 버전 이전에 저장된 캐시에는 `digestCoveredTurns`가 없다(-1).
        assertTrue(isRerollShrink(-1, 50, coveredTurns = 100, newSize = 99))
        assertTrue(!isRerollShrink(-1, 50, coveredTurns = 200, newSize = 100))
        assertTrue(
            !isRerollShrink(-1, 50, coveredTurns = 100, newSize = 100 - REROLL_SHRINK_MAX_ENTRIES - 1)
        )
    }

    @Test
    fun `실제 요약 흐름에서 방이 표시되지 않는다`() {
        // 코덱스가 재현한 순서를 실제 `ConversationCompactor.plan`으로 만든다.
        // 캐시는 사용자 32턴 때 만들어졌고(요약 없음), 지금은 81턴에 1~50턴 요약이
        // 끝난 상태다. 요청 배열 길이가 캐시 길이와 같아지는 지점이다.
        fun conversation(userTurns: Int) = buildList {
            repeat(userTurns) {
                add(ConversationTurn(UUID.randomUUID(), MessageSender.USER, "질문 $it"))
                add(ConversationTurn(UUID.randomUUID(), MessageSender.SAPIENS, "답변 $it"))
            }
        }

        val 캐시생성시점 = ConversationCompactor.plan(conversation(32), null, ChatMode.COMPANION)
        val 요약후 = ConversationCompactor.plan(
            conversation(81),
            ConversationDigest(
                segments = listOf(ConversationSegment(firstTurn = 1, lastTurn = 50, text = "요약")),
                memoryVersion = 2,
                revision = 1
            ),
            ChatMode.COMPANION,
            renderDigest = { "M2/M3" }
        )

        // 캐시를 만들 때는 요약이 0턴, 지금은 50턴을 덮는다.
        assertEquals(0, 캐시생성시점.coveredTurns)
        assertEquals(50, 요약후.coveredTurns)

        // 요청 엔트리 수(요약 preamble 2개 + 원문)를 세어 크기가 실제로 비슷해지는지 본다.
        val 캐시길이 = 캐시생성시점.verbatimTurns.size
        val 요약후길이 = 요약후.verbatimTurns.size + 2

        assertTrue(
            "이 순서에서는 크기만으로 가를 수 없다 (캐시 $캐시길이 / 요약후 $요약후길이)",
            캐시길이 - 요약후길이 in 0..REROLL_SHRINK_MAX_ENTRIES
        )
        // 그런데도 표시되면 안 된다 — 요약 범위가 0에서 50으로 늘었기 때문이다.
        assertTrue(
            !isRerollShrink(
                cacheDigestCoveredTurns = 캐시생성시점.coveredTurns,
                requestDigestCoveredTurns = 요약후.coveredTurns,
                coveredTurns = 캐시길이,
                newSize = 요약후길이
            )
        )
    }

    @Test
    fun `같은 흐름에서 답을 다시 받으면 표시된다`() {
        // 요약은 그대로인데 마지막 답 하나가 잘린 경우다.
        assertTrue(
            isRerollShrink(
                cacheDigestCoveredTurns = 50,
                requestDigestCoveredTurns = 50,
                coveredTurns = 63,
                newSize = 62
            )
        )
    }
}
