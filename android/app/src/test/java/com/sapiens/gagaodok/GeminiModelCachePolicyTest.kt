package com.sapiens.gagaodok

import com.sapiens.gagaodok.data.MeasurementPolicy
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.service.CACHE_BURST_WINDOW_MILLIS
import com.sapiens.gagaodok.service.CACHE_REFRESH_MIN_TAIL_TOKENS
import com.sapiens.gagaodok.service.CACHE_TTL_SECONDS
import com.sapiens.gagaodok.service.MINIMUM_CACHE_TOKENS
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
    fun `캐시는 30분 동안 유지된다`() {
        // 15분에서 올렸습니다. 실측에서 대화 한 판이 25~35분 이어지는데 15분은
        // 그 절반만 덮어, 만료 4분 전 규칙 때문에 세션마다 접두사를 두 번 다시
        // 올리고 있었습니다.
        assertEquals(1800, CACHE_TTL_SECONDS)
    }

    @Test
    fun `측정 정책은 실제로 동작 중인 캐시 상수를 그대로 담는다`() {
        // 예전에는 이 값들이 하드코딩이라, 정책을 바꿔도 측정 기록은 옛 값을
        // 가리켰습니다. 그러면 구간끼리 견줄 때 어느 정책이었는지 알 수 없습니다.
        val policy = MeasurementPolicy.current()

        assertEquals(CACHE_TTL_SECONDS, policy.cacheTtlSeconds)
        assertEquals(MINIMUM_CACHE_TOKENS, policy.minimumCacheTokens)
        assertEquals(CACHE_REFRESH_MIN_TAIL_TOKENS, policy.refreshTailMinimumTokens)
        assertEquals((CACHE_BURST_WINDOW_MILLIS / 1000L).toInt(), policy.burstWindowSeconds)
    }

    @Test
    fun `personal companion choices exclude Luna and keep 37 first`() {
        // 3.8이 기본이고 3.7도 계속 고를 수 있습니다.
        assertEquals(
            // DeepSeek(실험)는 폰 빌드에서만 고를 수 있습니다.
            if (BuildConfig.TABLET_MENTOR) listOf(AIModel.GEMINI_38_FLASH, AIModel.GEMINI_37_FLASH)
            else listOf(AIModel.GEMINI_38_FLASH, AIModel.GEMINI_37_FLASH, AIModel.DEEPSEEK_FLASH),
            AIModel.personalCompanionModels,
        )
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
