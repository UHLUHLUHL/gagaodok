package com.sapiens.gagaodok.service

import android.content.Context
import android.graphics.Bitmap
import android.util.Base64
import com.sapiens.gagaodok.data.ChatStore
import com.sapiens.gagaodok.data.SecureStore
import com.sapiens.gagaodok.data.TokenUsageStore
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.AttachmentType
import com.sapiens.gagaodok.model.ChatAttachment
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.Codec
import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageKind
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.model.PersonaStyle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.TimeUnit

/// @param retryable 같은 요청을 그대로 다시 보내면 될 만한 실패인지.
///
/// **거짓이면 다시 보내지 않습니다.** 예전에는 어떤 실패든 조용히 두 번 더 보냈는데,
/// 키가 틀렸거나 안전 필터에 걸린 요청은 몇 번을 보내도 똑같이 실패합니다.
/// 그 재시도는 화면에 아무것도 남기지 않으면서 요금만 세 배로 냈습니다.
class AIServiceException(
    message: String,
    val retryable: Boolean = false
) : Exception(message)

data class GeneratedMessageBubble(
    val text: String,
    val attachment: ChatAttachment? = null,
    val kind: MessageKind = MessageKind.SPEECH
)

/// 스트림 조각을 받아 완성된 말풍선만 밖으로 내보냅니다.
///
/// 문단이 완성되면 기존 말풍선 분리기에 그대로 넘기므로, 그래프 태그 처리나
/// 이름 접두사 제거 같은 규칙이 스트리밍에서도 똑같이 적용됩니다.
class StreamBubbleSink(
    /// 이 턴이 상황극이라고 이미 아는지.
    ///
    /// 문단은 완성되는 대로 화면에 붙기 때문에, 첫 문단을 붙일 때는 뒤에 따옴표 대사가
    /// 나올지 알 수 없습니다. 그래서 지난 턴에서 얻은 값으로 시작합니다.
    /// 상황극을 처음 시작하는 턴에서만, 첫 대사가 나오기 전의 묘사가 대사 말풍선으로
    /// 나옵니다. 그 다음 턴부터는 앞 턴이 근거가 되어 첫 문단부터 제대로 갈립니다.
    private var roleplayEstablished: Boolean,
    private val makeBubbles: (String, Boolean) -> List<GeneratedMessageBubble>,
    private val onBubble: suspend (GeneratedMessageBubble) -> Unit
) {
    private val buffer = StreamingBubbleBuffer()
    private val lock = Mutex()

    suspend fun consume(piece: String) = lock.withLock {
        buffer.append(piece).forEach { handle(it) }
    }

    suspend fun finish() = lock.withLock {
        val rest = buffer.flush()
        if (rest.isNotEmpty()) handle(rest)
    }

    private suspend fun handle(paragraph: String) {
        if (RoleplayParser.establishesRoleplay(paragraph)) roleplayEstablished = true
        makeBubbles(paragraph, roleplayEstablished).forEach { onBubble(it) }
    }
}

/// Gemini의 implicit 캐시는 "완전히 똑같은 요청"이 짧은 간격으로 반복될 때만 걸립니다.
/// 채팅처럼 턴이 계속 붙는 패턴에서는 접두사가 같아도 적중하지 않아 실측 적중률이 0%였습니다.
/// 그래서 대화 접두사를 명시적 캐시(cachedContents)로 올려두고 새 턴만 보냅니다.
@Serializable
private data class PrefixCache(
    val name: String,          // cachedContents/xxxx
    val coveredTurns: Int,     // 이 캐시가 덮는 contents 앞부분의 개수
    val fingerprint: String,   // 덮은 구간이 편집되지 않았는지 확인하는 지문
    val expiresAtMillis: Long,
    /// 이 캐시에 올라가 있는 토큰 수입니다. 다시 만들 값어치가 있는지 따질 때 씁니다.
    /// 예전 파일에는 없던 값이라 기본값을 둡니다.
    val tokenCount: Int = 0
)

class AIService private constructor(private val appContext: Context) {

    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(180, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val store get() = ChatStore.get(appContext)
    private val usage get() = TokenUsageStore.get(appContext)

    // MARK: - 시스템 지침

    private fun systemPrompt(botName: String, persona: PersonaStyle?, mode: ChatMode): String {
        // 이 고정 접두사는 두 공급자에서 동일하게 재사용됩니다.
        // 방 이름 같은 동적 값은 끝에 둬 캐시 적중률을 높입니다.
        var prompt = mode.stableSystemPrompt
        // 말투는 방마다 고정이라 캐시 접두사 안쪽에 두어도 적중률이 떨어지지 않습니다.
        persona?.promptSection(botName, mode)?.let { prompt += "\n\n$it" }
        prompt += "\n\n# 현재 대화 설정\n이 대화에서 당신의 이름은 '$botName'이다. 자신을 지칭해야 할 때 이 이름을 사용한다."
        return prompt
    }

    // MARK: - 답변 생성

    /// 답변을 말풍선이 완성되는 대로 흘려보냅니다.
    ///
    /// 글자 단위로 올리지 않는 이유는 청크가 수식 한가운데서 끊기기 때문입니다.
    /// `StreamingBubbleBuffer`가 구분자가 모두 닫힌 문단만 통과시키므로
    /// 깨진 수식이 화면에 뜨는 일이 없습니다.
    suspend fun streamResponse(
        conversation: List<ConversationTurn>,
        botName: String,
        roomId: UUID,
        model: AIModel,
        persona: PersonaStyle?,
        mode: ChatMode,
        roleplayInProgress: Boolean,
        onBubble: suspend (GeneratedMessageBubble) -> Unit
    ): String = withContext(Dispatchers.IO) {
        when (model) {
            AIModel.GEMINI_37_FLASH -> sendGeminiRequest(
                conversation, botName, roomId, persona, mode, roleplayInProgress, onBubble
            )
            AIModel.GPT_56_LUNA -> {
                // Luna는 스트리밍하지 않습니다. 한 번에 받아 말풍선으로 갈라 내보냅니다.
                val raw = sendOpenAIRequest(conversation, botName, roomId, persona, mode)
                parseResponseIntoBubbles(raw, botName, mode == ChatMode.COMPANION && roleplayInProgress)
                    .forEach { onBubble(it) }
                raw
            }
        }
    }

    private suspend fun sendGeminiRequest(
        conversation: List<ConversationTurn>,
        botName: String,
        roomId: UUID,
        persona: PersonaStyle?,
        mode: ChatMode,
        roleplayInProgress: Boolean,
        onBubble: suspend (GeneratedMessageBubble) -> Unit
    ): String {
        val model = AIModel.GEMINI_37_FLASH
        val apiKey = SecureStore.apiKey(appContext, SecureStore.Credential.GEMINI)
            ?: throw AIServiceException("설정에서 Gemini API 키를 먼저 등록해주세요.")

        // 대화가 아주 길어진 방에서는 앞부분을 구간 요약으로 갈아끼웁니다.
        // 기준에 못 미치면 plan이 원본을 그대로 돌려주므로 짧은 방은 지금까지와 똑같이 동작합니다.
        val digest = store.loadDigest(roomId)
        val plan = ConversationCompactor.plan(conversation, digest, mode)

        var contents = buildGeminiContents(plan.verbatimTurns)
        plan.digestText?.let { contents = digestPreamble(it) + contents }
        val system = systemPrompt(botName, persona, mode)

        // 지문에 system이 들어가므로, 모드를 바꾸면 이전 캐시가 저절로 버려지고 새 지침으로 다시 잡힙니다.
        val cache = usablePrefixCache(roomId, contents, system, apiKey)
        // 캐시를 만들지 말지 정할 때 씁니다. **읽기 전에** 꺼내야 직전 값이 나옵니다.
        val previousRequestAt = markRequest(roomId)

        val sink = StreamBubbleSink(
            roleplayEstablished = mode == ChatMode.COMPANION && roleplayInProgress,
            makeBubbles = { paragraph, roleplay -> parseResponseIntoBubbles(paragraph, botName, roleplay) },
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
        try {
            streamGemini(outcome, contents, system, cache, apiKey, model, mode) { sink.consume(it) }
            sink.finish()
        } finally {
            val reported = outcome.usage
            if (reported != null) {
                val output = reported.optInt("candidatesTokenCount") + reported.optInt("thoughtsTokenCount")
                usage.recordUsage(
                    roomId, model,
                    // 검색 그라운딩을 쓰면 도구가 쓴 입력이 따로 옵니다. 이것도 청구됩니다.
                    inputTokens = reported.optInt("promptTokenCount") +
                        reported.optInt("toolUsePromptTokenCount"),
                    outputTokens = output,
                    cachedInputTokens = reported.optInt("cachedContentTokenCount")
                )
            } else {
                // 한 조각도 못 받고 끊겼습니다. 숫자를 지어내지 않고 건수만 남깁니다.
                usage.recordUnreportedRequest(roomId, model)
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
        scope.launch { refreshPrefixCache(roomId, contents, system, apiKey, previousRequestAt) }

        // 요약도 답변을 다 받은 뒤에 만듭니다. 보내기 전에 만들면 그 몇 초가 고스란히 응답 지연이 됩니다.
        plan.pending?.let { pending -> scope.launch { appendDigestSegment(roomId, pending, mode, apiKey) } }

        return outcome.text
    }

    /// 요약을 대화 맨 앞에 놓습니다. Gemini는 첫 턴이 user여야 해서 model 턴으로 한 번 받아 줍니다.
    private fun digestPreamble(text: String): List<JSONObject> = listOf(
        JSONObject().put("role", "user")
            .put("parts", JSONArray().put(JSONObject().put("text", text))),
        JSONObject().put("role", "model")
            .put("parts", JSONArray().put(JSONObject().put("text", "이전 대화 요약을 확인했습니다. 이어서 진행하겠습니다.")))
    )

    /// 스트림 한 건의 결과입니다. 사용량과 종료 사유는 마지막 청크에 들어옵니다.
    private data class StreamOutcome(
        var text: String = "",
        var finishReason: String? = null,
        var usage: JSONObject? = null
    )

    /// `streamGenerateContent`로 받아 도착하는 대로 흘려보냅니다.
    ///
    /// 완성된 말풍선을 만드는 판단은 `StreamingBubbleBuffer`가 합니다. 여기서는
    /// 서버가 준 조각을 그대로 넘길 뿐이라, 청크가 어디서 끊기든 상관하지 않습니다.
    private suspend fun streamGemini(
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

    private fun requestBody(
        contents: List<JSONObject>,
        system: String,
        cache: PrefixCache?,
        mode: ChatMode
    ): JSONObject {
        // Gemini 3.x는 temperature·topP·topK·candidateCount를 받지 않고,
        // 사고량은 thinking_budget 숫자가 아니라 thinkingLevel 문자열(low/medium/high)로 지정합니다.
        val body = JSONObject().put(
            "generationConfig",
            JSONObject()
                .put("maxOutputTokens", GEMINI_MAX_OUTPUT_TOKENS)
                // 사고량은 모드가 정합니다(`ChatMode.geminiThinkingLevel`).
                // 챗봇 방에서는 낮음입니다. 안 보이는 사고 토큰이 출력 단가로
                // 붙는데, 잡담의 말씨는 오래 생각한다고 좋아지지 않습니다.
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

    private val cacheFile: File by lazy {
        File(File(appContext.filesDir, "KakaoSapiens").apply { mkdirs() }, "prefix_caches.json")
    }

    // 캐시 이름을 메모리에만 두면 앱을 껐다 켤 때마다 서버에 살아 있는 캐시를 버리고
    // 첫 요청을 전액으로 냅니다. TTL이 남아 있으면 이어서 쓰도록 디스크에 적어 둡니다.
    private val prefixCaches: MutableMap<String, PrefixCache> by lazy {
        runCatching {
            Codec.json.decodeFromString<Map<String, PrefixCache>>(cacheFile.readText())
                // 이미 만료된 것은 되살리지 않습니다. 서버에도 없습니다.
                .filterValues { it.expiresAtMillis > System.currentTimeMillis() }
                .toMutableMap()
        }.getOrElse { mutableMapOf() }
    }

    private fun persistCaches() {
        val snapshot = synchronized(prefixCaches) { prefixCaches.toMap() }
        scope.launch { runCatching { cacheFile.writeText(Codec.json.encodeToString(snapshot)) } }
    }

    private fun usablePrefixCache(
        roomId: UUID,
        contents: List<JSONObject>,
        system: String,
        apiKey: String
    ): PrefixCache? {
        val key = roomId.toString()
        val cache = synchronized(prefixCaches) { prefixCaches[key] } ?: return null

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
    private fun dropCache(key: String, deleteRemote: Boolean, apiKey: String) {
        val removed = synchronized(prefixCaches) { prefixCaches.remove(key) }
        persistCaches()
        if (deleteRemote && removed != null) {
            scope.launch { deleteCache(removed.name, apiKey) }
        }
    }

    private val refreshingRooms = mutableSetOf<String>()

    /// 방마다 **직전** 요청 시각입니다. 대화가 이어지는 중인지 보는 데 씁니다.
    ///
    /// 메모리에만 둡니다. 앱을 껐다 켜면 비어 있어서 그 방의 캐시가 한 메시지 늦게
    /// 만들어집니다. 파일로 남길 값어치는 없다고 봤습니다.
    private val lastRequestAt = mutableMapOf<String, Long>()

    /// 직전 요청 시각을 꺼내면서 지금 시각으로 갱신합니다.
    private fun markRequest(roomId: UUID): Long? = synchronized(lastRequestAt) {
        val previous = lastRequestAt[roomId.toString()]
        lastRequestAt[roomId.toString()] = System.currentTimeMillis()
        previous
    }

    private suspend fun refreshPrefixCache(
        roomId: UUID,
        contents: List<JSONObject>,
        system: String,
        apiKey: String,
        previousRequestAt: Long?
    ) {
        val key = roomId.toString()
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
            if (estimated < MINIMUM_CACHE_TOKENS) return

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
                if (!ongoing) return
            }

            if (previous != null) {
                // 이미 같은 구간을 덮고 있으면 다시 만들 것이 없습니다.
                if (previous.coveredTurns >= contents.size &&
                    previous.expiresAtMillis > now + 60_000
                ) return

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
                if (!worthIt && !expiringSoon) return
            }
            val payload = JSONObject()
                .put("model", "models/${AIModel.GEMINI_37_FLASH.rawValue}")
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
            val json = runCatching {
                client.newCall(request).execute().use {
                    if (!it.isSuccessful) return
                    JSONObject(it.body?.string().orEmpty())
                }
            }.getOrNull() ?: return
            val name = json.optString("name").takeIf { it.isNotEmpty() } ?: return

            val cachedTokens = json.optJSONObject("usageMetadata")?.optInt("totalTokenCount") ?: 0
            synchronized(prefixCaches) {
                prefixCaches[key] = PrefixCache(
                    name = name,
                    coveredTurns = contents.size,
                    fingerprint = fingerprint(contents, system),
                    expiresAtMillis = System.currentTimeMillis() + CACHE_TTL_SECONDS * 1000L,
                    tokenCount = if (cachedTokens > 0) cachedTokens else estimated
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
                    roomId, AIModel.GEMINI_37_FLASH,
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

    private fun deleteCache(name: String, apiKey: String) {
        runCatching {
            client.newCall(
                Request.Builder().url("$GEMINI_BASE/$name")
                    .addHeader("x-goog-api-key", apiKey)
                    .delete().build()
            ).execute().close()
        }
    }

    private fun fingerprint(contents: List<JSONObject>, system: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(system.toByteArray())
        // JSONObject.toString()은 키 순서를 넣은 순서대로 유지합니다.
        // contents를 만드는 코드가 한 곳뿐이라 같은 대화면 같은 문자열이 나옵니다.
        contents.forEach { digest.update(it.toString().toByteArray()) }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /// Gemini `contents` 배열 하나가 몇 토큰쯤 되는지 어림합니다.
    private fun estimateTokens(contents: List<JSONObject>): Int {
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

    private val summarizingRooms = mutableSetOf<String>()

    /// 한 구간을 요약해 방의 요약 목록 뒤에 붙입니다.
    ///
    /// 실패하면 아무것도 바꾸지 않습니다. 그러면 다음 요청에서 같은 구간을 다시 시도하고,
    /// 그때까지는 그 구간이 원문으로 나가므로 대화에는 영향이 없습니다.
    private fun appendDigestSegment(
        roomId: UUID,
        pending: ConversationCompactor.PendingSegment,
        mode: ChatMode,
        apiKey: String
    ) {
        val key = roomId.toString()
        synchronized(summarizingRooms) {
            if (key in summarizingRooms) return
            summarizingRooms += key
        }
        try {
            // 그 사이 다른 요청이 같은 구간을 이미 채웠을 수 있습니다.
            val current = store.loadDigest(roomId)
            if (current.coveredTurns >= pending.lastTurn) return

            val text = requestSegmentSummary(roomId, pending.turns, pending.firstTurn, mode, apiKey)
            if (text.isEmpty()) return

            store.saveDigest(
                roomId,
                current.copy(
                    segments = current.segments + ConversationSegment(
                        firstTurn = pending.firstTurn,
                        lastTurn = pending.lastTurn,
                        text = text
                    )
                )
            )
        } finally {
            synchronized(summarizingRooms) { summarizingRooms -= key }
        }
    }

    private fun requestSegmentSummary(
        roomId: UUID,
        turns: List<ConversationTurn>,
        startingTurn: Int,
        mode: ChatMode,
        apiKey: String
    ): String {
        val transcript = ConversationCompactor.transcript(turns, startingTurn, mode)
        if (transcript.isEmpty()) return ""

        val body = JSONObject()
            .put(
                "systemInstruction",
                JSONObject().put(
                    "parts",
                    JSONArray().put(
                        JSONObject().put("text", ConversationCompactor.summaryInstruction(mode))
                    )
                )
            )
            .put(
                "contents",
                JSONArray().put(
                    JSONObject().put("role", "user").put(
                        "parts",
                        JSONArray().put(JSONObject().put("text", "다음은 정리할 대화 구간이다.\n\n$transcript"))
                    )
                )
            )
            .put(
                "generationConfig",
                JSONObject()
                    // 지시한 분량보다 넉넉히 잡습니다. 사고 토큰도 이 예산에서 함께 쓰고,
                    // 모자라면 문장 한가운데서 잘린 글이 나옵니다.
                    .put("maxOutputTokens", ConversationCompactor.SEGMENT_TOKEN_BUDGET + 1200)
                    .put("thinkingConfig", JSONObject().put("thinkingLevel", "low"))
            )

        val json = runCatching { postGemini(body, apiKey, roomId) }.getOrNull() ?: return ""
        val candidate = json.optJSONArray("candidates")?.optJSONObject(0) ?: return ""

        // 잘린 요약은 저장하지 않습니다. 한 번 넣으면 고치지 않는 기록이라
        // 중간에서 끊긴 글이 그 구간의 기억으로 영영 남습니다.
        // 빈 값을 돌려주면 다음 요청에서 같은 구간을 다시 시도합니다.
        val reason = candidate.optString("finishReason")
        if (reason.isNotEmpty() && reason != "STOP") return ""

        return joinParts(candidate).trim()
    }

    // MARK: - 말투 조사 / 미리보기

    data class PersonaLookup(
        val confidence: String,   // 높음 / 보통 / 낮음
        val note: String,
        val samples: List<String>,
        val styleGuide: String,
        val sources: List<String>
    ) {
        val isUsable: Boolean get() = samples.isNotEmpty() || styleGuide.isNotEmpty()
    }

    /// 대사를 외우고 있지 않아도 되도록, 이름이나 링크만으로 말투를 조사합니다.
    ///
    /// 검색 그라운딩과 URL 읽기를 함께 켜므로 이름이든 링크든 같은 입구로 처리됩니다.
    /// 모르는 인물이면 지어내지 않고 확신도를 '낮음'으로 돌려줍니다.
    /// @param onProgress 지금 무엇이 도착했는지를 알려 줍니다.
    ///
    /// **진행률을 흉내 내지 않습니다.** 이 요청은 오래 걸리는데(검색 → 읽기 → 정리)
    /// 예전에는 화면에 "처리 중입니다…" 한 줄만 떠서, 멈춘 것인지 되고 있는 것인지
    /// 알 수 없었습니다. 그래서 한 번에 받지 않고 흘려 받으면서, 답변에 실제로
    /// 도착한 절([확신도] → [대사] → [말투])을 그대로 알려 줍니다. 시간을 재서
    /// 지어낸 단계가 아니라 방금 받은 글자가 근거입니다.
    suspend fun lookupPersona(
        query: String,
        roomId: UUID,
        imageBase64: String? = null,
        imageMimeType: String? = null,
        onProgress: (String) -> Unit = {}
    ): PersonaLookup = withContext(Dispatchers.IO) {
        val apiKey = SecureStore.apiKey(appContext, SecureStore.Credential.GEMINI)
            ?: throw AIServiceException("설정에서 Gemini API 키를 먼저 등록해주세요.")
        val trimmed = query.trim()
        if (trimmed.isEmpty() && imageBase64 == null) {
            throw AIServiceException("캐릭터 이름이나 참고 링크를 입력해주세요.")
        }

        val parts = JSONArray()
        if (trimmed.isNotEmpty()) parts.put(JSONObject().put("text", "인물 또는 참고 자료: $trimmed"))
        if (imageBase64 != null && imageMimeType != null) {
            parts.put(JSONObject().put("text", "아래 이미지에 이 인물의 대사가 있다. 읽어서 활용한다."))
            parts.put(
                JSONObject().put(
                    "inlineData",
                    JSONObject().put("mimeType", imageMimeType).put("data", imageBase64)
                )
            )
        }

        val body = JSONObject()
            .put("systemInstruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", LOOKUP_INSTRUCTION))))
            .put("contents", JSONArray().put(JSONObject().put("role", "user").put("parts", parts)))
            // 이름이면 검색이, 링크가 섞여 있으면 URL 읽기가 각각 동작합니다.
            .put("tools", JSONArray().put(JSONObject().put("google_search", JSONObject()))
                .put(JSONObject().put("url_context", JSONObject())))
            .put(
                "generationConfig",
                JSONObject().put("maxOutputTokens", 4096)
                    .put("thinkingConfig", JSONObject().put("thinkingLevel", "medium"))
            )

        onProgress("자료를 찾고 있습니다…")
        val result = streamGeminiText(body, apiKey, roomId) { soFar ->
            onProgress(lookupProgressLabel(soFar))
        }
        if (result.text.isEmpty()) {
            throw AIServiceException(emptyResponseMessage(result.finishReason))
        }
        parsePersonaLookup(result.text, result.sources)
    }

    /// 저장하기 전에 이 말투가 실제 그 캐릭터 같은지 확인할 수 있도록 짧은 답변을 만듭니다.
    /// 실제 대화와 똑같은 시스템 지침을 쓰므로, 여기서 보이는 결이 채팅방에서도 그대로 나옵니다.
    suspend fun previewPersona(
        roomId: UUID,
        persona: PersonaStyle,
        botName: String,
        message: String,
        mode: ChatMode
    ): String = withContext(Dispatchers.IO) {
        val apiKey = SecureStore.apiKey(appContext, SecureStore.Credential.GEMINI)
            ?: throw AIServiceException("설정에서 Gemini API 키를 먼저 등록해주세요.")
        val system = systemPrompt(botName, persona.copy(isEnabled = true), mode)

        val body = JSONObject()
            .put("systemInstruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", system))))
            .put(
                "contents",
                JSONArray().put(
                    JSONObject().put("role", "user")
                        .put("parts", JSONArray().put(JSONObject().put("text", message)))
                )
            )
            .put(
                "generationConfig",
                JSONObject().put("maxOutputTokens", 2048)
                    .put("thinkingConfig", JSONObject().put("thinkingLevel", "low"))
            )
            .apply {
                // 미리보기도 실제 대화와 같은 조건이어야 결을 판단할 수 있습니다.
                mode.geminiSafetyCategories?.let { categories ->
                    put("safetySettings", JSONArray().apply {
                        categories.forEach {
                            put(JSONObject().put("category", it).put("threshold", "BLOCK_NONE"))
                        }
                    })
                }
            }

        val json = postGemini(body, apiKey, roomId)
        val candidate = json.optJSONArray("candidates")?.optJSONObject(0)
            ?: throw AIServiceException("미리보기를 읽을 수 없습니다.")
        val text = joinParts(candidate).trim()
        if (text.isEmpty()) {
            throw AIServiceException(emptyResponseMessage(candidate.optString("finishReason")))
        }
        text
    }

    /// 붙여넣은 대사에서 말투 규칙을 뽑아냅니다.
    ///
    /// 모델에게 "이 캐릭터처럼 말해"라고만 하면 흉내가 흐려집니다.
    /// 관찰 가능한 항목(문장 끝맺음, 호칭, 자주 쓰는 어휘, 문장 길이 등)을 짚어서 적게 하면
    /// 이후 대화에서 재현이 훨씬 안정적입니다.
    suspend fun analyzePersonaStyle(roomId: UUID, description: String, samples: List<String>): String =
        withContext(Dispatchers.IO) {
            val apiKey = SecureStore.apiKey(appContext, SecureStore.Credential.GEMINI)
                ?: throw AIServiceException("설정에서 Gemini API 키를 먼저 등록해주세요.")
            val joined = samples.map { it.trim() }.filter { it.isNotEmpty() }.joinToString("\n")
            if (joined.isEmpty()) throw AIServiceException("말투를 분석할 대사를 먼저 입력해주세요.")

            var userText = ""
            if (description.isNotBlank()) userText += "인물 설명: ${description.trim()}\n\n"
            userText += "대사:\n$joined"

            val body = JSONObject()
                .put("systemInstruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", ANALYZE_INSTRUCTION))))
                .put(
                    "contents",
                    JSONArray().put(
                        JSONObject().put("role", "user")
                            .put("parts", JSONArray().put(JSONObject().put("text", userText)))
                    )
                )
                .put(
                    "generationConfig",
                    JSONObject().put("maxOutputTokens", 2048)
                        .put("thinkingConfig", JSONObject().put("thinkingLevel", "low"))
                )

            val candidate = postGemini(body, apiKey, roomId).optJSONArray("candidates")?.optJSONObject(0)
                ?: throw AIServiceException("말투 분석 결과를 읽을 수 없습니다.")
            joinParts(candidate).trim().ifEmpty {
                throw AIServiceException(emptyResponseMessage(candidate.optString("finishReason")))
            }
        }

    /// 뽑아낸 말투 규칙을 사용자의 요청대로 손봅니다.
    ///
    /// 자동 추출은 관찰된 사실만 담기 때문에, 실제로 쓰다 보면
    /// "좀 더 딱딱하게", "이모지 빼줘" 같은 조정이 필요합니다.
    /// 원래 규칙을 통째로 다시 쓰지 않고 요청한 부분만 반영합니다.
    suspend fun refinePersonaStyle(
        roomId: UUID,
        currentGuide: String,
        instruction: String,
        description: String,
        samples: List<String>
    ): String = withContext(Dispatchers.IO) {
        val apiKey = SecureStore.apiKey(appContext, SecureStore.Credential.GEMINI)
            ?: throw AIServiceException("설정에서 Gemini API 키를 먼저 등록해주세요.")
        if (instruction.isBlank()) throw AIServiceException("어떻게 고칠지 입력해주세요.")
        if (currentGuide.isBlank()) throw AIServiceException("먼저 말투 규칙을 만들어주세요.")

        var userText = "현재 말투 규칙:\n${currentGuide.trim()}\n\n"
        if (description.isNotBlank()) userText += "인물: ${description.trim()}\n\n"
        if (samples.isNotEmpty()) {
            userText += "참고용 실제 대사:\n" + samples.take(20).joinToString("\n") + "\n\n"
        }
        userText += "고쳐줬으면 하는 방향:\n${instruction.trim()}"

        val body = JSONObject()
            .put("systemInstruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", REFINE_INSTRUCTION))))
            .put(
                "contents",
                JSONArray().put(
                    JSONObject().put("role", "user")
                        .put("parts", JSONArray().put(JSONObject().put("text", userText)))
                )
            )
            .put(
                "generationConfig",
                JSONObject().put("maxOutputTokens", 2560)
                    .put("thinkingConfig", JSONObject().put("thinkingLevel", "low"))
            )

        val candidate = postGemini(body, apiKey, roomId).optJSONArray("candidates")?.optJSONObject(0)
            ?: throw AIServiceException("교정 결과를 읽을 수 없습니다.")
        joinParts(candidate).trim().ifEmpty {
            throw AIServiceException(emptyResponseMessage(candidate.optString("finishReason")))
        }
    }

    // MARK: - OpenAI

    private fun sendOpenAIRequest(
        conversation: List<ConversationTurn>,
        botName: String,
        roomId: UUID,
        persona: PersonaStyle?,
        mode: ChatMode
    ): String {
        val apiKey = SecureStore.apiKey(appContext, SecureStore.Credential.OPENAI)
            ?: throw AIServiceException("설정에서 OpenAI API 키를 먼저 등록해주세요.")

        val body = JSONObject()
            .put("model", AIModel.GPT_56_LUNA.rawValue)
            .put("instructions", systemPrompt(botName, persona, mode))
            .put("input", buildOpenAIInput(conversation))
            .put("prompt_cache_key", "gagaodok-room-$roomId")
            // 대화가 뒤에 계속 추가되는 메신저에는 implicit 경계가 가장 잘 맞습니다.
            .put("prompt_cache_options", JSONObject().put("mode", "implicit").put("ttl", "30m"))
            .put("reasoning", JSONObject().put("effort", "medium").put("context", "all_turns"))
            .put("text", JSONObject().put("verbosity", "medium"))
            .put("max_output_tokens", 4096)
            .put("safety_identifier", "gagaodok-local-user")
            .put("store", false)

        val request = Request.Builder()
            .url("https://api.openai.com/v1/responses")
            .addHeader("Content-Type", "application/json")
            .addHeader("Authorization", "Bearer $apiKey")
            .post(body.toString().toRequestBody(JSON_MEDIA))
            .build()

        val json = client.newCall(request).execute().use {
            val raw = it.body?.string().orEmpty()
            if (!it.isSuccessful) throw AIServiceException(errorMessage(raw, it.code, "OpenAI"))
            JSONObject(raw)
        }

        json.optJSONObject("usage")?.let { u ->
            val details = u.optJSONObject("input_tokens_details")
            usage.recordUsage(
                roomId, AIModel.GPT_56_LUNA,
                inputTokens = u.optInt("input_tokens"),
                outputTokens = u.optInt("output_tokens"),
                cachedInputTokens = details?.optInt("cached_tokens") ?: 0,
                cacheWriteTokens = details?.optInt("cache_write_tokens") ?: 0
            )
        }

        json.optString("output_text").takeIf { it.isNotEmpty() }?.let { return it }
        val output = json.optJSONArray("output")
        if (output != null) {
            val text = buildString {
                for (i in 0 until output.length()) {
                    val content = output.optJSONObject(i)?.optJSONArray("content") ?: continue
                    for (j in 0 until content.length()) {
                        val item = content.optJSONObject(j) ?: continue
                        if (item.optString("type") == "output_text") {
                            if (isNotEmpty()) append("\n")
                            append(item.optString("text"))
                        }
                    }
                }
            }
            if (text.isNotEmpty()) return text
        }
        throw AIServiceException("OpenAI 응답 형식을 읽을 수 없습니다.")
    }

    private fun buildOpenAIInput(conversation: List<ConversationTurn>): JSONArray {
        val array = JSONArray()
        for (turn in conversation) {
            if (turn.sender == MessageSender.SAPIENS) {
                // 화면에 남아 있는 과거 전송 오류는 대화 맥락에 포함하지 않습니다.
                if (turn.text.isEmpty() || turn.text.startsWith(ERROR_PREFIX)) continue
                array.put(JSONObject().put("role", "assistant").put("content", turn.text))
                continue
            }
            var text = turn.text
            val attachment = turn.attachment
            if (attachment != null && attachment.type != AttachmentType.IMAGE) {
                decodeText(attachment)?.let {
                    if (text.isNotEmpty()) text += "\n\n"
                    text += "첨부파일 ${attachment.fileName}:\n$it"
                }
            }
            val content = JSONArray()
            if (text.isNotEmpty()) content.put(JSONObject().put("type", "input_text").put("text", text))
            if (attachment != null && attachment.type == AttachmentType.IMAGE) {
                content.put(
                    JSONObject().put("type", "input_image")
                        .put("image_url", "data:${attachment.mimeType};base64,${attachment.dataBase64}")
                        .put("detail", "auto")
                )
            }
            if (content.length() == 0) continue
            array.put(JSONObject().put("role", "user").put("content", content))
        }
        return array
    }

    // MARK: - 요청 조립과 응답 해석

    private fun buildGeminiContents(conversation: List<ConversationTurn>): List<JSONObject> =
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

    private fun decodeText(attachment: ChatAttachment): String? = runCatching {
        String(Base64.decode(attachment.dataBase64, Base64.DEFAULT), Charsets.UTF_8)
    }.getOrNull()

    /// 스트리밍이 아닌 Gemini 요청을 보냅니다.
    ///
    /// **여기서 사용량을 함께 적습니다.** 예전에는 대화 답변만 장부에 적히고
    /// 이 길로 나가는 요청 — 구간 요약, 말투 조사, 말투 분석, 다듬기, 미리보기 — 은
    /// 하나도 안 적혔습니다. 말투 조사는 검색 그라운딩까지 켜는 무거운 요청인데
    /// 앱 화면에서는 공짜처럼 보였습니다. 요금이 과소평가되던 가장 큰 이유입니다.
    private fun postGemini(body: JSONObject, apiKey: String, roomId: UUID): JSONObject {
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

    private data class TextStreamResult(
        val text: String,
        val finishReason: String?,
        val sources: List<String>
    )

    /// 글 하나를 흘려 받습니다. 대화용 스트림과 달리 말풍선으로 가르지 않습니다.
    ///
    /// 지금은 말투 조사만 씁니다. 오래 걸리는 요청이라, 다 받을 때까지 기다리는 대신
    /// 도착하는 대로 넘겨 화면이 무엇을 하고 있는지 보여줄 수 있게 합니다.
    private fun streamGeminiText(
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
    private fun retryable(code: Int): Boolean = code == 429 || code >= 500

    private fun joinParts(candidate: JSONObject): String {
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

    private fun errorMessage(raw: String, code: Int, provider: String): String {
        val message = runCatching {
            JSONObject(raw).optJSONObject("error")?.optString("message")
        }.getOrNull()
        return "$provider 오류: ${message?.takeIf { it.isNotEmpty() } ?: "HTTP $code"}"
    }

    private fun emptyResponseMessage(finishReason: String?): String = when (finishReason) {
        "MAX_TOKENS" -> "답변이 출력 토큰 한도에 먼저 걸렸습니다. 질문을 나눠서 다시 보내주세요."
        "SAFETY", "PROHIBITED_CONTENT" ->
            "Gemini 안전 정책에 걸려 답변이 생성되지 않았습니다. 표현을 바꿔 다시 시도해주세요."
        "RECITATION" -> "저작권 보호 정책 때문에 답변이 중단되었습니다. 질문을 다르게 표현해주세요."
        null, "" -> "Gemini가 빈 응답을 반환했습니다."
        else -> "Gemini가 빈 응답을 반환했습니다. (사유: $finishReason)"
    }

    // MARK: - 말풍선 분리

    /// @param roleplay 이 턴이 상황극임이 확인됐는지. 참일 때만 따옴표 없는
    ///   문단을 묘사로 봅니다. 잡담에서는 대사에 따옴표를 치지 않으므로, 이 조건이
    ///   없으면 평범한 대화가 통째로 묘사가 됩니다.
    fun parseResponseIntoBubbles(
        rawText: String,
        botName: String,
        roleplay: Boolean = false
    ): List<GeneratedMessageBubble> {
        val clean = rawText.trim()
        var paragraphs = clean.split("\n\n")
        if (paragraphs.size == 1) {
            val lines = clean.split("\n")
            if (lines.any { it.startsWith("$botName:") || it.startsWith("사피엔스:") }) paragraphs = lines
        }

        // 한 번에 받는 경로에서는 답변 전체가 여기 들어오므로, 뒤쪽 문단의 따옴표를
        // 보고 앞쪽 문단까지 제대로 가를 수 있습니다. 스트리밍 경로는 문단이 하나씩
        // 들어오므로 호출하는 쪽이 지금까지 본 것을 `roleplay`로 알려 줍니다.
        val isRoleplay = roleplay || paragraphs.any { RoleplayParser.establishesRoleplay(it) }

        val chunks = paragraphs.flatMap { splitTextAndComplexMath(it) }
        val bubbles = mutableListOf<GeneratedMessageBubble>()
        for (item in chunks) {
            var text = item.trim()
            for (prefix in listOf("$botName:", "$botName :", "사피엔스:")) {
                if (text.startsWith(prefix)) {
                    text = text.removePrefix(prefix).trim()
                    break
                }
            }
            val classified = RoleplayParser.classify(text, isRoleplay)
            val (cleanedText, allSpecs) = MathGraphRenderer.extractGraphSpecs(classified.text)
            if (cleanedText.isNotEmpty()) {
                bubbles += GeneratedMessageBubble(cleanedText, kind = classified.kind)
            }
            // 해석하지 못하는 식은 그래프를 만들지 않습니다. 틀린 그림을 내보내는 것보다 낫습니다.
            for (spec in allSpecs.filter { MathGraphRenderer.canRender(it) }) {
                graphAttachment(spec)?.let { bubbles += GeneratedMessageBubble("", attachment = it) }
            }
        }
        if (bubbles.isEmpty() && clean.isNotEmpty()) bubbles += GeneratedMessageBubble(clean)
        return bubbles
    }

    private fun graphAttachment(spec: MathGraphSpec): ChatAttachment? = runCatching {
        val bitmap = MathGraphRenderer.render(spec)
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 90, stream)
        val bytes = stream.toByteArray()
        ChatAttachment(
            type = AttachmentType.IMAGE,
            fileName = "${spec.title}.jpg",
            fileSize = bytes.size.toLong(),
            fileExtension = "jpg",
            dataBase64 = Base64.encodeToString(bytes, Base64.NO_WRAP),
            mimeType = "image/jpeg"
        )
    }.getOrNull()

    private fun splitTextAndComplexMath(paragraph: String): List<String> {
        val lines = paragraph.split("\n")
        if (lines.size <= 1) return listOf(paragraph)

        val result = mutableListOf<String>()
        val buffer = mutableListOf<String>()
        var mathMode: Boolean? = null
        var displayMathClosing: String? = null

        fun flush() {
            if (buffer.isEmpty()) return
            result += buffer.joinToString("\n")
            buffer.clear()
        }

        for (line in lines) {
            val trimmed = line.trim()
            if (trimmed.isEmpty()) continue

            val closing = displayMathClosing
            if (closing != null) {
                buffer += trimmed
                if (trimmed == closing) {
                    flush()
                    displayMathClosing = null
                    mathMode = null
                }
                continue
            }

            if (trimmed == "$$" || trimmed == "\\[") {
                flush()
                mathMode = true
                displayMathClosing = if (trimmed == "$$") "$$" else "\\]"
                buffer += trimmed
                continue
            }

            val isMath = isStandaloneMathLine(trimmed)
            if (mathMode != null && mathMode != isMath) flush()
            mathMode = isMath
            buffer += trimmed
        }
        flush()
        return result.ifEmpty { listOf(paragraph) }
    }

    private fun isStandaloneMathLine(line: String): Boolean {
        if (line.startsWith("$$") || line.startsWith("\\[")) return true
        if (line.startsWith("$") && line.endsWith("$") && line.contains("=")) return true
        if (line.contains("=") &&
            listOf("\\frac", "\\cos", "\\sin", "\\int", "\\lim").any { line.contains(it) }
        ) {
            val korean = line.count { it.code in 0xAC00..0xD7A3 }
            return korean <= 3
        }
        return false
    }

    companion object {
        private const val GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta"

        // Gemini 3.7 Flash는 사고 토큰도 출력 토큰 예산에서 함께 소모합니다.
        // thinkingLevel이 medium이므로 실제로 보이는 답변 길이보다 여유를 두고 잡습니다.
        private const val GEMINI_MAX_OUTPUT_TOKENS = 8192

        private const val CACHE_TTL_SECONDS = 900

        // 명시적 캐시는 1,024토큰 미만이면 생성이 거부됩니다. 어림값이 실제보다 조금 클 수
        // 있으므로 여유를 둡니다. 거부돼도 캐시 없이 진행하므로 대화에는 영향이 없습니다.
        private const val MINIMUM_CACHE_TOKENS = 1200

        // 캐시를 다시 만들 기준입니다. 자세한 셈은 `refreshPrefixCache`에 적었습니다.
        // 짧은 대화에서 몇 마디 붙었다고 다시 만들지 않게 하는 바닥값입니다.
        private const val CACHE_REFRESH_MIN_TAIL_TOKENS = 2000

        // TTL이 이만큼도 안 남았으면 꼬리가 짧아도 새로 만듭니다. 그대로 두면
        // 곧 만료되어 다음 요청이 통째로 전액이 됩니다.
        private const val CACHE_REFRESH_TTL_FLOOR_MILLIS = 240_000L

        // 직전 요청이 이 안에 있었으면 "대화 중"으로 봅니다. 그때만 첫 캐시를 만듭니다.
        private const val CACHE_BURST_WINDOW_MILLIS = 300_000L

        const val ERROR_PREFIX = "요청을 처리하는 중 오류가 발생했습니다:"

        private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()

        private val LOOKUP_INSTRUCTION = """
너는 말투 조사관이다. 사용자가 지정한 인물의 말투를 조사해 정리한다.

먼저 검색이나 주어진 링크·이미지에서 그 인물의 실제 대사를 찾는다. 그 다음 아래 형식으로만 출력한다.

[확신도] 높음/보통/낮음 중 하나와 한 줄 근거.
- 실제 대사를 여러 개 찾았으면 '높음'
- 인물 설명은 찾았지만 대사가 적으면 '보통'
- 인물을 특정하지 못했으면 '낮음'이라고 솔직히 적고 아래 두 절을 비운다

[대사]
찾은 실제 대사를 한 줄에 하나씩, 최대 20줄. 앞에 기호를 붙이지 않는다.
지어내지 말고 실제로 찾은 것만 적는다. 찾지 못했으면 이 절을 비운다.

[말투]
- 문장 끝맺음:
- 높임 수준:
- 1인칭과 호칭:
- 자주 쓰는 표현:
- 문장 길이와 리듬:
- 감정 표현:
- 피해야 할 것:
- 한 줄 요약:

없는 사실을 지어내지 않는다. 확실하지 않으면 확신도를 낮춘다.
        """.trimIndent()

        private val ANALYZE_INSTRUCTION = """
너는 말투 분석가다. 아래 대사를 읽고, 다른 사람이 이 인물의 말투를 그대로 재현할 수 있도록
관찰된 특징만 한국어로 정리한다. 대사에 없는 특징은 지어내지 않는다.

다음 항목을 각각 한 줄씩, '- 항목: 내용' 형태로 쓴다. 해당 없으면 그 줄은 생략한다.
- 문장 끝맺음: 자주 쓰는 어미와 종결 형태를 실제 예와 함께
- 높임 수준: 반말/존댓말/혼용 중 무엇이며 어떤 상황에서 바뀌는지
- 1인칭과 호칭: 자기를 뭐라 부르고 상대를 뭐라 부르는지
- 자주 쓰는 표현: 반복되는 단어·감탄사·말버릇을 원문 그대로
- 문장 길이와 리듬: 짧게 끊는지 길게 이어붙이는지
- 감정 표현: 이모지·물결·느낌표 사용 습관
- 피해야 할 것: 이 인물이 절대 쓰지 않을 법한 말투

마지막에 '- 한 줄 요약:'으로 전체를 한 문장으로 압축한다.
설명이나 인사말 없이 목록만 출력한다.
        """.trimIndent()

        private val REFINE_INSTRUCTION = """
너는 말투 규칙 편집자다. 주어진 말투 규칙을 사용자의 요청대로 고친다.

규칙:
- 요청과 관련된 항목만 고치고 나머지는 원래 문장을 그대로 둔다.
- 원래와 같은 '- 항목: 내용' 목록 형식을 유지한다. 항목 이름을 바꾸지 않는다.
- 요청이 기존 관찰과 충돌하면 요청을 따른다. 사용자가 원하는 방향이 우선이다.
- 요청에 없는 내용을 새로 지어내지 않는다.
- 마지막 '- 한 줄 요약:' 항목도 바뀐 내용에 맞게 갱신한다.

설명이나 인사말 없이 고친 목록만 출력한다.
        """.trimIndent()

        /// 미리보기에서 던져볼 상황들입니다.
        ///
        /// 모드마다 다르게 묻습니다. 챗봇 방에 "미분이 뭐야"를 던져 놓고 결을 판단할 수는 없습니다.
        /// 멘토는 설명·지적·칭찬에서, 챗봇은 인사·감정·거리감에서 말투가 가장 크게 갈립니다.
        fun previewPrompts(mode: ChatMode): List<Pair<String, String>> = when (mode) {
            ChatMode.MATH_MENTOR -> listOf(
                "설명할 때" to "미분이 뭔지 한두 문장으로 짧게 설명해줘.",
                "틀렸다고 말할 때" to "x²의 미분은 2라고 배웠어. 맞지?",
                "칭찬할 때" to "고마워! 덕분에 이해했어."
            )
            ChatMode.COMPANION -> listOf(
                "말 걸었을 때" to "야, 뭐해?",
                "속마음을 물을 때" to "너는 나를 어떻게 생각해?",
                "기분이 안 좋을 때" to "오늘 진짜 최악이었어. 아무것도 하기 싫다."
            )
        }

        /// 지금까지 도착한 글을 보고 무슨 일을 하고 있는지 한 줄로 옮깁니다.
        ///
        /// 답변은 [확신도] → [대사] → [말투] 순서로 나오도록 지침에 적혀 있습니다.
        /// 마지막으로 열린 절이 곧 지금 하고 있는 일입니다. 대사는 몇 줄까지 왔는지
        /// 함께 셉니다 — 숫자가 늘어나는 것이 보여야 멈춘 것이 아님을 알 수 있습니다.
        fun lookupProgressLabel(soFar: String): String = when {
            soFar.contains("[말투]") -> "말투 규칙을 적고 있습니다…"
            soFar.contains("[대사]") -> {
                val lines = soFar.substringAfter("[대사]").substringBefore("[말투]")
                    .lines().map { it.trim() }.count { it.isNotEmpty() }
                if (lines == 0) "대사를 모으고 있습니다…" else "대사를 모으고 있습니다… ${lines}줄"
            }
            soFar.contains("[확신도]") -> "찾은 자료를 살펴보고 있습니다…"
            else -> "자료를 찾고 있습니다…"
        }

        fun parsePersonaLookup(text: String, sources: List<String>): PersonaLookup {
            var confidence = "보통"
            var note = ""
            val samples = mutableListOf<String>()
            val guideLines = mutableListOf<String>()

            var section = 0  // 0: 없음, 1: 대사, 2: 말투

            for (rawLine in text.lines()) {
                val line = rawLine.trim()
                if (line.startsWith("[확신도]")) {
                    val body = line.removePrefix("[확신도]").trim()
                    for (level in listOf("높음", "보통", "낮음")) {
                        if (body.startsWith(level)) {
                            confidence = level
                            note = body.drop(level.length).trim(' ', '-', '–', '—', '(', ')', '·', ',')
                            break
                        }
                    }
                    if (note.isEmpty()) note = body
                    section = 0
                    continue
                }
                if (line.startsWith("[대사]")) { section = 1; continue }
                if (line.startsWith("[말투]")) { section = 2; continue }
                if (line.isEmpty()) continue

                when (section) {
                    1 -> line.trim('-', '•', '*', ' ').trim().takeIf { it.isNotEmpty() }?.let { samples += it }
                    2 -> guideLines += line
                }
            }

            return PersonaLookup(
                confidence = confidence,
                note = note,
                samples = samples,
                styleGuide = guideLines.joinToString("\n"),
                sources = sources.distinct().sorted()
            )
        }

        @Volatile
        private var instance: AIService? = null

        fun get(context: Context): AIService =
            instance ?: synchronized(this) {
                instance ?: AIService(context.applicationContext).also { instance = it }
            }
    }
}
