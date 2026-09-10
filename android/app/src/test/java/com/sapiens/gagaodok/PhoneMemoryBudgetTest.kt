package com.sapiens.gagaodok

import com.sapiens.gagaodok.service.ConversationCompactor
import com.sapiens.gagaodok.service.GEMINI_MODEL_MAX_OUTPUT_TOKENS
import com.sapiens.gagaodok.service.MEMORY_THINKING_LEVEL
import com.sapiens.gagaodok.service.THINKING_HEADROOM
import com.sapiens.gagaodok.service.outputBudget
import com.sapiens.gagaodok.service.phoneMemoryOutputBudget
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// 기억 갱신에 줄 출력 예산입니다.
///
/// **사고 토큰과 응답 본문이 같은 예산을 나눠 씁니다.** 실사용 12건에서 호출당
/// 평균 출력이 상한 3,500의 98.25%였고 본문은 평균 258토큰이었습니다. 지시한
/// 분량은 구간당 900~1,100인데 그 1/4도 못 쓰고 천장에 닿은 것입니다.
class PhoneMemoryBudgetTest {
    @Test
    fun `본문 필요량과 사고 여유를 각각 확보한다`() {
        // 한 예산에 뭉쳐 잡으면 사고가 길어질 때 본문이 먼저 잘립니다.
        // 본문 몫은 지시문이 요구하는 최대치에서 나옵니다:
        // M2 구간당 1,500 + M3 최대 800 + JSON 구조.
        val body = 1 * ConversationCompactor.SEGMENT_TOKEN_BUDGET + 1000
        assertEquals(body + THINKING_HEADROOM, phoneMemoryOutputBudget(1))
        assertTrue("본문만으로도 M2 1500과 M3 800이 들어가야 한다", body >= 2300)
    }

    @Test
    fun `구간이 늘면 본문 몫만 늘고 사고 여유는 그대로다`() {
        // 전환은 구간을 여러 개 만듭니다. 사고량이 구간 수에 비례하지는 않습니다.
        val one = phoneMemoryOutputBudget(1)
        val three = phoneMemoryOutputBudget(3)
        assertEquals(2 * ConversationCompactor.SEGMENT_TOKEN_BUDGET, three - one)
    }

    @Test
    fun `코드가 허용하는 최대 구간에서도 모델 상한 안에 있다`() {
        // 전환은 구간이 최대 30개입니다(`Migration requires bounded repair`).
        // 30구간이면 54,192로 아직 여유가 있습니다.
        assertTrue(phoneMemoryOutputBudget(30) <= GEMINI_MODEL_MAX_OUTPUT_TOKENS)
        assertEquals(30 * ConversationCompactor.SEGMENT_TOKEN_BUDGET + 1000 + THINKING_HEADROOM,
            phoneMemoryOutputBudget(30))
    }

    @Test
    fun `상한을 넘길 만큼 커지면 잘라낸다`() {
        // 지금 코드로는 도달하지 않지만, 구간 상한이나 분량 예산이 바뀌면 조용히
        // 모델 한도를 넘어 요청 자체가 거부됩니다. 그때 실패하지 않도록 막아 둡니다.
        assertEquals(GEMINI_MODEL_MAX_OUTPUT_TOKENS, phoneMemoryOutputBudget(100))
    }

    @Test
    fun `사고 몫은 본문이 무엇이든 같은 크기로 붙는다`() {
        // 사고량은 본문 분량과 무관합니다. 말투 분석이든 구간 요약이든 모델이
        // 생각하는 양은 그 작업의 어려움에서 나오지, 답이 길어서 늘지 않습니다.
        assertEquals(2048 + THINKING_HEADROOM, outputBudget(2048))
        assertEquals(2560 + THINKING_HEADROOM, outputBudget(2560))
        assertEquals(GEMINI_MODEL_MAX_OUTPUT_TOKENS, outputBudget(60_000))
    }

    @Test
    fun `예전 예산은 사고 하나로 다 찼다`() {
        // 회귀 방지입니다. 예전 값은 1,500 + 2,000 = 3,500이었고 관측된 사고
        // 최대가 3,362였습니다. 남는 자리가 138토큰뿐이라 요약을 쓸 수 없었습니다.
        val old = 1 * 1500 + 2000
        assertTrue("새 예산은 관측된 사고량에 본문 몫을 더한 것보다 커야 한다",
            phoneMemoryOutputBudget(1) > 3362 + 2300)
        assertTrue(phoneMemoryOutputBudget(1) > old)
        // **예산만 올리는 것으로는 못 고칩니다.** 실측에서 `high`는 3,500을 주면
        // 3,362(96.1%), 10,692를 주면 10,262(96.0%)를 썼습니다. 주는 만큼 먹으므로
        // 남는 자리는 늘 그대로입니다. 그래서 `thinkingLevel`을 낮춰야 합니다.
        assertEquals("low", MEMORY_THINKING_LEVEL)
    }
}
