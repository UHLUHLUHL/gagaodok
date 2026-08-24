package com.sapiens.gagaodok.service

import android.util.Base64
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.ChatAttachment
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.UUID

// 요청 한 건을 보내고, 오류를 읽고, 사용량을 장부에 적습니다.
// **사용량을 적는 곳은 여기 하나입니다.** 여러 곳에 흩어져 있던 시절에는
// 새로 만든 요청이 장부에서 조용히 빠졌습니다.
internal data class TextStreamResult(
    val text: String,
    val finishReason: String?,
    val sources: List<String>
)

internal const val GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta"

// Gemini 3.7 Flash는 사고 토큰도 출력 토큰 예산에서 함께 소모합니다.
// thinkingLevel이 medium이므로 실제로 보이는 답변 길이보다 여유를 두고 잡습니다.
internal const val GEMINI_MAX_OUTPUT_TOKENS = 8192

const val ERROR_PREFIX = "요청을 처리하는 중 오류가 발생했습니다:"

internal val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()

/// 스트리밍이 아닌 Gemini 요청을 보냅니다.
///
/// **여기서 사용량을 함께 적습니다.** 예전에는 대화 답변만 장부에 적히고
/// 이 길로 나가는 요청 — 구간 요약, 말투 조사, 말투 분석, 다듬기, 미리보기 — 은
/// 하나도 안 적혔습니다. 말투 조사는 검색 그라운딩까지 켜는 무거운 요청인데
/// 앱 화면에서는 공짜처럼 보였습니다. 요금이 과소평가되던 가장 큰 이유입니다.
internal fun AIService.postGemini(body: JSONObject, apiKey: String, roomId: UUID): JSONObject {
    val model = AIModel.GEMINI_37_FLASH
    val request = Request.Builder()
        .url("$GEMINI_BASE/models/${model.rawValue}:generateContent")
        .addHeader("Content-Type", "application/json")
        .addHeader("x-goog-api-key", apiKey)
        .post(body.toString().toRequestBody(JSON_MEDIA))
        .build()
    return client.newCall(request).execute().use {
        val raw = it.body?.string().orEmpty()
        if (!it.isSuccessful) {
            // 실패한 요청도 서버가 입력을 읽은 뒤라면 청구됩니다.
            usage.recordUnreportedRequest(roomId, model)
            throw AIServiceException(errorMessage(raw, it.code, "Gemini"), retryable(it.code))
        }
        val json = JSONObject(raw)
        val reported = json.optJSONObject("usageMetadata")
        if (reported != null) {
            usage.recordUsage(
                roomId, model,
                inputTokens = reported.optInt("promptTokenCount") +
                    reported.optInt("toolUsePromptTokenCount"),
                outputTokens = reported.optInt("candidatesTokenCount") +
                    reported.optInt("thoughtsTokenCount"),
                cachedInputTokens = reported.optInt("cachedContentTokenCount")
            )
        } else {
            usage.recordUnreportedRequest(roomId, model)
        }
        json
    }
}

/// 글 하나를 흘려 받습니다. 대화용 스트림과 달리 말풍선으로 가르지 않습니다.
///
/// 지금은 말투 조사만 씁니다. 오래 걸리는 요청이라, 다 받을 때까지 기다리는 대신
/// 도착하는 대로 넘겨 화면이 무엇을 하고 있는지 보여줄 수 있게 합니다.
internal fun AIService.streamGeminiText(
    body: JSONObject,
    apiKey: String,
    roomId: UUID,
    onPartial: (String) -> Unit
): TextStreamResult {
    val model = AIModel.GEMINI_37_FLASH
    val request = Request.Builder()
        .url("$GEMINI_BASE/models/${model.rawValue}:streamGenerateContent?alt=sse")
        .addHeader("Content-Type", "application/json")
        .addHeader("x-goog-api-key", apiKey)
        .post(body.toString().toRequestBody(JSON_MEDIA))
        .build()

    val text = StringBuilder()
    var finishReason: String? = null
    val sources = linkedSetOf<String>()
    var reported: JSONObject? = null

    try {
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                val raw = response.body?.string().orEmpty()
                throw AIServiceException(
                    errorMessage(raw, response.code, "Gemini"),
                    retryable(response.code)
                )
            }
            val source = response.body?.source() ?: return@use
            while (true) {
                val line = source.readUtf8Line() ?: break
                if (!line.startsWith("data:")) continue
                val payload = line.removePrefix("data:").trim()
                if (payload.isEmpty() || payload == "[DONE]") continue
                val json = runCatching { JSONObject(payload) }.getOrNull() ?: continue

                json.optJSONObject("usageMetadata")?.let { reported = it }
                val candidate = json.optJSONArray("candidates")?.optJSONObject(0) ?: continue
                candidate.optString("finishReason").takeIf { it.isNotEmpty() }
                    ?.let { finishReason = it }
                candidate.optJSONObject("groundingMetadata")
                    ?.optJSONArray("groundingChunks")?.let { chunks ->
                        for (i in 0 until chunks.length()) {
                            chunks.optJSONObject(i)?.optJSONObject("web")?.optString("title")
                                ?.takeIf { title -> title.isNotEmpty() }?.let { sources += it }
                        }
                    }

                val parts = candidate.optJSONObject("content")?.optJSONArray("parts") ?: continue
                var grew = false
                for (i in 0 until parts.length()) {
                    val piece = parts.optJSONObject(i)?.optString("text").orEmpty()
                    if (piece.isEmpty()) continue
                    text.append(piece)
                    grew = true
                }
                if (grew) onPartial(text.toString())
            }
        }
    } finally {
        val metadata = reported
        if (metadata != null) {
            usage.recordUsage(
                roomId, model,
                inputTokens = metadata.optInt("promptTokenCount") +
                    metadata.optInt("toolUsePromptTokenCount"),
                outputTokens = metadata.optInt("candidatesTokenCount") +
                    metadata.optInt("thoughtsTokenCount"),
                cachedInputTokens = metadata.optInt("cachedContentTokenCount")
            )
        } else {
            usage.recordUnreportedRequest(roomId, model)
        }
    }

    return TextStreamResult(text.toString(), finishReason, sources.toList())
}

/// 그대로 다시 보내면 될 만한 실패인지입니다.
///
/// 429는 잠깐 몰린 것이고 5xx는 저쪽 사정이라 다시 보낼 값어치가 있습니다.
/// 400·401·403은 요청이나 키가 잘못된 것이라 몇 번을 보내도 같습니다.
internal fun AIService.retryable(code: Int): Boolean = code == 429 || code >= 500

internal fun AIService.joinParts(candidate: JSONObject): String {
    val parts = candidate.optJSONObject("content")?.optJSONArray("parts") ?: return ""
    return buildString {
        for (i in 0 until parts.length()) {
            val text = parts.optJSONObject(i)?.optString("text").orEmpty()
            if (text.isEmpty()) continue
            if (isNotEmpty()) append("\n")
            append(text)
        }
    }
}

internal fun AIService.errorMessage(raw: String, code: Int, provider: String): String {
    val message = runCatching {
        JSONObject(raw).optJSONObject("error")?.optString("message")
    }.getOrNull()
    return "$provider 오류: ${message?.takeIf { it.isNotEmpty() } ?: "HTTP $code"}"
}

internal fun AIService.emptyResponseMessage(finishReason: String?): String = when (finishReason) {
    "MAX_TOKENS" -> "답변이 출력 토큰 한도에 먼저 걸렸습니다. 질문을 나눠서 다시 보내주세요."
    "SAFETY", "PROHIBITED_CONTENT" ->
        "Gemini 안전 정책에 걸려 답변이 생성되지 않았습니다. 표현을 바꿔 다시 시도해주세요."
    "RECITATION" -> "저작권 보호 정책 때문에 답변이 중단되었습니다. 질문을 다르게 표현해주세요."
    null, "" -> "Gemini가 빈 응답을 반환했습니다."
    else -> "Gemini가 빈 응답을 반환했습니다. (사유: $finishReason)"
}

// MARK: - 말풍선 분리

internal fun AIService.decodeText(attachment: ChatAttachment): String? = runCatching {
    String(Base64.decode(attachment.dataBase64, Base64.DEFAULT), Charsets.UTF_8)
}.getOrNull()
