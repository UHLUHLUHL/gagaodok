package com.sapiens.gagaodok

import com.sapiens.gagaodok.data.ModelTokenUsage
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.service.AIService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// 요금 계산이 실제로 낸 돈보다 적게 나오지 않는지 봅니다.
///
/// 화면에 뜨는 금액이 실제보다 **적은** 것이 가장 나쁜 실패입니다.
/// 많으면 사용자가 놀라고 끝이지만, 적으면 새는 곳을 못 찾습니다.
class UsageAccountingTest {

    private val model = AIModel.GEMINI_37_FLASH

    @Test
    fun `캐시에 올린 토큰도 요금에 들어간다`() {
        // 캐시를 만드는 요청은 별개의 요청이라 어떤 promptTokenCount에도 안 잡힙니다.
        // 예전에는 이 값을 아예 안 세서 캐시를 매 턴 새로 만드는 비용이 통째로 빠졌습니다.
        val without = ModelTokenUsage(inputTokens = 10_000, outputTokens = 1_000)
        val with = without.copy(cacheCreateTokens = 50_000)

        val delta = with.costUSD(model) - without.costUSD(model)
        assertEquals(50_000 / 1_000_000.0 * model.inputPricePerMillion, delta, 1e-12)
    }

    @Test
    fun `캐시에 올린 토큰은 입력에서 덜어 내지 않는다`() {
        // OpenAI식 cacheWriteTokens는 inputTokens의 부분집합이라 덜어 내지만,
        // Gemini식 캐시 생성은 별도 청구라 덜어 내면 안 됩니다.
        val usage = ModelTokenUsage(inputTokens = 1_000, cacheCreateTokens = 100_000)
        assertTrue(usage.costUSD(model) > 100_000 / 1_000_000.0 * model.inputPricePerMillion)
    }

    @Test
    fun `합칠 때 새 항목도 함께 더해진다`() {
        val a = ModelTokenUsage(cacheCreateTokens = 100, unreportedRequests = 1)
        val b = ModelTokenUsage(cacheCreateTokens = 250, unreportedRequests = 2)
        val sum = a.adding(b)
        assertEquals(350, sum.cacheCreateTokens)
        assertEquals(3, sum.unreportedRequests)
    }

    @Test
    fun `사고 토큰은 출력 요금으로 친다`() {
        // 사고 토큰은 화면에 한 글자도 안 보이지만 출력 단가로 청구됩니다.
        val usage = ModelTokenUsage(outputTokens = 2_000)
        assertEquals(2_000 / 1_000_000.0 * model.outputPricePerMillion, usage.costUSD(model), 1e-12)
    }
}

/// 모드마다 사고량이 다른지 봅니다.
class ThinkingLevelTest {

    @Test
    fun `챗봇은 적게 생각하고 멘토는 그대로다`() {
        // 사고 토큰은 화면에 안 보이지만 출력 단가(입력의 5배)로 청구됩니다.
        // 챗봇에 필요한 것은 정답이 아니라 그 인물다운 말씨와 빠른 대꾸라
        // 오래 생각한다고 좋아지지 않습니다. 멘토는 계산이 틀리면 틀린 것을 가르칩니다.
        assertEquals("low", ChatMode.COMPANION.geminiThinkingLevel)
        assertEquals("medium", ChatMode.MATH_MENTOR.geminiThinkingLevel)
    }
}

/// 말투 조사가 "지금 무엇을 하고 있는지"를 지어내지 않고 도착한 글에서 읽어 내는지 봅니다.
class LookupProgressTest {

    @Test
    fun `아직 아무것도 안 왔으면 찾는 중이다`() {
        assertEquals("자료를 찾고 있습니다…", AIService.lookupProgressLabel(""))
    }

    @Test
    fun `절이 열린 순서대로 따라간다`() {
        assertEquals(
            "찾은 자료를 살펴보고 있습니다…",
            AIService.lookupProgressLabel("[확신도] 높음. 대사를 여럿 찾음")
        )
        assertEquals(
            "말투 규칙을 적고 있습니다…",
            AIService.lookupProgressLabel("[확신도] 높음\n[대사]\n가\n나\n[말투]\n- 문장 끝맺음:")
        )
    }

    @Test
    fun `대사는 몇 줄까지 왔는지 센다`() {
        // 숫자가 늘어나는 것이 보여야 멈춘 것이 아님을 알 수 있습니다.
        val soFar = "[확신도] 높음\n[대사]\n첫 줄\n둘째 줄\n셋째 줄"
        assertEquals("대사를 모으고 있습니다… 3줄", AIService.lookupProgressLabel(soFar))
    }

    @Test
    fun `절만 열리고 아직 줄이 없으면 숫자를 붙이지 않는다`() {
        assertEquals("대사를 모으고 있습니다…", AIService.lookupProgressLabel("[확신도] 보통\n[대사]\n"))
    }
}
