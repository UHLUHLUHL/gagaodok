package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.data.CacheDecision
import com.sapiens.gagaodok.data.CacheObservation
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.Codec
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID

// 명시적 캐시(cachedContents)를 만들고 쓰고 버리는 규칙입니다.
// 언제 만들고 언제 안 만드는지가 요금의 대부분을 정합니다.
/// Gemini의 implicit 캐시는 "완전히 똑같은 요청"이 짧은 간격으로 반복될 때만 걸립니다.
/// 채팅처럼 턴이 계속 붙는 패턴에서는 접두사가 같아도 적중하지 않아 실측 적중률이 0%였습니다.
/// 그래서 대화 접두사를 명시적 캐시(cachedContents)로 올려두고 새 턴만 보냅니다.
@Serializable
internal data class PrefixCache(
    val name: String,          // cachedContents/xxxx
    val coveredTurns: Int,     // 이 캐시가 덮는 contents 앞부분의 개수
    val fingerprint: String,   // 덮은 구간이 편집되지 않았는지 확인하는 지문
    val expiresAtMillis: Long,
    /// 이 캐시에 올라가 있는 토큰 수입니다. 다시 만들 값어치가 있는지 따질 때 씁니다.
    /// 예전 파일에는 없던 값이라 기본값을 둡니다.
    val tokenCount: Int = 0,
    /// 예전 파일에는 없으므로 3.7로만 해석합니다. 다른 모델에 재사용하지 않습니다.
    val modelIdentifier: String = AIModel.GEMINI_37_FLASH.rawValue
)

internal const val CACHE_TTL_SECONDS = 900

// Gemini 3.7 Flash 명시적 캐시는 4,096토큰 미만이면 생성이 거부됩니다. 로컬 추정값이
// 실제보다 조금 클 수 있어 약 12% 여유를 둡니다. 짧은 방에서 실패할 캐시 요청을 보내지 않습니다.
internal const val MINIMUM_CACHE_TOKENS = 4600

// 캐시를 다시 만들 기준입니다. 자세한 셈은 `refreshPrefixCache`에 적었습니다.
// 짧은 대화에서 몇 마디 붙었다고 다시 만들지 않게 하는 바닥값입니다.
internal const val CACHE_REFRESH_MIN_TAIL_TOKENS = 2000

// TTL이 이만큼도 안 남았으면 꼬리가 짧아도 새로 만듭니다. 그대로 두면
// 곧 만료되어 다음 요청이 통째로 전액이 됩니다.
internal const val CACHE_REFRESH_TTL_FLOOR_MILLIS = 240_000L

// 직전 요청이 이 안에 있었으면 "대화 중"으로 봅니다. 그때만 첫 캐시를 만듭니다.
internal const val CACHE_BURST_WINDOW_MILLIS = 300_000L

internal fun cacheKey(roomId: UUID, model: AIModel): String = "${roomId}|${model.rawValue}"

internal fun normalizePrefixCacheMap(caches: Map<String, PrefixCache>): MutableMap<String, PrefixCache> =
    caches.entries.associate { (storedKey, cache) ->
        val key = if ('|' in storedKey) storedKey else "$storedKey|${cache.modelIdentifier}"
        key to cache
    }.toMutableMap()

internal fun AIService.persistCaches() {
    val snapshot = synchronized(prefixCaches) { prefixCaches.toMap() }
    scope.launch { runCatching { cacheFile.writeText(Codec.json.encodeToString(snapshot)) } }
}

internal fun AIService.usablePrefixCache(
    roomId: UUID,
    model: AIModel,
    contents: List<JSONObject>,
    system: String,
    apiKey: String
): PrefixCache? {
    val key = cacheKey(roomId, model)
    val cache = synchronized(prefixCaches) { prefixCaches[key] } ?: return null
    if (cache.modelIdentifier != model.rawValue) {
        dropCache(key, deleteRemote = false, apiKey = apiKey)
        return null
    }

    // 만료된 것은 서버에도 없으므로 지울 것이 없습니다.
    if (cache.expiresAtMillis <= System.currentTimeMillis() + 30_000) {
        dropCache(key, deleteRemote = false, apiKey = apiKey)
        return null
    }

    // 캐시가 덮는 만큼의 턴이 남아 있고, 그 구간이 편집되지 않았을 때만 재사용합니다.
    //
    // **여기서 그냥 `null`만 돌려주면 안 됩니다.** 예전에는 그랬는데, 메시지를
    // 하나 고치거나 지워서 대화가 짧아지면 이 조건에 걸려 캐시를 안 쓰고,
    // 갱신하는 쪽은 "이미 더 많이 덮는 캐시가 있다"며 그냥 돌아갔습니다.
    // 그래서 그 방은 대화가 예전 길이를 되찾을 때까지 캐시 없이 전액을 내면서,
    // 쓰지도 않는 캐시의 **보관료는 계속 냈습니다.** 지금은 버리고 다시 만듭니다.
    if (contents.size <= cache.coveredTurns) {
        dropCache(key, deleteRemote = true, apiKey = apiKey)
        return null
    }
    if (fingerprint(contents.take(cache.coveredTurns), system) != cache.fingerprint) {
        dropCache(key, deleteRemote = true, apiKey = apiKey)
        return null
    }
    return cache
}

/// 로컬 기록에서 지우고, 서버에 남아 있을 것이면 그것도 지웁니다.
///
/// 서버 쪽을 안 지우면 아무도 안 쓰는 캐시가 TTL이 다할 때까지 보관료를 먹습니다.
internal fun AIService.dropCache(key: String, deleteRemote: Boolean, apiKey: String) {
    val removed = synchronized(prefixCaches) { prefixCaches.remove(key) }
    persistCaches()
    if (deleteRemote && removed != null) {
        scope.launch { deleteCache(removed.name, apiKey) }
    }
}

/// 직전 요청 시각을 꺼내면서 지금 시각으로 갱신합니다.
internal fun AIService.markRequest(roomId: UUID, model: AIModel): Long? = synchronized(lastRequestAt) {
    val key = cacheKey(roomId, model)
    val previous = lastRequestAt[key]
    lastRequestAt[key] = System.currentTimeMillis()
    previous
}

internal suspend fun AIService.refreshPrefixCache(
    roomId: UUID,
    model: AIModel,
    contents: List<JSONObject>,
    system: String,
    apiKey: String,
    previousRequestAt: Long?,
    measure: Boolean = false
) {
    val key = cacheKey(roomId, model)
    // 막지 않으면 같은 방에 대해 갱신이 겹치면서 캐시가 여러 개 만들어지고
    // 이전 것이 지워지지 않습니다.
    synchronized(refreshingRooms) {
        if (key in refreshingRooms) return
        refreshingRooms += key
    }
    try {
        val previous = synchronized(prefixCaches) { prefixCaches[key] }
        val now = System.currentTimeMillis()

        // 사진도 함께 셉니다. 글자만 세던 시절에는 사진이 0자로 잡혀서,
        // 사진이 많아 제일 비싼 방이 바로 그 이유로 캐시를 못 받았습니다.
        val estimated = estimateTokens(contents) + TokenEstimator.textTokens(system)
        fun observe(decision: CacheDecision, actualTokens: Int = 0) {
            if (measure) measurement.observeCache(
                CacheObservation(key, estimated, decision, actualTokens)
            )
        }
        if (estimated < MINIMUM_CACHE_TOKENS) {
            observe(CacheDecision.BELOW_MINIMUM)
            return
        }

        if (previous == null) {
            // **아직 캐시가 없으면, 대화가 이어지는 중일 때만 만듭니다.**
            //
            // 메신저는 몰아서 쓰고 한참 쉽니다. 예전에는 한참 만에 한 마디 던져도
            // 그 뒤에 대화 전체를 캐시로 올렸는데, 사용자가 바로 앱을 닫으면
            // 그 캐시는 아무도 안 읽고 TTL이 다할 때까지 보관료만 먹었습니다.
            // 올리는 값까지 치면 그 한 마디의 요금을 두 배로 낸 셈입니다.
            //
            // 직전 요청이 얼마 전이면 지금은 대화 중이고, 다음 요청도 TTL 안에
            // 올 가능성이 높습니다. 그때만 올립니다. 대신 한 묶음의 두 번째
            // 메시지까지는 캐시 없이 갑니다 — 안 쓸 캐시를 만드는 것보다 낫습니다.
            //
            // 5분은 **정한 값입니다.** 실제 사용 기록을 보고 뽑은 값이 아닙니다.
            val ongoing = previousRequestAt != null &&
                now - previousRequestAt <= CACHE_BURST_WINDOW_MILLIS
            if (!ongoing) {
                observe(CacheDecision.NOT_BURST)
                return
            }
        }

        if (previous != null) {
            // 이미 같은 구간을 덮고 있으면 다시 만들 것이 없습니다.
            if (previous.coveredTurns >= contents.size &&
                previous.expiresAtMillis > now + 60_000
            ) {
                observe(CacheDecision.CACHE_CURRENT)
                return
            }

            // **매 턴 다시 만들지 않습니다.**
            //
            // 예전에는 답변을 받을 때마다 대화 접두사 전체를 새 캐시로 올리고
            // 옛것을 지웠습니다. 한 턴 아끼자고 수만 토큰을 매번 다시 올린 셈입니다.
            // 캐시를 만드는 요청은 그 자체로 청구되고 보관료도 따로 붙는 반면,
            // 안 만들고 넘어갔을 때 더 내는 것은 **새로 붙은 꼬리만큼**뿐입니다.
            //
            // 그래서 꼬리가 캐시의 5분의 1보다 커졌을 때만 새로 만듭니다.
            // 그 아래에서는 새로 만드는 값이 아끼는 값보다 큽니다.
            val tail = estimateTokens(contents.drop(previous.coveredTurns))
            val worthIt = tail >= maxOf(CACHE_REFRESH_MIN_TAIL_TOKENS, previous.tokenCount / 5)
            val expiringSoon = previous.expiresAtMillis <= now + CACHE_REFRESH_TTL_FLOOR_MILLIS
            if (!worthIt && !expiringSoon) {
                observe(CacheDecision.TAIL_TOO_SMALL)
                return
            }
        }
        observe(CacheDecision.CREATE_ATTEMPT)
        val payload = JSONObject()
            .put("model", "models/${model.rawValue}")
            .put("systemInstruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", system))))
            .put("contents", JSONArray().apply { contents.forEach { put(it) } })
            .put("ttl", "${CACHE_TTL_SECONDS}s")

        val request = Request.Builder()
            .url("$GEMINI_BASE/cachedContents")
            .addHeader("Content-Type", "application/json")
            .addHeader("x-goog-api-key", apiKey)
            .post(payload.toString().toRequestBody(JSON_MEDIA))
            .build()

        // 캐시는 요금 최적화 수단일 뿐이라 실패해도 대화에는 영향이 없습니다. 조용히 넘어갑니다.
        val json = try {
            client.newCall(request).execute().use {
                if (!it.isSuccessful) {
                    observe(CacheDecision.HTTP_FAILURE)
                    return
                }
                JSONObject(it.body?.string().orEmpty())
            }
        } catch (_: Throwable) {
            observe(CacheDecision.LOCAL_FAILURE)
            return
        }
        val name = json.optString("name").takeIf { it.isNotEmpty() } ?: run {
            observe(CacheDecision.LOCAL_FAILURE)
            return
        }

        val cachedTokens = json.optJSONObject("usageMetadata")?.optInt("totalTokenCount") ?: 0
        observe(CacheDecision.CREATE_SUCCESS, cachedTokens)
        synchronized(prefixCaches) {
            prefixCaches[key] = PrefixCache(
                name = name,
                coveredTurns = contents.size,
                fingerprint = fingerprint(contents, system),
                expiresAtMillis = System.currentTimeMillis() + CACHE_TTL_SECONDS * 1000L,
                tokenCount = if (cachedTokens > 0) cachedTokens else estimated,
                modelIdentifier = model.rawValue
            )
        }
        persistCaches()

        // 올린 토큰과 보관량을 함께 적습니다.
        //
        // **올린 토큰을 입력 요금으로 칩니다.** 캐시를 만드는 요청이 청구되는지
        // 문서로 확인하지는 못했습니다. 확실하지 않을 때는 비싼 쪽으로 잡습니다 —
        // 화면의 숫자가 실제보다 적은 것이 많은 것보다 나쁩니다.
        //
        // 보관량은 실제 보관 시간이 아니라 TTL 전체로 잡습니다. 다음 갱신 때
        // 이전 것을 지우므로 실제로는 그보다 짧습니다. 이것도 넉넉한 쪽입니다.
        if (cachedTokens > 0) {
            usage.recordCacheCreation(
                roomId, model,
                tokens = cachedTokens,
                tokenHours = cachedTokens * (CACHE_TTL_SECONDS / 3600.0)
            )
        }

        // 이전 캐시는 보관 요금이 붙으므로 새 캐시가 자리 잡은 뒤 지웁니다.
        previous?.let { deleteCache(it.name, apiKey) }
    } finally {
        synchronized(refreshingRooms) { refreshingRooms -= key }
    }
}

internal fun AIService.deleteCache(name: String, apiKey: String) {
    runCatching {
        client.newCall(
            Request.Builder().url("$GEMINI_BASE/$name")
                .addHeader("x-goog-api-key", apiKey)
                .delete().build()
        ).execute().close()
    }
}

internal fun AIService.fingerprint(contents: List<JSONObject>, system: String): String {
    val digest = MessageDigest.getInstance("SHA-256")
    digest.update(system.toByteArray())
    // JSONObject.toString()은 키 순서를 넣은 순서대로 유지합니다.
    // contents를 만드는 코드가 한 곳뿐이라 같은 대화면 같은 문자열이 나옵니다.
    contents.forEach { digest.update(it.toString().toByteArray()) }
    return digest.digest().joinToString("") { "%02x".format(it) }
}

/// Gemini `contents` 배열 하나가 몇 토큰쯤 되는지 어림합니다.
internal fun AIService.estimateTokens(contents: List<JSONObject>): Int {
    var total = 0
    for (item in contents) {
        val parts = item.optJSONArray("parts") ?: continue
        for (i in 0 until parts.length()) {
            val part = parts.optJSONObject(i) ?: continue
            part.optString("text").takeIf { it.isNotEmpty() }?.let {
                total += TokenEstimator.textTokens(it)
            }
            part.optJSONObject("inlineData")?.let { inline ->
                val mime = inline.optString("mimeType")
                val data = inline.optString("data")
                // PDF는 페이지 단위라 규칙이 다릅니다. 사진 한 장 몫으로만 잡아 둡니다.
                total += if (mime.startsWith("image/")) TokenEstimator.imageTokensFromBase64(data)
                else TokenEstimator.FALLBACK_IMAGE_TOKENS
            }
        }
    }
    return total
}

// MARK: - 구간 요약
