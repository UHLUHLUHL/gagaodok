package com.sapiens.gagaodok.model

import java.util.Calendar
import java.util.TimeZone

enum class AIModel(val rawValue: String) {
    GEMINI_37_FLASH("gemini-3.7-flash"),
    GEMINI_35_FLASH_LITE("gemini-3.5-flash-lite"),
    GPT_56_LUNA("gpt-5.6-luna");

    val displayName: String
        get() = when (this) {
            GEMINI_37_FLASH -> "Gemini 3.7 Flash"
            GEMINI_35_FLASH_LITE -> "Gemini 3.5 Flash-Lite"
            GPT_56_LUNA -> "GPT-5.6 Luna"
        }

    val shortName: String
        get() = when (this) {
            GEMINI_37_FLASH -> "Gemini"
            GEMINI_35_FLASH_LITE -> "Gemini Lite"
            GPT_56_LUNA -> "Luna"
        }

    val providerName: String
        get() = when (this) {
            GEMINI_37_FLASH -> "Google"
            GEMINI_35_FLASH_LITE -> "Google"
            GPT_56_LUNA -> "OpenAI"
        }

    val inputPricePerMillion: Double
        get() = when (this) {
            GEMINI_37_FLASH -> if (isIntroductoryPricingActive) 0.75 else 1.50
            GEMINI_35_FLASH_LITE -> 0.30
            GPT_56_LUNA -> 0.20
        }

    val cachedInputPricePerMillion: Double
        get() = when (this) {
            GEMINI_37_FLASH -> if (isIntroductoryPricingActive) 0.075 else 0.15
            GEMINI_35_FLASH_LITE -> 0.03
            GPT_56_LUNA -> 0.02
        }

    val outputPricePerMillion: Double
        get() = when (this) {
            GEMINI_37_FLASH -> if (isIntroductoryPricingActive) 3.75 else 7.50
            GEMINI_35_FLASH_LITE -> 2.50
            GPT_56_LUNA -> 1.20
        }

    /// 명시적 캐시를 1시간 보관할 때 100만 토큰당 요금입니다.
    /// Gemini는 캐시를 올려두는 동안 별도로 보관료가 붙습니다.
    val cacheStoragePricePerMillionPerHour: Double
        get() = when (this) {
            GEMINI_37_FLASH -> if (isIntroductoryPricingActive) 0.50 else 1.00
            GEMINI_35_FLASH_LITE -> 1.00
            GPT_56_LUNA -> 0.0  // OpenAI는 보관료 없이 캐시 쓰기 요금만 받습니다.
        }

    /// 캐시에 처음 써 넣을 때 입력 단가 대비 배수입니다.
    /// OpenAI 계열에만 있는 개념이라 Gemini는 1.0으로 두고 대신 보관료로 계산합니다.
    val cacheWriteMultiplier: Double
        get() = when (this) {
            GEMINI_37_FLASH -> 1.0
            GEMINI_35_FLASH_LITE -> 1.0
            GPT_56_LUNA -> 1.25
        }

    val isGeminiConversationModel: Boolean
        get() = this == GEMINI_37_FLASH || this == GEMINI_35_FLASH_LITE

    companion object {
        val personalCompanionModels = listOf(GEMINI_37_FLASH, GEMINI_35_FLASH_LITE)

        // 이전 버전이 저장한 모델 식별자를 현재 모델로 이어 붙입니다.
        // 이 표가 없으면 3.6 시절에 쌓인 토큰·요금 기록이 조용히 사라집니다.
        private val legacyIdentifiers = mapOf(
            "gemini-3.6-flash" to GEMINI_37_FLASH
        )

        fun fromStoredValue(value: String): AIModel? =
            entries.firstOrNull { it.rawValue == value } ?: legacyIdentifiers[value]

        // Gemini 3.7 Flash 도입 요금은 2026-12-31까지만 적용되고 2027-01-01부터 정가로 두 배가 됩니다.
        // 대시보드는 "지금 청구되는 금액"을 보여줘야 하므로 단가를 날짜에 따라 고릅니다.
        private val standardPricingStartMillis: Long by lazy {
            Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
                clear()
                set(2027, Calendar.JANUARY, 1)
            }.timeInMillis
        }

        val isIntroductoryPricingActive: Boolean
            get() = System.currentTimeMillis() < standardPricingStartMillis
    }
}
