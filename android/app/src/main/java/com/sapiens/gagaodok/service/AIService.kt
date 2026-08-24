package com.sapiens.gagaodok.service

import android.content.Context
import com.sapiens.gagaodok.BuildConfig
import com.sapiens.gagaodok.data.ChatStore
import com.sapiens.gagaodok.data.TokenUsageStore
import com.sapiens.gagaodok.data.OptimizationMeasurementStore
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.Codec
import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.PersonaStyle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import java.io.File
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

/// 두 공급자에 답변을 요청하는 곳입니다.
///
/// 이 파일에는 클래스 자신과 상태, 그리고 밖에서 부르는 입구만 둡니다.
/// 실제 일은 옆의 `AIService*.kt`에 나눠 두었습니다. 파일 이름이 곧 목차입니다.
///
/// - `AIServiceConversation` 대화 한 턴 보내기
/// - `AIServicePrefixCache`  명시적 캐시 규칙
/// - `AIServiceDigest`       구간 요약
/// - `AIServicePersona`      말투 찾기·미리보기
/// - `AIServiceOpenAI`       Luna 쪽 길
/// - `AIServiceTransport`    요청 한 건과 장부 기록
/// - `AIServiceBubbles`      답변을 말풍선으로 가르기
///
/// 멤버가 `private`이 아니고 `internal`인 것은 그 파일들에서 보여야 하기 때문입니다.
/// 앱은 모듈 하나라 `internal`이 곧 앱 전용입니다.
class AIService private constructor(internal val appContext: Context) {
    internal val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(180, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()
    internal val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    internal val store get() = ChatStore.get(appContext)
    internal val usage get() = TokenUsageStore.get(appContext)
    internal val measurement get() = OptimizationMeasurementStore.get(appContext)

    // MARK: - 시스템 지침
    internal fun systemPrompt(botName: String, persona: PersonaStyle?, mode: ChatMode): String {
        // 이 고정 접두사는 두 공급자에서 동일하게 재사용됩니다.
        // 방 이름 같은 동적 값은 끝에 둬 캐시 적중률을 높입니다.
        var prompt = mode.stableSystemPrompt
        // 말투는 방마다 고정이라 캐시 접두사 안쪽에 두어도 적중률이 떨어지지 않습니다.
        persona?.promptSection(
            botName,
            mode,
            companionRepetitionControlEnabled = !BuildConfig.TABLET_MENTOR
        )?.let { prompt += "\n\n$it" }
        prompt += "\n\n# 현재 대화 설정\n이 대화에서 당신의 이름은 '$botName'이다. 자신을 지칭해야 할 때 이 이름을 사용한다."
        return prompt
    }

    // MARK: - 답변 생성
    /// 답변을 말풍선이 완성되는 대로 흘려보냅니다.
    ///
    /// 글자 단위로 올리지 않는 이유는 청크가 수식 한가운데서 끊기기 때문입니다.
    /// `StreamingBubbleBuffer`가 구분자가 모두 닫힌 문단만 통과시키므로
    /// 깨진 수식이 화면에 뜨는 일이 없습니다.
    internal suspend fun streamResponse(
        conversation: List<ConversationTurn>,
        botName: String,
        roomId: UUID,
        model: AIModel,
        persona: PersonaStyle?,
        mode: ChatMode,
        roleplayInProgress: Boolean,
        repetitionAdvice: RepetitionAdvice? = null,
        systemPromptOverride: String? = null,
        onRawText: suspend (String) -> Unit = {},
        onBubble: suspend (GeneratedMessageBubble) -> Unit
    ): String = withContext(Dispatchers.IO) {
        when (model) {
            AIModel.GEMINI_37_FLASH -> sendGeminiRequest(
                conversation, botName, roomId, persona, mode, roleplayInProgress,
                repetitionAdvice, systemPromptOverride, onRawText, onBubble
            )
            AIModel.GPT_56_LUNA -> {
                // Luna는 스트리밍하지 않습니다. 한 번에 받아 말풍선으로 갈라 내보냅니다.
                val raw = sendOpenAIRequest(conversation, botName, roomId, persona, mode, repetitionAdvice)
                onRawText(raw)
                parseResponseIntoBubbles(
                    raw, botName,
                    mode == ChatMode.COMPANION && roleplayInProgress,
                    preserveMentorMath = mode == ChatMode.MATH_MENTOR
                )
                    .forEach { onBubble(it) }
                raw
            }
        }
    }
    internal val cacheFile: File by lazy {
        File(File(appContext.filesDir, "KakaoSapiens").apply { mkdirs() }, "prefix_caches.json")
    }
    // 캐시 이름을 메모리에만 두면 앱을 껐다 켤 때마다 서버에 살아 있는 캐시를 버리고
    // 첫 요청을 전액으로 냅니다. TTL이 남아 있으면 이어서 쓰도록 디스크에 적어 둡니다.
    internal val prefixCaches: MutableMap<String, PrefixCache> by lazy {
        runCatching {
            Codec.json.decodeFromString<Map<String, PrefixCache>>(cacheFile.readText())
                // 이미 만료된 것은 되살리지 않습니다. 서버에도 없습니다.
                .filterValues { it.expiresAtMillis > System.currentTimeMillis() }
                .toMutableMap()
        }.getOrElse { mutableMapOf() }
    }
    internal val refreshingRooms = mutableSetOf<String>()
    /// 방마다 **직전** 요청 시각입니다. 대화가 이어지는 중인지 보는 데 씁니다.
    ///
    /// 메모리에만 둡니다. 앱을 껐다 켜면 비어 있어서 그 방의 캐시가 한 메시지 늦게
    /// 만들어집니다. 파일로 남길 값어치는 없다고 봤습니다.
    internal val lastRequestAt = mutableMapOf<String, Long>()
    internal val summarizingRooms = mutableSetOf<String>()

    companion object {
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
    @Volatile
    internal var instance: AIService? = null
    fun get(context: Context): AIService =
        instance ?: synchronized(this) {
            instance ?: AIService(context.applicationContext).also { instance = it }
        }

    /**
     * 답변 말풍선 분리에 쓰는 순수 문자열 유틸리티입니다.
     *
     * 서비스 인스턴스나 네트워크 상태에 의존하지 않으므로 companion에 둡니다. 그 덕분에
     * 단위 테스트와 스트리밍·일괄 응답 경로가 같은 규칙을 공유합니다.
     */
    internal fun splitTextAndComplexMath(paragraph: String): List<String> =
        com.sapiens.gagaodok.service.splitTextAndComplexMath(paragraph)
    }
}
