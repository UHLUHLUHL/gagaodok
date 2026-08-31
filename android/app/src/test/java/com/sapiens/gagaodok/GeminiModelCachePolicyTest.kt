package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.service.PrefixCache
import com.sapiens.gagaodok.service.cacheKey
import com.sapiens.gagaodok.service.normalizePrefixCacheMap
import com.sapiens.gagaodok.service.isMissingCachedContentResponse
import com.sapiens.gagaodok.model.Codec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class GeminiModelCachePolicyTest {
    private val roomId = UUID.fromString("11111111-1111-1111-1111-111111111111")

    @Test
    fun `personal companion choices exclude Luna and keep 37 first`() {
        assertEquals(listOf(AIModel.GEMINI_37_FLASH), AIModel.personalCompanionModels)
        assertTrue(AIModel.personalCompanionModels.none { it == AIModel.GPT_56_LUNA })
    }

    @Test
    fun `방마다 모델별로 캐시 키가 갈린다`() {
        val flash = cacheKey(roomId, AIModel.GEMINI_37_FLASH)
        val luna = cacheKey(roomId, AIModel.GPT_56_LUNA)

        assertNotEquals(flash, luna)
        assertEquals(flash, cacheKey(roomId, AIModel.GEMINI_37_FLASH))
    }

    @Test
    fun `물린 Flash-Lite 식별자는 3_7로 접혀 요금 기록이 남는다`() {
        // 열거에서 뺐지만 저장된 방과 장부에는 이 문자열이 남아 있습니다.
        // null이 되면 방은 전역 기본값으로 튀고 장부의 그 행은 다음 저장 때 사라집니다.
        assertEquals(AIModel.GEMINI_37_FLASH, AIModel.fromStoredValue("gemini-3.5-flash-lite"))
        assertEquals(AIModel.GEMINI_37_FLASH, AIModel.fromStoredValue("gemini-3.6-flash"))
        assertNull(AIModel.fromStoredValue("gemini-9.9-unknown"))
    }

    @Test
    fun `legacy cache without model id belongs only to Gemini 37`() {
        val legacy = Codec.json.decodeFromString<PrefixCache>(
            """{"name":"cachedContents/legacy","coveredTurns":4,"fingerprint":"abc","expiresAtMillis":9999999999999}"""
        )

        assertEquals(AIModel.GEMINI_37_FLASH.rawValue, legacy.modelIdentifier)
        assertEquals(
            setOf(cacheKey(roomId, AIModel.GEMINI_37_FLASH)),
            normalizePrefixCacheMap(mapOf(roomId.toString() to legacy)).keys
        )
    }

    @Test
    fun `only an explicit cached content not found response permits uncached retry`() {
        assertTrue(isMissingCachedContentResponse(404, "CachedContent not found", "cachedContents/a"))
        assertTrue(isMissingCachedContentResponse(400, "{\"status\":\"NOT_FOUND\",\"message\":\"CachedContent expired\"}", "cachedContents/a"))
        assertTrue(!isMissingCachedContentResponse(404, "model not found", "cachedContents/a"))
        assertTrue(!isMissingCachedContentResponse(500, "CachedContent not found", "cachedContents/a"))
    }
}
