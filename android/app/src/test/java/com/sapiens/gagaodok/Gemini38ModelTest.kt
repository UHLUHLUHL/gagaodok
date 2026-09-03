package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.AIModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 3.8을 들이면서 3.7을 남겼습니다. 두 모델이 함께 있는 동안 지켜져야 할 것들입니다.
 */
class Gemini38ModelTest {
    @Test fun `both gemini models keep their own wire identifiers`() {
        assertEquals("gemini-3.8-flash", AIModel.GEMINI_38_FLASH.rawValue)
        assertEquals("gemini-3.7-flash", AIModel.GEMINI_37_FLASH.rawValue)
    }

    @Test fun `a room saved with 3_7 still opens as 3_7`() {
        // 3.7을 남긴 덕에 이관 표가 필요 없습니다. 저장값이 그대로 해석됩니다.
        assertEquals(AIModel.GEMINI_37_FLASH, AIModel.fromStoredValue("gemini-3.7-flash"))
        assertEquals(AIModel.GEMINI_38_FLASH, AIModel.fromStoredValue("gemini-3.8-flash"))
    }

    @Test fun `3_8 counts as a gemini model everywhere it matters`() {
        // 이걸 놓치면 3.8이 "Gemini가 아닌 것"이 되어 API 호출이 막히고
        // 배지가 GPT 색으로 나옵니다.
        assertTrue(AIModel.GEMINI_38_FLASH.isGeminiConversationModel)
        assertTrue(AIModel.GEMINI_37_FLASH.isGeminiConversationModel)
        assertFalse(AIModel.GPT_56_LUNA.isGeminiConversationModel)
        assertEquals("Google", AIModel.GEMINI_38_FLASH.providerName)
        assertEquals("Gemini", AIModel.GEMINI_38_FLASH.shortName)
    }

    @Test fun `3_8 is priced exactly like 3_7`() {
        // 2026-09-02 공식 요금표 확인: 단가도 도입가 종료일도 같습니다.
        val new = AIModel.GEMINI_38_FLASH
        val old = AIModel.GEMINI_37_FLASH
        assertEquals(old.inputPricePerMillion, new.inputPricePerMillion, 0.0)
        assertEquals(old.outputPricePerMillion, new.outputPricePerMillion, 0.0)
        assertEquals(old.cachedInputPricePerMillion, new.cachedInputPricePerMillion, 0.0)
        assertEquals(old.cacheStoragePricePerMillionPerHour, new.cacheStoragePricePerMillionPerHour, 0.0)
        assertEquals(old.cacheWriteMultiplier, new.cacheWriteMultiplier, 0.0)
    }

    @Test fun `the personal companion list offers 3_8 first`() {
        assertEquals(AIModel.GEMINI_38_FLASH, AIModel.personalCompanionModels.first())
        assertTrue(AIModel.personalCompanionModels.contains(AIModel.GEMINI_37_FLASH))
    }

    @Test fun `the two models are told apart on screen`() {
        assertEquals("Gemini 3.8 Flash", AIModel.GEMINI_38_FLASH.displayName)
        assertEquals("Gemini 3.7 Flash", AIModel.GEMINI_37_FLASH.displayName)
    }
}
