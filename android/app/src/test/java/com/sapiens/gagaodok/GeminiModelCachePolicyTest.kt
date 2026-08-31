package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.service.PrefixCache
import com.sapiens.gagaodok.service.cacheKey
import com.sapiens.gagaodok.service.normalizePrefixCacheMap
import com.sapiens.gagaodok.service.isMissingCachedContentResponse
import com.sapiens.gagaodok.model.Codec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class GeminiModelCachePolicyTest {
    private val roomId = UUID.fromString("11111111-1111-1111-1111-111111111111")

    @Test
    fun `personal companion choices exclude Luna and keep 37 first`() {
        assertEquals(
            listOf(AIModel.GEMINI_37_FLASH, AIModel.GEMINI_35_FLASH_LITE),
            AIModel.personalCompanionModels
        )
        assertTrue(AIModel.personalCompanionModels.none { it == AIModel.GPT_56_LUNA })
    }

    @Test
    fun `same room has independent cache keys per Gemini model`() {
        val flash = cacheKey(roomId, AIModel.GEMINI_37_FLASH)
        val lite = cacheKey(roomId, AIModel.GEMINI_35_FLASH_LITE)

        assertNotEquals(flash, lite)
        assertEquals(flash, cacheKey(roomId, AIModel.GEMINI_37_FLASH))
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
