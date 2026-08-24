package com.sapiens.gagaodok.service

import android.os.SystemClock
import android.util.Log
import com.sapiens.gagaodok.BuildConfig
import com.sapiens.gagaodok.data.RequestObservation
import com.sapiens.gagaodok.data.PromptTokenBreakdown
import com.sapiens.gagaodok.data.SecureStore
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.AttachmentType
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.model.PersonaStyle
import kotlinx.coroutines.launch
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

// 대화 한 턴을 보내고 받는 길입니다.
// 요청 본문 조립, SSE 스트리밍, 보낼 대화 만들기가 여기 있습니다.
/// 스트림 한 건의 결과입니다. 사용량과 종료 사유는 마지막 청크에 들어옵니다.
internal data class StreamOutcome(
    var text: String = "",
    var finishReason: String? = null,
    var usage: JSONObject? = null
)

internal suspend fun AIService.sendGeminiRequest(
    conversation: List<ConversationTurn>,
    botName: String,
    roomId: UUID,
    persona: PersonaStyle?,
    mode: ChatMode,
    roleplayInProgress: Boolean,
    repetitionAdvice: RepetitionAdvice?,
    systemPromptOverride: String?,
    onRawText: suspend (String) -> Unit,
    onBubble: suspend (GeneratedMessageBubble) -> Unit
): String {
    val model = AIModel.GEMINI_37_FLASH
    val apiKey = SecureStore.apiKey(appContext, SecureStore.Credential.GEMINI)
        ?: throw AIServiceException("설정에서 Gemini API 키를 먼저 등록해주세요.")

    // 대화가 아주 길어진 방에서는 앞부분을 구간 요약으로 갈아끼웁니다.
    // 기준에 못 미치면 plan이 원본을 그대로 돌려주므로 짧은 방은 지금까지와 똑같이 동작합니다.
    val digest = store.loadDigest(roomId)
    val plan = ConversationCompactor.plan(conversation, digest, mode)

    val verbatimContents = buildGeminiContents(plan.verbatimTurns)
    var contents = verbatimContents
    plan.digestText?.let { contents = digestPreamble(it) + contents }
    var requestContents = buildGeminiContents(plan.verbatimTurns.withRepetitionGuidance(repetitionAdvice))
    plan.digestText?.let { requestContents = digestPreamble(it) + requestContents }
    val system = systemPromptOverride ?: systemPrompt(botName, persona, mode)
    val stableSystemTokens = TokenEstimator.textTokens(mode.stableSystemPrompt)
    val systemTokens = TokenEstimator.textTokens(system)
    val digestTokens = plan.digestText?.let(TokenEstimator::textTokens) ?: 0
    val promptBreakdown = PromptTokenBreakdown(
        stableSystemTokens = stableSystemTokens.toLong(),
        personaAndRoomTokens = (systemTokens - stableSystemTokens).coerceAtLeast(0).toLong(),
        digestTokens = digestTokens.toLong(),
        recentConversationTokens = estimateTokens(verbatimContents).toLong(),
        dynamicGuidanceTokens = (estimateTokens(requestContents) - estimateTokens(contents)).coerceAtLeast(0).toLong()
    )

    // 지문에 system이 들어가므로, 모드를 바꾸면 이전 캐시가 저절로 버려지고 새 지침으로 다시 잡힙니다.
    val cache = usablePrefixCache(roomId, contents, system, apiKey)
    // 캐시를 만들지 말지 정할 때 씁니다. **읽기 전에** 꺼내야 직전 값이 나옵니다.
    val previousRequestAt = markRequest(roomId)

    val sink = StreamBubbleSink(
        roleplayEstablished = mode == ChatMode.COMPANION && roleplayInProgress,
        makeBubbles = { paragraph, roleplay ->
            parseResponseIntoBubbles(
                paragraph, botName, roleplay,
                preserveMentorMath = mode == ChatMode.MATH_MENTOR
            )
        },
        onBubble = onBubble
    )

    // 사용량을 **`finally`에서** 적습니다.
    //
    // 예전에는 스트림이 정상적으로 끝난 뒤에만 적었습니다. 그런데 답변을 도중에
    // 멈추면(사용자가 "눌러서 중지") 코루틴이 취소되면서 그 자리를 건너뛰었습니다.
    // 서버는 이미 입력을 다 읽고 답을 만들고 있었으므로 요금은 그대로 나갑니다.
    // 사용량 조각은 매 청크에 실려 오기 때문에, 도중에 멈춰도 그때까지 받은 값은
    // 손에 있습니다. 그걸 버리지 않고 적습니다.
    val outcome = StreamOutcome()
    // 응답이 왜 느린지는 "총 몇 초"로는 안 갈립니다. 첫 글자까지 걸린 시간과 그 뒤
    // 생성에 걸린 시간을 나눠 봐야, 모델이 생각만 하고 있었는지 길게 쓰느라 오래
    // 걸렸는지가 구분됩니다. 실기기에서 첫 말풍선까지 23초가 걸린 적이 있는데,
    // 그중 22초가 첫 글자를 기다린 시간이었습니다.
    val requestStartedAt = SystemClock.elapsedRealtime()
    var firstTokenAt = 0L
    try {
        val consume: suspend (String) -> Unit = {
            if (firstTokenAt == 0L) firstTokenAt = SystemClock.elapsedRealtime()
            onRawText(it)
            sink.consume(it)
        }
        // 첫 글자가 늦으면 끊고 다시 거는 장치를 넣었다가 **뺐습니다.**
        //
        // 전제는 "오래 걸리는 연결을 버리고 새로 걸면 빠른 쪽에 붙는다"였습니다. 실기기에서
        // 세 번 발동했는데 다시 건 요청도 똑같이 느렸습니다. 첫 글자만 늦은 것이 아니라
        // 그 뒤 토큰까지 20 tok/s로 왔습니다(빠른 턴은 200 tok/s). 요금만 두 배 냈습니다.
        //
        // 실험 자체에도 결함이 있었습니다. [AIService.client]는 하나를 공유하고 연결 풀을
        // 쓰므로, 다시 건 요청은 십중팔구 **이미 느려진 그 연결을 그대로 다시 탔습니다.**
        // 그래서 이 결과는 "새 연결이 소용없다"의 증거가 아니라 "새 연결을 아예 못 얻었다"에
        // 가깝습니다. 다시 시도한다면 연결을 먼저 버리게 만들어야 합니다.
        streamGemini(outcome, requestContents, system, cache, apiKey, model, mode, onText = consume)
        sink.finish()
    } finally {
        val finishedAt = SystemClock.elapsedRealtime()
        val ttftMillis = if (firstTokenAt == 0L) 0L else firstTokenAt - requestStartedAt
        val totalMillis = finishedAt - requestStartedAt
        val reported = outcome.usage
        val shouldMeasure = !BuildConfig.TABLET_MENTOR && mode == ChatMode.COMPANION
        if (reported != null) {
            // 사고 토큰은 요금에서는 출력에 합산되지만, 느린 이유를 가릴 때는 따로 봐야 합니다.
            //
            // **"0"과 "안 알려줬다"를 구분합니다.** `optInt`는 키가 없어도 0을 돌려주므로,
            // 사고를 정말 안 한 것인지 서버가 값을 안 준 것인지 구분할 수 없습니다.
            // 그 둘을 섞으면 "사고를 껐다"는 결론이 근거 없이 서 버립니다.
            val reportedThoughts = if (reported.has("thoughtsTokenCount")) reported.optInt("thoughtsTokenCount") else null
            val thoughts = reportedThoughts ?: 0
            val output = reported.optInt("candidatesTokenCount") + thoughts
            val input = reported.optInt("promptTokenCount") + reported.optInt("toolUsePromptTokenCount")
            val cached = reported.optInt("cachedContentTokenCount")
            logRequestTiming(
                mode, ttftMillis, totalMillis, input, cached, reportedThoughts, output - thoughts,
                thinkingLevel = mode.geminiThinkingLevel,
                turns = conversation.size,
                digestTurns = plan.digestText?.let { plan.verbatimTurns.size } ?: -1
            )
            usage.recordUsage(
                roomId, model,
                // 검색 그라운딩을 쓰면 도구가 쓴 입력이 따로 옵니다. 이것도 청구됩니다.
                inputTokens = input,
                outputTokens = output,
                cachedInputTokens = cached
            )
            if (shouldMeasure) measurement.observeRequest(RequestObservation(
                roomId.toString(), input, cached, output,
                estimatedPromptTokens = estimateTokens(requestContents) + TokenEstimator.textTokens(system),
                prompt = promptBreakdown,
                ttftMillis = ttftMillis,
                totalMillis = totalMillis,
                thoughtsTokens = thoughts
            ))
        } else {
            // 한 조각도 못 받고 끊겼습니다. 숫자를 지어내지 않고 건수만 남깁니다.
            logRequestTiming(
                mode, ttftMillis, totalMillis, 0, 0, null, 0,
                thinkingLevel = mode.geminiThinkingLevel,
                turns = conversation.size,
                digestTurns = plan.digestText?.let { plan.verbatimTurns.size } ?: -1
            )
            usage.recordUnreportedRequest(roomId, model)
            if (shouldMeasure) measurement.observeRequest(RequestObservation(
                roomId.toString(), 0, 0, 0,
                estimatedPromptTokens = estimateTokens(requestContents) + TokenEstimator.textTokens(system),
                unreported = true,
                prompt = promptBreakdown,
                ttftMillis = ttftMillis,
                totalMillis = totalMillis
            ))
        }
    }

    if (outcome.text.isEmpty()) {
        // 답변이 비었을 때 "왜" 비었는지가 대부분 finishReason에 담겨 옵니다.
        throw AIServiceException(emptyResponseMessage(outcome.finishReason))
    }

    // 캐시에는 "방금 실제로 보낸 contents"를 그대로 올립니다.
    // 답변까지 덧붙여 캐시하면 적중률이 조금 높지만, 앱이 다음 턴에 재구성하는 문자열과
    // 한 글자라도 어긋나면 지문 검사에서 통째로 탈락합니다.
    // 답변을 이미 확보한 뒤이므로 화면 표시를 막지 않도록 백그라운드에서 진행합니다.
    scope.launch {
        refreshPrefixCache(
            roomId, contents, system, apiKey, previousRequestAt,
            measure = !BuildConfig.TABLET_MENTOR && mode == ChatMode.COMPANION
        )
    }

    // 요약도 답변을 다 받은 뒤에 만듭니다. 보내기 전에 만들면 그 몇 초가 고스란히 응답 지연이 됩니다.
    plan.pending?.let { pending -> scope.launch { appendDigestSegment(roomId, pending, mode, apiKey) } }

    return outcome.text
}

/// 요약을 대화 맨 앞에 놓습니다. Gemini는 첫 턴이 user여야 해서 model 턴으로 한 번 받아 줍니다.
internal fun AIService.digestPreamble(text: String): List<JSONObject> = listOf(
    JSONObject().put("role", "user")
        .put("parts", JSONArray().put(JSONObject().put("text", text))),
    JSONObject().put("role", "model")
        .put("parts", JSONArray().put(JSONObject().put("text", "이전 대화 요약을 확인했습니다. 이어서 진행하겠습니다.")))
)

/// `streamGenerateContent`로 받아 도착하는 대로 흘려보냅니다.
///
/// 완성된 말풍선을 만드는 판단은 `StreamingBubbleBuffer`가 합니다. 여기서는
/// 서버가 준 조각을 그대로 넘길 뿐이라, 청크가 어디서 끊기든 상관하지 않습니다.
internal suspend fun AIService.streamGemini(
    outcome: StreamOutcome,
    contents: List<JSONObject>,
    system: String,
    cache: PrefixCache?,
    apiKey: String,
    model: AIModel,
    mode: ChatMode,
    onText: suspend (String) -> Unit
) {
    val url = "$GEMINI_BASE/models/${model.rawValue}:streamGenerateContent?alt=sse"
    val body = requestBody(contents, system, cache, mode).toString()

    val request = Request.Builder()
        .url(url)
        .addHeader("Content-Type", "application/json")
        // 키를 쿼리 문자열에 붙이면 URL이 남는 곳마다 그대로 노출되므로 헤더로 보냅니다.
        .addHeader("x-goog-api-key", apiKey)
        .post(body.toRequestBody(JSON_MEDIA))
        .build()

    val response = client.newCall(request).execute()
    response.use {
        if (!it.isSuccessful) {
            // 오류 본문도 스트림으로 오므로 모아서 해석합니다.
            val raw = it.body?.string().orEmpty()
            throw AIServiceException(errorMessage(raw, it.code, "Gemini"))
        }

        val source = it.body?.source() ?: return
        while (true) {
            val line = source.readUtf8Line() ?: break
            if (!line.startsWith("data:")) continue
            val payload = line.removePrefix("data:").trim()
            if (payload.isEmpty() || payload == "[DONE]") continue
            val json = runCatching { JSONObject(payload) }.getOrNull() ?: continue

            json.optJSONObject("usageMetadata")?.let { u -> outcome.usage = u }
            val candidate = json.optJSONArray("candidates")?.optJSONObject(0) ?: continue
            candidate.optString("finishReason").takeIf { r -> r.isNotEmpty() }
                ?.let { r -> outcome.finishReason = r }

            val parts = candidate.optJSONObject("content")?.optJSONArray("parts") ?: continue
            val piece = buildString {
                for (i in 0 until parts.length()) {
                    append(parts.optJSONObject(i)?.optString("text").orEmpty())
                }
            }
            if (piece.isEmpty()) continue
            outcome.text += piece
            onText(piece)
        }
    }
}

internal fun AIService.requestBody(
    contents: List<JSONObject>,
    system: String,
    cache: PrefixCache?,
    mode: ChatMode
): JSONObject {
    // Gemini 3.x는 temperature·topP·topK·candidateCount를 받지 않고,
    // 사고량은 thinking_budget 숫자가 아니라 thinkingLevel 문자열로 지정합니다.
    val body = JSONObject().put(
        "generationConfig",
        JSONObject()
            .put("maxOutputTokens", GEMINI_MAX_OUTPUT_TOKENS)
            // 사고량은 모드가 정합니다(`ChatMode.geminiThinkingLevel`).
            // 챗봇 방에서는 끕니다. 안 보이는 사고 토큰이 출력 단가로 붙는 데다,
            // 그 시간이 첫 글자까지의 대기에 그대로 얹힙니다.
            .put("thinkingConfig", JSONObject().put("thinkingLevel", mode.geminiThinkingLevel))
    )

    // 안전 설정은 캐시에 담기지 않으므로 캐시를 쓰든 안 쓰든 매 요청에 함께 보냅니다.
    mode.geminiSafetyCategories?.let { categories ->
        body.put("safetySettings", JSONArray().apply {
            categories.forEach {
                put(JSONObject().put("category", it).put("threshold", "BLOCK_NONE"))
            }
        })
    }

    if (cache != null) {
        // 캐시에 시스템 지침과 앞부분 대화가 들어 있으므로 남은 턴만 보냅니다.
        // 이때 systemInstruction을 함께 보내면 요청이 거부됩니다.
        body.put("cachedContent", cache.name)
        body.put("contents", JSONArray().apply {
            contents.drop(cache.coveredTurns).forEach { put(it) }
        })
    } else {
        body.put("systemInstruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", system))))
        body.put("contents", JSONArray().apply { contents.forEach { put(it) } })
    }
    return body
}

// MARK: - 명시적 캐시

internal fun AIService.buildGeminiContents(conversation: List<ConversationTurn>): List<JSONObject> =
    conversation.mapNotNull { turn ->
        if (turn.text.startsWith(ERROR_PREFIX)) return@mapNotNull null
        val parts = JSONArray()
        if (turn.text.isNotEmpty()) parts.put(JSONObject().put("text", turn.text))

        val attachment = turn.attachment
        if (turn.sender == MessageSender.USER && attachment != null) {
            if (attachment.type == AttachmentType.IMAGE ||
                attachment.mimeType.startsWith("image/") ||
                attachment.mimeType == "application/pdf"
            ) {
                parts.put(
                    JSONObject().put(
                        "inlineData",
                        JSONObject().put("mimeType", attachment.mimeType).put("data", attachment.dataBase64)
                    )
                )
            } else {
                decodeText(attachment)?.let {
                    parts.put(JSONObject().put("text", "첨부파일 ${attachment.fileName}:\n$it"))
                }
            }
        }
        if (parts.length() == 0) return@mapNotNull null

        // Gemini 3.x는 마지막 user 턴에 텍스트 파트가 있어야 합니다.
        // 설명 없이 사진만 올린 경우를 대비해 기본 지시문을 앞에 넣습니다.
        val finalParts = if (turn.sender == MessageSender.USER && turn.text.isEmpty()) {
            JSONArray().put(JSONObject().put("text", "첨부한 내용을 봐주세요.")).also { out ->
                for (i in 0 until parts.length()) out.put(parts.get(i))
            }
        } else parts

        JSONObject()
            .put("role", if (turn.sender == MessageSender.USER) "user" else "model")
            .put("parts", finalParts)
    }

/// 요청 한 건의 시간과 토큰을 한 줄로 남깁니다.
///
/// 기기를 연결해 두고 `adb logcat -s GagaodokTiming`으로 봅니다. 저장하지 않으므로
/// 요금이나 사용량 장부에는 영향이 없고, 기기가 없을 때는 최적화 측정 장부 쪽 숫자를
/// 봅니다(합계와 최댓값).
///
/// 이 네 숫자면 느린 이유가 갈립니다.
/// - ttft가 크고 사고 토큰이 많다 → 모델이 답을 쓰기 전에 오래 생각한 것
/// - ttft가 크고 입력 토큰이 크다 → 프롬프트가 커진 것(대화가 길어질수록 느려짐)
/// - ttft가 큰데 둘 다 보통이다 → 네트워크나 서버 사정
/// - ttft는 작은데 총 시간이 크다 → 답변이 길어서 생성에 걸린 것
private fun logRequestTiming(
    mode: ChatMode,
    ttftMillis: Long,
    totalMillis: Long,
    inputTokens: Int,
    cachedTokens: Int,
    /// 서버가 알려주지 않았으면 `null`입니다. 0과 구분해야 "사고를 껐다"를 말할 수 있습니다.
    thoughtsTokens: Int?,
    answerTokens: Int,
    thinkingLevel: String,
    turns: Int,
    /// 압축이 걸렸으면 원문으로 나간 턴 수, 안 걸렸으면 -1입니다.
    digestTurns: Int
) {
    val thoughts = thoughtsTokens?.toString() ?: "n/a"
    val compaction = if (digestTurns < 0) "none" else "verbatim=$digestTurns"
    Log.i(
        "GagaodokTiming",
        "$mode ttft=${ttftMillis}ms total=${totalMillis}ms " +
            "input=$inputTokens(cached=$cachedTokens) thoughts=$thoughts answer=$answerTokens " +
            "thinking=$thinkingLevel turns=$turns compaction=$compaction"
    )
}
