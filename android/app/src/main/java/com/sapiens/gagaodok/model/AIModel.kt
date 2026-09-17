package com.sapiens.gagaodok.model

import java.util.Calendar
import java.util.TimeZone

enum class AIModel(val rawValue: String) {
    GEMINI_38_FLASH("gemini-3.8-flash"),
    GEMINI_37_FLASH("gemini-3.7-flash"),
    GPT_56_LUNA("gpt-5.6-luna"),

    /// **실험 중입니다.** 도입이 확정되지 않았으므로 걷어낼 때는 이 항목과
    /// `service/AIServiceDeepSeek.kt`, 그리고 `DEEPSEEK_FLASH`를 부르는 분기를 지웁니다.
    ///
    /// 식별자는 공식 요금표(https://api-docs.deepseek.com/quick_start/pricing, 2026-09-17 확인)의
    /// 모델 이름입니다. `deepseek-flash`가 DeepSeek-V4.1-Flash를 가리킵니다.
    DEEPSEEK_FLASH("deepseek-flash");

    val displayName: String
        get() = when (this) {
            GEMINI_38_FLASH -> "Gemini 3.8 Flash"
            GEMINI_37_FLASH -> "Gemini 3.7 Flash"
            GPT_56_LUNA -> "GPT-5.6 Luna"
            DEEPSEEK_FLASH -> "DeepSeek V4.1 Flash"
        }

    val shortName: String
        get() = when (this) {
            GEMINI_38_FLASH, GEMINI_37_FLASH -> "Gemini"
            GPT_56_LUNA -> "Luna"
            DEEPSEEK_FLASH -> "DeepSeek"
        }

    val providerName: String
        get() = when (this) {
            GEMINI_38_FLASH, GEMINI_37_FLASH -> "Google"
            GPT_56_LUNA -> "OpenAI"
            DEEPSEEK_FLASH -> "DeepSeek"
        }

    val inputPricePerMillion: Double
        get() = when (this) {
            GEMINI_38_FLASH, GEMINI_37_FLASH -> if (isIntroductoryPricingActive) 0.75 else 1.50
            GPT_56_LUNA -> 0.20
            // DeepSeek 세 단가는 **비피크** 값입니다. 피크 몫은 `peakSurchargeRate`로 더합니다.
            DEEPSEEK_FLASH -> 0.15
        }

    val cachedInputPricePerMillion: Double
        get() = when (this) {
            GEMINI_38_FLASH, GEMINI_37_FLASH -> if (isIntroductoryPricingActive) 0.075 else 0.15
            GPT_56_LUNA -> 0.02
            DEEPSEEK_FLASH -> 0.003
        }

    val outputPricePerMillion: Double
        get() = when (this) {
            GEMINI_38_FLASH, GEMINI_37_FLASH -> if (isIntroductoryPricingActive) 3.75 else 7.50
            GPT_56_LUNA -> 1.20
            DEEPSEEK_FLASH -> 0.6
        }

    /// 명시적 캐시를 1시간 보관할 때 100만 토큰당 요금입니다.
    /// Gemini는 캐시를 올려두는 동안 별도로 보관료가 붙습니다.
    val cacheStoragePricePerMillionPerHour: Double
        get() = when (this) {
            GEMINI_38_FLASH, GEMINI_37_FLASH -> if (isIntroductoryPricingActive) 0.50 else 1.00
            GPT_56_LUNA -> 0.0  // OpenAI는 보관료 없이 캐시 쓰기 요금만 받습니다.
            // DeepSeek는 서버가 알아서 디스크에 캐시하고 보관료가 없습니다(요금표에 항목 없음).
            DEEPSEEK_FLASH -> 0.0
        }

    /// 캐시에 처음 써 넣을 때 입력 단가 대비 배수입니다.
    /// OpenAI 계열에만 있는 개념이라 Gemini는 1.0으로 두고 대신 보관료로 계산합니다.
    val cacheWriteMultiplier: Double
        get() = when (this) {
            GEMINI_38_FLASH, GEMINI_37_FLASH -> 1.0
            GPT_56_LUNA -> 1.25
            // 캐시 쓰기 항목이 요금표에 없습니다. 적중하지 않은 입력은 그냥 입력 단가입니다.
            DEEPSEEK_FLASH -> 1.0
        }

    /// 피크 시간대에 비피크 단가 위로 더 받는 비율입니다. 0이면 시간대와 상관없습니다.
    ///
    /// DeepSeek 요금표: "Off-peak rates are half of the peak rates" — 피크는 비피크의
    /// 두 배이므로 더 받는 몫은 비피크 단가의 100%입니다. 어느 요청이 피크였는지는
    /// 보낸 시각으로 가립니다([isDeepSeekPeak]).
    val peakSurchargeRate: Double
        get() = if (this == DEEPSEEK_FLASH) 1.0 else 0.0

    /**
     * 이 모델이 Gemini 계열인가.
     *
     * 예전에는 `this == GEMINI_37_FLASH`였습니다. Gemini가 하나뿐일 때만 맞는
     * 코드였고, 3.8이 들어오는 순간 3.8이 "Gemini가 아닌 것"으로 취급됩니다.
     */
    val isGeminiConversationModel: Boolean
        get() = this == GEMINI_38_FLASH || this == GEMINI_37_FLASH

    /// 개인 챗봇 대화와 보조 호출이 함께 쓰는 길(`sendGeminiRequest`, `postGemini`)로
    /// 보낼 수 있는 모델인가. Gemini는 그대로, DeepSeek는 전송 직전에 형식을 옮겨 보냅니다.
    /// Luna는 따로 떼어 둔 길(`sendOpenAIRequest`)을 씁니다.
    val usesSharedConversationPath: Boolean
        get() = isGeminiConversationModel || this == DEEPSEEK_FLASH

    companion object {
        // 첫 항목이 기본값입니다. 실험 모델은 끝에 둡니다.
        // DeepSeek는 폰에서만 고를 수 있습니다. 태블릿 빌드는 기억·호감도 길이 꺼져 있어
        // 이번 실험 범위(폰 챗봇) 밖입니다. 태블릿에서 DeepSeek로 저장된 방은 3.7로 물러납니다.
        val personalCompanionModels: List<AIModel> =
            if (com.sapiens.gagaodok.BuildConfig.TABLET_MENTOR) listOf(GEMINI_38_FLASH, GEMINI_37_FLASH)
            else listOf(GEMINI_38_FLASH, GEMINI_37_FLASH, DEEPSEEK_FLASH)

        // 이전 버전이 저장한 모델 식별자를 현재 모델로 이어 붙입니다.
        // 이 표가 없으면 3.6 시절에 쌓인 토큰·요금 기록이 조용히 사라집니다.
        //
        // Flash-Lite는 개인 챗봇방 선택지로 넣었다가 실사용에서 물렸습니다. 맥락을
        // 놓치고 답이 얕아서 챗봇으로 쓸 수 없었습니다. 열거에서는 뺐지만 식별자는
        // 여기 남깁니다. 그 모델로 대화했던 방과 그때 쌓인 요금 기록이 남아 있고,
        // 이 줄이 없으면 방은 전역 기본값으로 튀고 장부의 그 행은 다음 저장 때 사라집니다.
        private val legacyIdentifiers = mapOf(
            "gemini-3.6-flash" to GEMINI_37_FLASH,
            "gemini-3.5-flash-lite" to GEMINI_37_FLASH
        )

        fun fromStoredValue(value: String): AIModel? =
            entries.firstOrNull { it.rawValue == value } ?: legacyIdentifiers[value]

        // Gemini 3.8·3.7 Flash 도입 요금은 2026-12-31까지만 적용되고 2027-01-01부터 정가로 두 배가 됩니다.
        // 대시보드는 "지금 청구되는 금액"을 보여줘야 하므로 단가를 날짜에 따라 고릅니다.
        private val standardPricingStartMillis: Long by lazy {
            Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
                clear()
                set(2027, Calendar.JANUARY, 1)
            }.timeInMillis
        }

        val isIntroductoryPricingActive: Boolean
            get() = System.currentTimeMillis() < standardPricingStartMillis

        /// DeepSeek 피크 시간대인가. 요금표: "Peak hours are 01:00 - 04:00 and 06:00 - 10:00 UTC,
        /// Monday through Friday (all other hours are off-peak)."
        ///
        /// 요청을 **보낸** 시각으로 가립니다. 경계에 걸친 요청을 서버가 어느 쪽으로 매기는지는
        /// 문서에 없습니다(미확인).
        fun isDeepSeekPeak(atMillis: Long): Boolean {
            val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { timeInMillis = atMillis }
            val weekday = utc.get(Calendar.DAY_OF_WEEK) in Calendar.MONDAY..Calendar.FRIDAY
            val hour = utc.get(Calendar.HOUR_OF_DAY)
            return weekday && (hour in 1..3 || hour in 6..9)
        }
    }
}
