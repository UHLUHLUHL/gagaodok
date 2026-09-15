package com.sapiens.gagaodok

import com.sapiens.gagaodok.data.AppSettings
import com.sapiens.gagaodok.data.ModelTokenUsage
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.service.AIService
import com.sapiens.gagaodok.service.MINIMUM_CACHE_TOKENS
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
    fun `Gemini 명시적 캐시는 공식 최소값보다 추정 여유를 둔다`() {
        assertEquals(4_600, MINIMUM_CACHE_TOKENS)
    }

    @Test
    fun `Luna 최신 인하 단가를 사용한다`() {
        assertEquals(0.20, AIModel.GPT_56_LUNA.inputPricePerMillion, 0.0)
        assertEquals(0.02, AIModel.GPT_56_LUNA.cachedInputPricePerMillion, 0.0)
        assertEquals(1.20, AIModel.GPT_56_LUNA.outputPricePerMillion, 0.0)
    }

    @Test
    fun `캐시에 올린 토큰은 요금에 안 들어간다`() {
        // **실제 청구서로 확인했습니다.** 예전에는 "확실하지 않으니 비싼 쪽으로"
        // 원칙으로 입력 단가를 매겼는데, 그게 화면 숫자를 실제보다 크게 만들었습니다.
        //
        // 2026-09-02~09-15 폰 프로젝트 청구서(필터 없음, SKU 12종):
        //   청구되는 종류는 input / cached input / output / cached content storage 넷뿐이고
        //   **캐시 생성 SKU가 없습니다.**
        //   입력 토큰 청구량 6,242,745 ≈ 장부의 비캐시 입력 6,314,689 (99%)
        //   생성이 입력에 섞였다면 14,261,416이어야 했습니다. 2.3배 차이라 필터로는
        //   설명되지 않습니다.
        //
        // 값 자체는 계속 셉니다. 캐시를 얼마나 다시 만드는지는 진단에 필요합니다.
        val without = ModelTokenUsage(inputTokens = 10_000, outputTokens = 1_000)
        val with = without.copy(cacheCreateTokens = 50_000)

        assertEquals(without.costUSD(model), with.costUSD(model), 1e-12)
    }

    @Test
    fun `캐시에 올린 토큰은 입력에서 덜어 내지도 않는다`() {
        // 요금에 안 넣는 것과 입력에서 빼는 것은 다릅니다. `inputTokens`는 모델이
        // 알려준 promptTokenCount이고 생성 토큰과 겹치지 않으므로 손대면 안 됩니다.
        val usage = ModelTokenUsage(inputTokens = 1_000, cacheCreateTokens = 100_000)

        assertEquals(1_000 / 1_000_000.0 * model.inputPricePerMillion, usage.costUSD(model), 1e-12)
    }

    @Test
    fun `캐시 보관료는 요금에 들어간다`() {
        // 생성과 달리 보관은 청구서에 항목이 있습니다.
        // `cached content storage token hours gemini 3.8 flash` 1,539,742시간 → ₩1,065.
        val usage = ModelTokenUsage(cacheStorageTokenHours = 1_000_000.0)

        assertEquals(model.cacheStoragePricePerMillionPerHour, usage.costUSD(model), 1e-12)
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
        //
        // 한때 챗봇 사고를 아예 끄려고 "off"를 보냈지만 서버가 거부했고, 무엇보다 사고량은
        // 대기 시간과 무관했습니다(같은 입력·같은 캐시로 1.7초와 24.3초가 갈렸습니다).
        // 속도로 얻을 것이 없으므로 조금이라도 생각하고 답하는 쪽으로 되돌렸습니다.
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

    @Test
    fun `환율 기본값은 청구서에서 역산한 값이다`() {
        // 2026-09-02~09-15 폰 청구서 세 항목에서 모두 같은 값이 나왔습니다.
        //   입력    6,085,703 × $0.75/M = $4.5643 → ₩6,314  → 1,383
        //   캐시읽기 34,537,934 × $0.075/M = $2.5903 → ₩3,583 → 1,383
        //   출력      339,611 × $3.75/M = $1.2735 → ₩1,762  → 1,384
        // 예전 기본값 1,420은 근거 없이 정한 값이었습니다.
        assertEquals(1383.0, AppSettings.DEFAULT_EXCHANGE_RATE, 0.0)
    }
}
