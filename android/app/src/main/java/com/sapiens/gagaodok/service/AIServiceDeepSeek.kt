package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.data.SecureStore
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.Codec
import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageSender
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

// DeepSeek(실험) 쪽 길입니다. **도입이 확정되지 않았습니다.**
//
// 대화 압축·기억·호감도·측정은 Gemini와 똑같이 거쳐야 하므로 요청을 따로 조립하지
// 않습니다. Gemini 형식으로 조립된 본문을 **보내기 직전에** Chat Completions로 옮기고,
// 받은 응답을 다시 Gemini 모양(`candidates`·`usageMetadata`)으로 되돌립니다.
// 그래서 갈라지는 곳은 보내는 세 곳(`streamGemini`, `postGemini`, `streamGeminiText`)뿐입니다.
//
// 걷어낼 때: 이 파일, `AIModel.DEEPSEEK_FLASH`, `SecureStore.Credential.DEEPSEEK`,
// 그리고 `DEEPSEEK_FLASH`를 부르는 분기를 지웁니다.
//
// 근거(2026-09-17 확인):
// - 요청 형식·사용량 필드: https://api-docs.deepseek.com/api/create-chat-completion
// - 사고 설정: https://api-docs.deepseek.com/guides/thinking_mode
// - 이미지 입력: https://api-docs.deepseek.com/guides/vision
// - JSON 출력: https://api-docs.deepseek.com/guides/json_mode
// - 캐시: https://api-docs.deepseek.com/guides/kv_cache — 서버가 알아서 디스크에 캐시합니다.
//   명시적 캐시·TTL·두 칸 물림 같은 Gemini 규칙은 여기에 적용하지 않습니다.

internal const val DEEPSEEK_CHAT_URL = "https://api.deepseek.com/chat/completions"

/// 요청 본문 한도(이미지 포함)가 48 MiB입니다. 문서에 적힌 형식만 보냅니다.
private val DEEPSEEK_IMAGE_TYPES = setOf("image/jpeg", "image/png", "image/gif", "image/webp")

/// 그 모델로 보낼 키입니다. 없으면 어느 키가 필요한지 알려 줍니다.
internal fun AIService.apiKeyFor(model: AIModel): String {
    require(model.usesSharedConversationPath) { "Unsupported model for the shared path." }
    val credential = if (model == AIModel.DEEPSEEK_FLASH) SecureStore.Credential.DEEPSEEK
        else SecureStore.Credential.GEMINI
    return SecureStore.apiKey(appContext, credential)
        ?: throw AIServiceException("설정에서 ${credential.displayName} API 키를 먼저 등록해주세요.")
}

internal fun deepSeekRequest(
    body: JSONObject,
    apiKey: String,
    stream: Boolean,
    chatReply: Boolean = false
): Request =
    Request.Builder()
        .url(DEEPSEEK_CHAT_URL)
        .addHeader("Content-Type", "application/json")
        .addHeader("Authorization", "Bearer $apiKey")
        .post(geminiBodyToDeepSeek(body, stream, chatReply).toString().toRequestBody(JSON_MEDIA))
        .build()

/// 챗봇방 답변에서 DeepSeek 사고를 끄는가.
///
/// **끕니다(사용자 결정, 2026-09-17).** 챗봇 대화는 첫 글자까지의 시간과 비용이 먼저이고,
/// 사고를 켜 두면 안 보이는 사고 토큰이 출력 단가로 붙습니다. 사고를 끄면 모델 출력이
/// 본문뿐이라, 다음 요청에 되돌려 보내는 답과 서버 캐시의 "출력 끝" 단위도 맞습니다.
/// 기억 요약·말투 분석 같은 보조 호출은 이 설정을 따르지 않습니다(요청에 적힌 사고 수준).
internal fun deepSeekChatThinkingDisabled(mode: ChatMode): Boolean = mode == ChatMode.COMPANION

/// 챗봇방 답변의 `temperature`입니다. 사고를 끈 상태에서만 효과가 있습니다(사고 모드에서는
/// 서버가 무시, 문서). 문서 기본값은 1입니다.
///
/// **1.05는 사용자 결정(2026-09-17)이고 측정 근거는 아직 없습니다.** 문장이 단조로워지지
/// 않게 조금 올린 값입니다. 답이 흐트러지면 1로 되돌립니다.
internal const val DEEPSEEK_CHAT_TEMPERATURE = 1.05

/// 대화 답변을 조용히 다시 보내기 전에 기다리는 시간입니다. [attempt]는 1부터 셉니다.
///
/// 곧바로 다시 보내면 429(요청 과다)가 연달아 나기 쉬워 1초, 3초를 둡니다. 이 값은
/// **짐작**입니다. 문서에 권장 대기 시간이 없습니다. Gemini 대화는 기다리지 않습니다(기존 동작).
internal fun deepSeekRetryDelayMillis(attempt: Int): Long = when (attempt) {
    1 -> 1_000L
    else -> 3_000L
}

/// DeepSeek가 쓴 기억 초안을 읽는 해석기입니다.
///
/// Gemini는 `responseSchema`로 모양을 강제하지만 DeepSeek는 `json_object`(올바른 JSON)까지만
/// 보장합니다. 모르는 칸 하나 때문에 기억 갱신 전체가 실패하지 않도록 **그 칸만** 무시합니다.
/// 빠진 필드·틀린 형식은 여전히 실패하고, 구간·분량·상태 검사도 그대로 거칩니다.
internal val deepSeekMemoryJson = Json { encodeDefaults = true; ignoreUnknownKeys = true }

/// 글 없이 끝났을 때 다시 보내 볼 만한 사유인가.
///
/// 서버 자원 부족(`insufficient_system_resource`, 문서의 `finish_reason` 값)은 요청 탓이
/// 아니라 다시 보낼 값어치가 있습니다. 콘텐츠 필터나 출력 한도는 다시 보내도 같습니다.
internal fun isDeepSeekRetryableFinish(finishReason: String?): Boolean =
    finishReason == "DEEPSEEK_INSUFFICIENT_SYSTEM_RESOURCE"

/// 글 없이 끝났을 때 보여 줄 문구입니다. `emptyResponseMessage`가 DeepSeek 방에서 부릅니다.
internal fun deepSeekEmptyResponseMessage(finishReason: String?): String = when (finishReason) {
    "MAX_TOKENS" -> "답변이 출력 토큰 한도에 먼저 걸렸습니다. 질문을 나눠서 다시 보내주세요."
    "DEEPSEEK_CONTENT_FILTER" -> "DeepSeek 콘텐츠 필터에 걸려 답변이 생성되지 않았습니다. 표현을 바꿔 다시 시도해주세요."
    "DEEPSEEK_INSUFFICIENT_SYSTEM_RESOURCE" -> "DeepSeek 서버 자원이 부족해 답변이 중단되었습니다. 잠시 후 다시 시도해주세요."
    null, "" -> "DeepSeek가 빈 응답을 반환했습니다."
    else -> "DeepSeek가 빈 응답을 반환했습니다. (사유: $finishReason)"
}

/// Gemini `generateContent` 본문을 DeepSeek Chat Completions 본문으로 옮깁니다.
///
/// **검색·링크 읽기·영상 같은 Google 전용 입력은 받지 않습니다.** 조용히 빼고 보내면
/// 근거 없는 답이 근거 있는 답처럼 돌아옵니다. 그런 요청은 Gemini로 보내야 합니다
/// (`googleToolsModel`).
///
/// [chatReply]가 참이면 챗봇방 답변입니다. 사고를 끄고 `temperature`를 적습니다
/// ([deepSeekChatThinkingDisabled]). 본문에 적힌 사고 수준보다 우선합니다.
internal fun geminiBodyToDeepSeek(body: JSONObject, stream: Boolean, chatReply: Boolean = false): JSONObject {
    require(!body.has("tools")) { "Google tools cannot be sent to DeepSeek." }
    require(!body.has("cachedContent")) { "Gemini explicit caches do not apply to DeepSeek." }
    val config = body.optJSONObject("generationConfig")
    val messages = JSONArray()

    var system = joinTextParts(body.optJSONObject("systemInstruction")?.optJSONArray("parts"))
    // Gemini는 스키마를 따로 받지만 DeepSeek는 `json_object`만 받습니다. 문서가 프롬프트에
    // "json"이라는 낱말과 형식 예시를 넣으라고 하므로 스키마를 지침 뒤에 붙입니다.
    config?.optJSONObject("responseSchema")?.let { schema ->
        system += "\n\n# 출력 형식\n반드시 아래 스키마를 따르는 json 객체 하나만 출력한다.\n$schema"
    }
    if (system.isNotEmpty()) messages.put(JSONObject().put("role", "system").put("content", system))

    val contents = body.optJSONArray("contents") ?: JSONArray()
    for (i in 0 until contents.length()) {
        val turn = contents.optJSONObject(i) ?: continue
        val assistant = turn.optString("role") == "model"
        val parts = turn.optJSONArray("parts") ?: JSONArray()
        val blocks = JSONArray()
        var hasImage = false
        for (j in 0 until parts.length()) {
            val part = parts.optJSONObject(j) ?: continue
            require(!part.has("fileData")) { "Google file inputs cannot be sent to DeepSeek." }
            if (part.has("text")) {
                blocks.put(JSONObject().put("type", "text").put("text", part.optString("text")))
                continue
            }
            val inline = part.optJSONObject("inlineData") ?: continue
            val mime = inline.optString("mimeType")
            if (!assistant && mime in DEEPSEEK_IMAGE_TYPES) {
                hasImage = true
                blocks.put(
                    JSONObject().put("type", "image_url").put(
                        "image_url",
                        JSONObject().put("url", "data:$mime;base64,${inline.optString("data")}")
                    )
                )
            } else {
                // PDF 등은 이 모델이 받지 않습니다. 빠졌다는 사실은 모델에게도 알립니다.
                blocks.put(
                    JSONObject().put("type", "text")
                        .put("text", "[첨부 파일($mime)은 이 모델에서 읽을 수 없어 빠졌습니다.]")
                )
            }
        }
        if (blocks.length() == 0) continue
        val message = JSONObject().put("role", if (assistant) "assistant" else "user")
        if (hasImage) {
            message.put("content", blocks)
        } else {
            val text = (0 until blocks.length()).joinToString("\n\n") { blocks.getJSONObject(it).optString("text") }
            message.put("content", text)
        }
        messages.put(message)
    }

    val out = JSONObject()
        .put("model", AIModel.DEEPSEEK_FLASH.rawValue)
        .put("messages", messages)
    config?.optInt("maxOutputTokens", 0)?.takeIf { it > 0 }?.let { out.put("max_tokens", it) }
    if (chatReply) {
        out.put("thinking", JSONObject().put("type", "disabled"))
        out.put("temperature", DEEPSEEK_CHAT_TEMPERATURE)
    } else {
        config?.optJSONObject("thinkingConfig")?.optString("thinkingLevel")
            ?.takeIf { it.isNotEmpty() }
            ?.let { applyThinking(out, it) }
    }
    if (config?.optString("responseMimeType") == "application/json") {
        out.put("response_format", JSONObject().put("type", "json_object"))
    }
    if (stream) {
        out.put("stream", true)
        // 이게 없으면 스트림 끝에 사용량이 오지 않아 요금 장부가 비어 버립니다.
        out.put("stream_options", JSONObject().put("include_usage", true))
    }
    // `safetySettings`는 옮기지 않습니다. DeepSeek에는 대응하는 항목이 없습니다.
    return out
}

/// Gemini의 사고 수준을 DeepSeek 설정으로 옮깁니다.
///
/// **대응 관계는 짐작입니다.** 두 모델의 사고량이 같은 이름에서 같다는 근거는 없습니다.
/// DeepSeek는 켜고 끄기와 `low/high/max`만 있고(`medium`은 서버가 `high`로 바꿈),
/// Gemini의 `minimal`은 사실상 끄는 쪽이라 끕니다.
private fun applyThinking(out: JSONObject, level: String) {
    when (level) {
        "minimal" -> out.put("thinking", JSONObject().put("type", "disabled"))
        "low" -> out.put("thinking", JSONObject().put("type", "enabled")).put("reasoning_effort", "low")
        else -> out.put("thinking", JSONObject().put("type", "enabled")).put("reasoning_effort", "high")
    }
}

private fun joinTextParts(parts: JSONArray?): String {
    if (parts == null) return ""
    return (0 until parts.length())
        .mapNotNull { parts.optJSONObject(it)?.takeIf { p -> p.has("text") }?.optString("text") }
        .joinToString("\n\n")
}

/// DeepSeek 응답(한 번에 받은 것이든 스트림 조각이든)을 Gemini 모양으로 바꿉니다.
///
/// 사고 내용(`reasoning_content`)은 옮기지 않습니다. 화면에 보일 글이 아니고,
/// 도구를 안 쓰는 대화에서는 다음 요청에 돌려보낼 필요도 없습니다(사고 모드 문서).
internal fun deepSeekResponseToGemini(json: JSONObject): JSONObject {
    val out = JSONObject()
    val choice = json.optJSONArray("choices")?.optJSONObject(0)
    if (choice != null) {
        val message = choice.optJSONObject("message") ?: choice.optJSONObject("delta")
        val text = message?.let { if (it.isNull("content")) "" else it.optString("content") }.orEmpty()
        val candidate = JSONObject()
            .put("content", JSONObject().put("role", "model").put(
                "parts",
                if (text.isEmpty()) JSONArray() else JSONArray().put(JSONObject().put("text", text))
            ))
        if (!choice.isNull("finish_reason")) {
            candidate.put("finishReason", geminiFinishReason(choice.optString("finish_reason")))
        }
        out.put("candidates", JSONArray().put(candidate))
    }
    json.optJSONObject("usage")?.let { out.put("usageMetadata", deepSeekUsageToGemini(it)) }
    return out
}

/// 멈춘 이유를 Gemini 이름으로 바꿉니다. 호출하는 쪽이 `STOP`·`MAX_TOKENS`로 가르기 때문입니다.
///
/// 나머지는 안전 필터와 섞이지 않게 `DEEPSEEK_` 접두사를 붙여 그대로 남깁니다.
internal fun geminiFinishReason(reason: String): String = when (reason) {
    "stop" -> "STOP"
    "length" -> "MAX_TOKENS"
    else -> "DEEPSEEK_${reason.uppercase()}"
}

/// DeepSeek 사용량을 Gemini `usageMetadata` 모양으로 바꿉니다.
///
/// - 입력: `prompt_tokens` = 적중 + 미적중(문서). Gemini `promptTokenCount`처럼 캐시분을 포함합니다.
/// - 캐시: `prompt_cache_hit_tokens`.
/// - 출력: `completion_tokens`를 요금 대상 출력 전체로 봅니다. 여기에 사고 토큰
///   (`completion_tokens_details.reasoning_tokens`)이 포함되는지는 **문서에 없습니다(미확인).**
///   포함된다고 보고 본문 몫을 뺀 값으로 나눕니다. 그래야 받는 쪽이 본문 + 사고로 다시
///   더했을 때 `completion_tokens`와 같아집니다.
/// - 사고 토큰은 **값이 왔을 때만** 적습니다. 없는 것을 0으로 적으면 "사고를 껐다"로 읽힙니다.
internal fun deepSeekUsageToGemini(usage: JSONObject): JSONObject {
    val prompt = usage.optInt("prompt_tokens")
    val cached = if (usage.has("prompt_cache_hit_tokens")) usage.optInt("prompt_cache_hit_tokens")
        else usage.optJSONObject("prompt_tokens_details")?.optInt("cached_tokens") ?: 0
    val completion = usage.optInt("completion_tokens")
    val details = usage.optJSONObject("completion_tokens_details")
    val reasoning = details?.takeIf { it.has("reasoning_tokens") }?.optInt("reasoning_tokens")
    val out = JSONObject()
        .put("promptTokenCount", prompt)
        .put("cachedContentTokenCount", cached)
        .put("candidatesTokenCount", (completion - (reasoning ?: 0)).coerceAtLeast(0))
    reasoning?.let { out.put("thoughtsTokenCount", it.coerceAtMost(completion)) }
    return out
}

// MARK: - 캐시 접두사를 바이트 그대로 되살리기
//
// DeepSeek 캐시는 요청마다 "입력 끝"과 "출력 끝"에서 캐시 단위를 만들고, 다음 요청의
// 앞부분이 그 단위와 **완전히 같아야** 적중합니다(kv_cache 문서). 그런데 저장된 대화에는
// 실제로 보낸 글 두 가지가 빠져 있습니다.
//
// 1. 마지막 사용자 턴에 붙였던 변주 지침(`withRepetitionGuidance`). 다음 요청에서는 빠지므로
//    직전 요청의 "입력 끝" 단위가 통째로 어긋납니다. **3만 토큰 전체가 걸린 쪽이 이것입니다.**
// 2. 답의 호감도 표식. 저장본(`canonicalText`)은 표식을 뺀 글이라 "출력 끝" 단위가
//    어긋납니다. 걸린 것은 마지막 답 몇백 토큰입니다.
//
// 저장된 대화를 고치면 동기화·내보내기·화면에 지침과 표식이 샙니다. 그래서 **DeepSeek에
// 실제로 보낸 추가분만** 방마다 따로 적어 두고, 요청을 만들 때만 되살립니다.
// Gemini 길은 이 기록을 읽지도 쓰지도 않습니다.

/// 한 방에서 DeepSeek에 실제로 보냈지만 저장된 대화에는 없는 글입니다.
@Serializable
internal data class DeepSeekSentExtras(
    /// 사용자 턴 id → 그 턴에 붙여 보낸 변주 지침.
    val guidanceByUserTurn: Map<String, String> = emptyMap(),
    /// 사용자 턴 id → 그 턴에 받은 답의 원문. **저장본과 다를 때만** 적습니다
    /// (대개 호감도 표식이 있을 때). 표식이 없는 답은 저장본이 곧 원문입니다.
    val rawReplyByUserTurn: Map<String, String> = emptyMap()
)

/// 이번 요청에 실을 대화입니다. 지난 요청에 보낸 모양을 그대로 되살립니다.
///
/// - 사용자 턴: 적어 둔 지침이 있으면 `withRepetitionGuidance`와 같은 모양으로 다시 붙입니다.
///   마지막 사용자 턴에는 이번 지침([currentGuidance])을 붙입니다.
/// - 답 턴: 바로 앞 사용자 턴에 적어 둔 원문이 있고, 그 원문에서 표식을 뺀 글이 저장본과
///   **똑같을 때만** 원문으로 바꿉니다. 사용자가 답을 고쳤거나 다시 받았으면 저장본을 그대로 씁니다.
internal fun deepSeekReplayTurns(
    turns: List<ConversationTurn>,
    extras: DeepSeekSentExtras,
    currentGuidance: String?
): List<ConversationTurn> {
    val lastUser = turns.indexOfLast { it.sender == MessageSender.USER }
    var previousUser: ConversationTurn? = null
    return turns.mapIndexed { index, turn ->
        if (turn.sender == MessageSender.USER) {
            previousUser = turn
            val guidance = if (index == lastUser) currentGuidance else extras.guidanceByUserTurn[turn.id.toString()]
            if (guidance == null) turn else turn.copy(text = "${turn.text}\n\n$guidance")
        } else {
            val raw = previousUser?.let { extras.rawReplyByUserTurn[it.id.toString()] }
            if (raw != null && PersonalAffectionProtocol.visibleText(raw) == turn.text) turn.copy(text = raw) else turn
        }
    }
}

/// [DeepSeekSentExtras]를 방마다 파일 하나에 둡니다(`deepseek_sent_extras.json`).
///
/// 앱을 껐다 켜도 이어져야 합니다. 비어 있으면 다음 요청의 접두사가 어긋나 한 번 전액을 냅니다.
/// 대화 내용이 담기므로 앱 전용 폴더에만 두고, 동기화·내보내기에는 쓰지 않습니다.
internal class DeepSeekSentExtrasStore(private val file: File) {
    private val rooms: MutableMap<String, DeepSeekSentExtras> = runCatching {
        Codec.json.decodeFromString<Map<String, DeepSeekSentExtras>>(file.readText()).toMutableMap()
    }.getOrElse { mutableMapOf() }

    @Synchronized
    fun load(roomId: UUID): DeepSeekSentExtras = rooms[roomId.toString()] ?: DeepSeekSentExtras()

    /// 이번 요청을 보내기 직전에 부릅니다. 지침을 적고, 이번 요청에 실리지 않는 턴의 기록은 버립니다
    /// (압축된 턴은 다시 보낼 일이 없습니다). 지침이 없으면 그 턴의 옛 지침을 지웁니다(재요청).
    @Synchronized
    fun recordRequest(roomId: UUID, turns: List<ConversationTurn>, lastUserTurn: UUID?, guidance: String?, liveRoomIds: Set<UUID>) {
        val kept = turns.map { it.id.toString() }.toSet()
        val old = load(roomId)
        var guidances = old.guidanceByUserTurn.filterKeys { it in kept }
        if (lastUserTurn != null) {
            val key = lastUserTurn.toString()
            guidances = if (guidance == null) guidances - key else guidances + (key to guidance)
        }
        rooms[roomId.toString()] = DeepSeekSentExtras(
            guidanceByUserTurn = guidances,
            rawReplyByUserTurn = old.rawReplyByUserTurn.filterKeys { it in kept }
        )
        // 지운 방의 기록이 남지 않게 합니다.
        val live = liveRoomIds.map(UUID::toString).toSet()
        rooms.keys.retainAll { it in live || it == roomId.toString() }
        save()
    }

    /// 답을 끝까지 받은 뒤에 부릅니다. 원문이 저장본과 같으면 적지 않고, 옛 기록은 지웁니다.
    @Synchronized
    fun recordReply(roomId: UUID, lastUserTurn: UUID?, raw: String) {
        val key = lastUserTurn?.toString() ?: return
        val old = load(roomId)
        val replies = if (PersonalAffectionProtocol.visibleText(raw) == raw) old.rawReplyByUserTurn - key
            else old.rawReplyByUserTurn + (key to raw)
        rooms[roomId.toString()] = old.copy(rawReplyByUserTurn = replies)
        save()
    }

    private fun save() {
        runCatching {
            file.parentFile?.mkdirs()
            file.writeText(Codec.json.encodeToString(rooms.toMap()))
        }
    }
}
