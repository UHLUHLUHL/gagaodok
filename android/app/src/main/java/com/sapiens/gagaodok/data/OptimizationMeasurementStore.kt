package com.sapiens.gagaodok.data

import android.content.Context
import com.sapiens.gagaodok.model.Codec
// 측정 기록이 실제 정책을 담게 하려고 캐시 상수를 직접 읽습니다.
// 여기서 다시 적으면 두 곳이 어긋나고, 어긋나도 아무도 모릅니다.
import com.sapiens.gagaodok.service.CACHE_BURST_WINDOW_MILLIS
import com.sapiens.gagaodok.service.CACHE_REFRESH_MIN_TAIL_TOKENS
import com.sapiens.gagaodok.service.CACHE_TTL_SECONDS
import com.sapiens.gagaodok.service.MINIMUM_CACHE_TOKENS
import com.sapiens.gagaodok.service.PhoneMemoryObservation
import com.sapiens.gagaodok.service.PhoneMemoryOutcome
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNames
import kotlinx.serialization.encodeToString
import java.io.File

@Serializable
data class MeasurementPolicy(
    val minimumCacheTokens: Int = 4_600,
    val officialMinimumCacheTokens: Int = 4_096,
    val cacheTtlSeconds: Int = 900,
    val burstWindowSeconds: Int = 300,
    val refreshTailMinimumTokens: Int = 2_000
) {
    companion object {
        /// **위 기본값을 그대로 쓰면 안 됩니다.** 그것은 정책을 바꾸기 전에 저장된
        /// 옛 기록을 읽기 위한 값입니다.
        ///
        /// 지금 시작하는 측정 구간에는 실제로 동작 중인 상수를 담아야 합니다.
        /// 예전에는 여기가 하드코딩이라 TTL을 15분에서 바꿔도 기록은 계속 900을
        /// 가리켰고, 그러면 구간끼리 견줄 때 어느 정책이었는지 알 수 없습니다.
        fun current() = MeasurementPolicy(
            minimumCacheTokens = MINIMUM_CACHE_TOKENS,
            cacheTtlSeconds = CACHE_TTL_SECONDS,
            burstWindowSeconds = (CACHE_BURST_WINDOW_MILLIS / 1000L).toInt(),
            refreshTailMinimumTokens = CACHE_REFRESH_MIN_TAIL_TOKENS
        )
    }
}

@Serializable
enum class CacheDecision {
    BELOW_MINIMUM, NOT_BURST, CACHE_CURRENT, TAIL_TOO_SMALL,
    CREATE_ATTEMPT, CREATE_SUCCESS, HTTP_FAILURE, LOCAL_FAILURE
}

/// 캐시를 **새로 만든 이유**입니다.
///
/// TTL을 바꾼 효과는 총액이 아니라 `EXPIRING_SOON`의 감소로 읽어야 합니다.
/// 이 구분이 없으면 같은 시기에 들어간 다른 변경과 섞여서, 30분이 도움이 됐는지
/// 알 수 없습니다. `EXPIRING_SOON`은 접두사 크기 변화에도 강건합니다.
@Serializable
enum class CacheDropReason {
    /// 수명이 다했습니다.
    EXPIRED,
    /// 다른 모델로 바뀌었습니다.
    MODEL_CHANGED,
    /// 대화가 캐시가 덮는 길이보다 짧아졌습니다.
    SHRUNK,
    /// 덮고 있던 구간의 글이 바뀌었습니다. 메시지 편집·삭제입니다.
    FINGERPRINT_CHANGED
}

/// 캐시를 새로 만든 이유입니다.
///
/// **예전에는 `FIRST` 하나가 다섯 가지를 뭉치고 있었습니다.** 만료된 캐시는 지역
/// 기록에서 지워지므로, 다음 생성 때는 "이 방에 캐시가 없다"로 보입니다. 그래서
/// TTL을 늘려서 줄이려던 바로 그 사건이 `FIRST`에 섞여 들어갔습니다. 실측 run-7의
/// `FIRST` 16건이 그 상태였고, 그래서 30분 TTL의 효과는 아직 측정되지 않았습니다.
enum class CacheCreateReason(
    /// TTL을 늘리면 줄어야 하는 원인인지입니다. **효과는 이들의 합으로 읽습니다.**
    val ttlSensitive: Boolean = false
) {
    /// 이 방에 캐시가 있었던 적이 없습니다.
    FIRST,
    /// 수명이 다해 사라진 뒤 다시 만들었습니다.
    EXPIRED(ttlSensitive = true),
    /// 아직 살아 있지만 곧 만료되어 미리 다시 만들었습니다.
    EXPIRING_SOON(ttlSensitive = true),
    /// 새로 붙은 꼬리가 충분히 커져서 다시 만들었습니다.
    TAIL_GREW,
    /// 다른 모델로 바뀌어 다시 만들었습니다.
    MODEL_CHANGED,
    /// 대화가 짧아져 캐시를 버린 뒤 다시 만들었습니다.
    SHRUNK,
    /// 메시지 편집·삭제로 접두사가 바뀌어 다시 만들었습니다.
    FINGERPRINT_CHANGED,
    /// 요약 갱신 등으로 접두사가 바뀌었습니다.
    PREFIX_CHANGED;

    companion object {
        /// 직전에 캐시를 버린 이유로부터 이번 생성의 이유를 정합니다.
        /// 버린 기록이 없으면 이 방에 캐시가 있었던 적이 없다는 뜻입니다.
        fun from(drop: CacheDropReason?): CacheCreateReason = when (drop) {
            null -> FIRST
            CacheDropReason.EXPIRED -> EXPIRED
            CacheDropReason.MODEL_CHANGED -> MODEL_CHANGED
            CacheDropReason.SHRUNK -> SHRUNK
            CacheDropReason.FINGERPRINT_CHANGED -> FINGERPRINT_CHANGED
        }
    }
}

/// 요청이 어떤 일을 하러 나갔는지입니다.
///
/// **섞어 두면 채팅의 지연과 기억 호출의 사고 토큰이 한 통에 담깁니다.** 실사용
/// 내보내기에서 출력의 44.2%가 사고 토큰이었는데, 채팅은 `low`이고 기억은 `high`라
/// 어느 쪽 몫인지 가를 수 없었습니다. 그래서 "챗봇 사고량이 늘었다"고도
/// "기억 호출 탓이다"라고도 말할 수 없었습니다.
@Serializable
enum class MeasurementWorkload { CHAT, MEMORY }

data class RequestObservation(
    val roomKey: String,
    val inputTokens: Int,
    val cachedInputTokens: Int,
    val outputTokens: Int,
    val estimatedPromptTokens: Int,
    val unreported: Boolean = false,
    val prompt: PromptTokenBreakdown = PromptTokenBreakdown(),
    /// 요청을 보낸 뒤 **첫 글자가 오기까지** 걸린 시간입니다.
    val ttftMillis: Long = 0,
    /// 요청을 보낸 뒤 스트림이 끝나기까지 걸린 시간입니다.
    val totalMillis: Long = 0,
    /// 모델이 답을 쓰기 전에 생각하는 데 쓴 토큰입니다. 요금은 출력에 합산되지만,
    /// 느린 이유를 가리려면 따로 봐야 합니다.
    val thoughtsTokens: Int = 0,
    val workload: MeasurementWorkload = MeasurementWorkload.CHAT,
    /// 요청을 보낸 벽시계 시각입니다. 모르면 기록하는 시각으로 대신합니다.
    val sentAtMillis: Long? = null,
    /// 명시적 캐시를 붙여 보냈는지입니다. 모르면 `null`입니다.
    /// 캐시 토큰이 있는데 이것이 `false`면 서버의 암묵 캐시가 읽힌 것입니다.
    val explicitCache: Boolean? = null,
    /// 요청을 받은 모델의 식별자(`AIModel.rawValue`)입니다.
    ///
    /// **기본값을 두지 않습니다.** Gemini와 DeepSeek를 한 회차에서 함께 재므로,
    /// 새 호출부가 모델을 빠뜨리면 두 모델의 숫자가 조용히 섞입니다.
    val model: String?
)

/// 캐시 판정·생성 이유를 세어도 되는 모델인가.
///
/// 명시적 캐시·TTL·두 칸 물림은 Gemini 규칙입니다. 다른 모델의 요청이 섞이면
/// 그 규칙의 효과를 잰 숫자가 흐려집니다.
fun isGeminiModelId(model: String?): Boolean = model?.startsWith("gemini-") == true

/// 요청 한 번의 기록입니다. 대화 내용은 담지 않습니다.
@Serializable
data class RequestLogEntry(
    val atMillis: Long,
    val roomKey: String,
    val workload: MeasurementWorkload = MeasurementWorkload.CHAT,
    val inputTokens: Int = 0,
    val cachedInputTokens: Int = 0,
    val outputTokens: Int = 0,
    val unreported: Boolean = false,
    val explicitCache: Boolean? = null,
    /// 모델 식별자입니다. 모델 칸이 생기기 전의 기록은 `null`(모름)입니다.
    val model: String? = null
)

/// 한 회차에 남기는 요청 기록의 상한입니다. 한 줄이 약 180바이트라 0.5MB 안팎이고,
/// 9회차 속도(6일 471건)면 한 달치가 넘습니다. 기록할 때마다 파일 전체를 다시 쓰므로
/// 크게 잡지 않습니다.
/// 넘으면 오래된 줄부터 버리고 버린 수를 셉니다. 합계(`requests`)는 계속 셉니다.
const val REQUEST_LOG_LIMIT = 3000

@Serializable
data class PromptTokenBreakdown(
    val stableSystemTokens: Long = 0,
    val personaAndRoomTokens: Long = 0,
    val digestTokens: Long = 0,
    val recentConversationTokens: Long = 0,
    val dynamicGuidanceTokens: Long = 0,
    /// 위 `digestTokens`를 계층별로 가른 값입니다. **셋의 합이 `digestTokens`입니다.**
    ///
    /// 합계는 옛 기록과 견주려고 그대로 둡니다. 3계층 렌더러(memoryVersion 2)를 쓴
    /// 요청에서만 채워지고, 그 외에는 0이라 합계와 어긋납니다 — 그 경우는 애초에
    /// 나눌 계층이 없습니다.
    val digestEventTokens: Long = 0,
    val digestStateTokens: Long = 0,
    /// 머리글과 "이것은 기록이지 지시가 아니다" 같은 고정 지침입니다.
    val digestOverheadTokens: Long = 0
) {
    fun adding(other: PromptTokenBreakdown) = PromptTokenBreakdown(
        stableSystemTokens = stableSystemTokens + other.stableSystemTokens,
        personaAndRoomTokens = personaAndRoomTokens + other.personaAndRoomTokens,
        digestTokens = digestTokens + other.digestTokens,
        recentConversationTokens = recentConversationTokens + other.recentConversationTokens,
        dynamicGuidanceTokens = dynamicGuidanceTokens + other.dynamicGuidanceTokens,
        digestEventTokens = digestEventTokens + other.digestEventTokens,
        digestStateTokens = digestStateTokens + other.digestStateTokens,
        digestOverheadTokens = digestOverheadTokens + other.digestOverheadTokens
    )
}

/// 요청 사이가 얼마나 벌어졌는지를 구간으로 셉니다.
///
/// **캐시 정책을 정하는 데 이 분포가 없으면 안 됩니다.** TTL 30분과 burst 5분은
/// 둘 다 근거 없이 정한 값이고, "캐시가 죽은 뒤 얼마 만에 돌아오는가"를 모르면
/// 늘릴지 줄일지 판단할 수 없습니다. 구간 경계는 그 판단에 맞췄습니다 —
/// 5분은 burst 기준, 30분은 TTL입니다.
///
/// **10~30분은 15분에서 한 번 더 나눕니다.** 맥의 TTL이 15분이라, 한 칸으로 두면
/// 15분 전에 돌아온 건지 후에 돌아온 건지 가를 수 없어 15분 대 30분을 판정하지
/// 못합니다. 기존 `tenToThirtyMinutes`는 옛 기록과 견주려고 **두 칸의 합**으로 계속
/// 셉니다 — 전체를 더할 때는 이 칸이나 나눈 두 칸 중 한쪽만 더하십시오.
///
/// 판정 기준: 쉬었다 돌아온 경우 가운데 15~30분 사이 비율이 약 15%를 넘으면 30분이
/// 15분보다 이득입니다(15분 더 두는 보관료 ÷ 그 사이 돌아와 아끼는 입력 값).
@Serializable
data class RequestGapCounts(
    /// 앱을 다시 켠 뒤 첫 요청입니다. 직전 시각이 메모리에만 있어 알 수 없습니다.
    /// **모르는 것을 "오래됐다"로 세면 안 됩니다.** 따로 셉니다.
    val unknown: Int = 0,
    val withinFiveMinutes: Int = 0,
    val fiveToTenMinutes: Int = 0,
    val tenToThirtyMinutes: Int = 0,
    val overThirtyMinutes: Int = 0,
    /// 옛 기록에는 없으므로 기본값을 둡니다.
    val tenToFifteenMinutes: Int = 0,
    val fifteenToThirtyMinutes: Int = 0
)

data class CacheObservation(
    val roomKey: String,
    val estimatedPrefixTokens: Int,
    val decision: CacheDecision,
    val actualCacheTokens: Int = 0,
    /// Gemini가 아니면 세지 않습니다(`isGeminiModelId`).
    val model: String
)

@Serializable
data class MeasurementRequests(
    val requestCount: Int = 0,
    val inputTokens: Long = 0,
    val cachedInputTokens: Long = 0,
    val outputTokens: Long = 0,
    val estimatedPromptTokens: Long = 0,
    val unreportedRequests: Int = 0,
    val cacheHitRequests: Int = 0,
    val prompt: PromptTokenBreakdown = PromptTokenBreakdown(),
    /// 응답이 느린 이유를 가리기 위한 시간입니다.
    ///
    /// 합계뿐 아니라 **최댓값**을 함께 둡니다. 23초짜리 한 건이 3초짜리 열 건에 섞이면
    /// 평균은 5초로 보여서, 정작 문제가 된 그 한 건이 숫자에서 사라집니다.
    val ttftMillisTotal: Long = 0,
    val ttftMillisMax: Long = 0,
    val totalMillisTotal: Long = 0,
    val totalMillisMax: Long = 0,
    /// 요청 하나가 쓴 최대 입력 토큰입니다. 대화가 길어질수록 느려지는지를 봅니다.
    val inputTokensMax: Int = 0,
    /// 사고 토큰입니다. 요금 계산에서는 출력에 합산되지만 여기서는 따로 셉니다.
    val thoughtsTokens: Long = 0,
    val thoughtsTokensMax: Int = 0
)

@Serializable
data class MeasurementCache(
    val decisionCounts: Map<CacheDecision, Int> = emptyMap(),
    /// 새로 만든 캐시를 이유별로 셉니다. 옛 기록에는 없으므로 기본값을 둡니다.
    val createReasons: Map<CacheCreateReason, Int> = emptyMap(),
    val prefixTokenBuckets: List<Int> = List(5) { 0 },
    val actualCacheTokens: Long = 0
)

/// 기억 갱신이 실제로 진전되고 있는지를 보는 집계입니다.
///
/// **`paidAttempts`가 큰데 `coverageAdvanced`가 0이면 돈만 쓰고 제자리입니다.**
/// 그 상태에서는 요약이 안 쌓이므로 최근 원문이 계속 자라고, 접두사와 캐시가
/// 함께 커집니다. 비용이 커지는 것이 원인이 아니라 결과일 수 있다는 뜻입니다.
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class MeasurementMemory(
    val attempts: Int = 0,
    /// 유료 요청을 보낸 시도입니다. 반복 비용은 이 수와 실패율로 읽습니다.
    val paidAttempts: Int = 0,
    val committed: Int = 0,
    /// 실제로 늘어난 요약 범위(턴 수)의 합입니다.
    val coverageAdvanced: Int = 0,
    val outcomeCounts: Map<PhoneMemoryOutcome, Int> = emptyMap(),
    /// 마지막으로 성공한 시점의 요약 범위입니다.
    val lastCommittedCoverage: Int = 0,
    /// 유료 실패가 연속으로 이어진 최대 횟수입니다. 같은 실패가 되풀이되면 커집니다.
    val maxConsecutivePaidFailures: Int = 0,
    /// 전환(v0 → v2) 시도 수입니다. 일반 갱신과 실패 양상이 달라 따로 셉니다.
    val migrationAttempts: Int = 0,
    /// 실패한 건의 사유별 횟수입니다.
    ///
    /// **`MAX_TOKENS`가 대부분이면 출력 예산 부족이고, `SAFETY`나 `RECITATION`이면
    /// 예산을 늘려도 소용없습니다.** 옛 기록에는 없으므로 기본값을 둡니다.
    ///
    /// **옛 이름 `finishReasons`도 함께 읽습니다.** 이름만 바꾸고 별칭을 안 두면
    /// `ignoreUnknownKeys`가 옛 값을 조용히 버리고, 다음 저장 때 파일에서 영영
    /// 사라집니다. 실제로 그렇게 잃었습니다 — run-7의 `NOT_STOP` 8건이 어떤 사유
    /// 였는지가 지금 장부에 없습니다. 되찾을 수는 없지만 되풀이는 막습니다.
    @JsonNames("finishReasons")
    val failureDetails: Map<String, Int> = emptyMap(),
    /// 자리를 만들려고 놓아준 반복 패턴의 누적 수입니다.
    ///
    /// 규칙은 쌓이기만 하므로 어떤 상한을 두든 언젠가 찹니다. 찼을 때 멈추지 않고
    /// 가장 덜 영구적인 것을 놓아주는데, **얼마나 자주 그러는지는 여기로만 알 수
    /// 있습니다.** 조용히 잊는 것이 가장 나쁜 결말입니다.
    val droppedLoopRules: Int = 0
)

@Serializable
data class MeasurementRun(
    val id: Int,
    val startedAtMillis: Long,
    val endedAtMillis: Long? = null,
    val policy: MeasurementPolicy,
    val requests: MeasurementRequests = MeasurementRequests(),
    val cache: MeasurementCache = MeasurementCache(),
    /// 작업 종류별 집계입니다. `requests`는 둘을 합친 값이라 그대로 두고,
    /// 나눠 봐야 하는 것만 여기서 가릅니다.
    val requestsByWorkload: Map<MeasurementWorkload, MeasurementRequests> = emptyMap(),
    /// 모델 식별자별 집계입니다. 옛 기록에는 없으므로 기본값을 둡니다.
    ///
    /// **위아래의 기존 합계(`requests`·`requestsByWorkload`·`memory`·`roomRequestCounts`)는
    /// Gemini만 셉니다**([countsInGeminiLedger]). DeepSeek(실험)를 함께 재는 동안에도
    /// Gemini 캐시 개선을 앞 회차와 같은 숫자로 견줄 수 있게 하려는 것입니다.
    /// 다른 모델은 여기에만 쌓입니다. Gemini도 3.8·3.7이 따로 쌓입니다.
    val byModel: Map<String, MeasurementModelRun> = emptyMap(),
    /// 옛 기록에는 없으므로 기본값을 둡니다.
    val memory: MeasurementMemory = MeasurementMemory(),
    val roomRequestCounts: Map<String, Int> = emptyMap(),
    /// 옛 기록에는 없으므로 기본값을 둡니다.
    val requestGaps: RequestGapCounts = RequestGapCounts(),
    /// 요청마다 시각과 토큰을 남긴 목록입니다. 옛 기록에는 없습니다.
    ///
    /// 간격을 구간으로만 세면 요청의 **순서**가 사라집니다. 캐시 수명은 마지막 요청이
    /// 아니라 캐시를 만든 시각부터 흐르므로, 어떤 TTL이 싼지는 이 순서를 그대로 다시
    /// 돌려 봐야 정할 수 있습니다.
    val requestLog: List<RequestLogEntry> = emptyList(),
    val requestLogDropped: Int = 0
)

/// 연속 실패를 셀 때 기존 Gemini 합계를 가리키는 열쇠입니다. 모델 식별자와 겹치지 않습니다.
private const val GEMINI_LEDGER_KEY = "*gemini-ledger*"

/// 한 모델이 한 회차에 쓴 몫입니다. 회차의 기존 합계와 같은 모양입니다.
@Serializable
data class MeasurementModelRun(
    val requests: MeasurementRequests = MeasurementRequests(),
    val requestsByWorkload: Map<MeasurementWorkload, MeasurementRequests> = emptyMap(),
    val memory: MeasurementMemory = MeasurementMemory()
)

/// 회차의 기존 합계에 넣을 요청인가. Gemini와, 모델 칸이 생기기 전의 요청(모름)입니다.
///
/// 모델 칸이 없던 시절 폰 챗봇방은 Gemini뿐이었으므로 "모름"은 Gemini로 봅니다.
fun countsInGeminiLedger(model: String?): Boolean = model == null || isGeminiModelId(model)

@Serializable
data class MeasurementLedger(
    val schemaVersion: Int = 1,
    val activeRun: MeasurementRun? = null,
    val completedRuns: List<MeasurementRun> = emptyList()
)

class OptimizationMeasurementStore internal constructor(
    private val file: File,
    private val requestLogLimit: Int = REQUEST_LOG_LIMIT,
    private val clock: () -> Long = System::currentTimeMillis
) {
    private val _state = MutableStateFlow(load())
    val state: StateFlow<MeasurementLedger> = _state

    @Synchronized
    fun start(policy: MeasurementPolicy): Boolean {
        if (_state.value.activeRun != null) return false
        val nextId = (_state.value.completedRuns.maxOfOrNull { it.id } ?: 0) + 1
        update(_state.value.copy(activeRun = MeasurementRun(nextId, clock(), policy = policy)))
        return true
    }

    @Synchronized
    fun stop(): Boolean {
        val active = _state.value.activeRun ?: return false
        update(_state.value.copy(
            activeRun = null,
            completedRuns = _state.value.completedRuns + active.copy(endedAtMillis = clock())
        ))
        return true
    }

    @Synchronized
    fun clear() = update(MeasurementLedger())

    private fun accumulate(old: MeasurementRequests, observation: RequestObservation) =
        old.copy(
            requestCount = old.requestCount + 1,
            inputTokens = old.inputTokens + observation.inputTokens.coerceAtLeast(0),
            cachedInputTokens = old.cachedInputTokens + observation.cachedInputTokens.coerceAtLeast(0),
            outputTokens = old.outputTokens + observation.outputTokens.coerceAtLeast(0),
            estimatedPromptTokens = old.estimatedPromptTokens + observation.estimatedPromptTokens.coerceAtLeast(0),
            unreportedRequests = old.unreportedRequests + if (observation.unreported) 1 else 0,
            cacheHitRequests = old.cacheHitRequests + if (observation.cachedInputTokens > 0) 1 else 0,
            prompt = old.prompt.adding(observation.prompt),
            ttftMillisTotal = old.ttftMillisTotal + observation.ttftMillis.coerceAtLeast(0),
            ttftMillisMax = maxOf(old.ttftMillisMax, observation.ttftMillis),
            totalMillisTotal = old.totalMillisTotal + observation.totalMillis.coerceAtLeast(0),
            totalMillisMax = maxOf(old.totalMillisMax, observation.totalMillis),
            inputTokensMax = maxOf(old.inputTokensMax, observation.inputTokens),
            thoughtsTokens = old.thoughtsTokens + observation.thoughtsTokens.coerceAtLeast(0),
            thoughtsTokensMax = maxOf(old.thoughtsTokensMax, observation.thoughtsTokens)
        )

    @Synchronized
    fun observeRequest(observation: RequestObservation) {
        val run = _state.value.activeRun ?: return
        fun perWorkload(old: Map<MeasurementWorkload, MeasurementRequests>) = old +
            (observation.workload to accumulate(old[observation.workload] ?: MeasurementRequests(), observation))
        // 기존 합계는 Gemini만 셉니다(`byModel` 설명).
        val gemini = countsInGeminiLedger(observation.model)
        val requests = if (gemini) accumulate(run.requests, observation) else run.requests
        val rooms = if (gemini) run.roomRequestCounts +
            (observation.roomKey to (run.roomRequestCounts[observation.roomKey] ?: 0) + 1)
            else run.roomRequestCounts
        val workloads = if (gemini) perWorkload(run.requestsByWorkload) else run.requestsByWorkload
        val byModel = observation.model?.let { model ->
            val old = run.byModel[model] ?: MeasurementModelRun()
            run.byModel + (model to old.copy(
                requests = accumulate(old.requests, observation),
                requestsByWorkload = perWorkload(old.requestsByWorkload)
            ))
        } ?: run.byModel
        val entry = RequestLogEntry(
            atMillis = observation.sentAtMillis ?: clock(),
            roomKey = observation.roomKey,
            workload = observation.workload,
            inputTokens = observation.inputTokens.coerceAtLeast(0),
            cachedInputTokens = observation.cachedInputTokens.coerceAtLeast(0),
            outputTokens = observation.outputTokens.coerceAtLeast(0),
            unreported = observation.unreported,
            explicitCache = observation.explicitCache,
            model = observation.model
        )
        val overflow = (run.requestLog.size + 1 - requestLogLimit).coerceAtLeast(0)
        replaceActive(run.copy(
            requests = requests,
            requestsByWorkload = workloads,
            byModel = byModel,
            roomRequestCounts = rooms,
            requestLog = run.requestLog.drop(overflow) + entry,
            requestLogDropped = run.requestLogDropped + overflow
        ))
    }

    @Synchronized
    fun observeCache(observation: CacheObservation) {
        if (!isGeminiModelId(observation.model)) return
        val run = _state.value.activeRun ?: return
        val old = run.cache
        val buckets = old.prefixTokenBuckets.toMutableList().also {
            while (it.size < 5) it += 0
            if (observation.decision == CacheDecision.CREATE_ATTEMPT) return@also
            val index = when (observation.estimatedPrefixTokens) {
                in Int.MIN_VALUE..4_095 -> 0
                in 4_096..4_599 -> 1
                in 4_600..8_191 -> 2
                in 8_192..16_383 -> 3
                else -> 4
            }
            it[index] = it[index] + 1
        }
        val counts = old.decisionCounts +
            (observation.decision to (old.decisionCounts[observation.decision] ?: 0) + 1)
        replaceActive(run.copy(cache = old.copy(
            decisionCounts = counts,
            prefixTokenBuckets = buckets,
            actualCacheTokens = old.actualCacheTokens + observation.actualCacheTokens.coerceAtLeast(0)
        )))
    }

    /// 기억 갱신 한 번의 결과를 적습니다.
    ///
    /// **무료 건너뜀은 연속 실패로 세지 않습니다.** 재시도 대기 중이라 그냥 돌아온
    /// 것은 실패가 아니라 절약이고, 그것까지 세면 실제로 돈을 쓴 실패가 몇 번이나
    /// 이어졌는지가 묻힙니다.
    @Synchronized
    fun observeMemory(observation: PhoneMemoryObservation) {
        val run = _state.value.activeRun ?: return
        // 연속 실패는 **장부마다** 셉니다. 모델이 섞이면 한쪽 성공이 다른 쪽 실패 연쇄를 끊습니다.
        fun nextStreak(key: String): Int {
            val previous = consecutivePaidFailures[key] ?: 0
            val next = when {
                observation.outcome.advancesCoverage -> 0
                observation.outcome.paid -> previous + 1
                else -> previous
            }
            consecutivePaidFailures[key] = next
            return next
        }
        val gemini = countsInGeminiLedger(observation.model)
        val memory = if (gemini) addMemory(run.memory, observation, nextStreak(GEMINI_LEDGER_KEY)) else run.memory
        val old = run.byModel[observation.model] ?: MeasurementModelRun()
        val byModel = run.byModel + (observation.model to old.copy(
            memory = addMemory(old.memory, observation, nextStreak(observation.model))
        ))
        replaceActive(run.copy(memory = memory, byModel = byModel))
    }

    private fun addMemory(old: MeasurementMemory, observation: PhoneMemoryObservation, streak: Int): MeasurementMemory {
        val advanced = (observation.coverageAfter - observation.coverageBefore).coerceAtLeast(0)
        return old.copy(
            attempts = old.attempts + 1,
            paidAttempts = old.paidAttempts + if (observation.outcome.paid) 1 else 0,
            committed = old.committed + if (observation.outcome.advancesCoverage) 1 else 0,
            coverageAdvanced = old.coverageAdvanced + advanced,
            outcomeCounts = old.outcomeCounts +
                (observation.outcome to (old.outcomeCounts[observation.outcome] ?: 0) + 1),
            lastCommittedCoverage =
                if (observation.outcome.advancesCoverage) observation.coverageAfter
                else old.lastCommittedCoverage,
            maxConsecutivePaidFailures = maxOf(old.maxConsecutivePaidFailures, streak),
            migrationAttempts = old.migrationAttempts + if (observation.migration) 1 else 0,
            droppedLoopRules = old.droppedLoopRules + observation.droppedLoops,
            failureDetails = observation.failureDetail?.let {
                old.failureDetails + (it to (old.failureDetails[it] ?: 0) + 1)
            } ?: old.failureDetails
        )
    }

    /// 장부(기존 Gemini 합계, 모델별)마다의 연속 유료 실패 수입니다.
    /// `observeMemory` 안에서만 만지므로 별도 잠금이 필요 없습니다.
    private val consecutivePaidFailures = mutableMapOf<String, Int>()

    /// 직전 요청과의 간격을 구간에 한 건 더합니다.
    @Synchronized
    fun observeRequestGap(previousRequestAt: Long?, now: Long) {
        val run = _state.value.activeRun ?: return
        val g = run.requestGaps
        val gap = previousRequestAt?.let { now - it }
        val next = when {
            gap == null || gap < 0 -> g.copy(unknown = g.unknown + 1)
            gap <= 5 * 60_000L -> g.copy(withinFiveMinutes = g.withinFiveMinutes + 1)
            gap <= 10 * 60_000L -> g.copy(fiveToTenMinutes = g.fiveToTenMinutes + 1)
            gap <= 15 * 60_000L -> g.copy(
                tenToThirtyMinutes = g.tenToThirtyMinutes + 1,
                tenToFifteenMinutes = g.tenToFifteenMinutes + 1
            )
            gap <= 30 * 60_000L -> g.copy(
                tenToThirtyMinutes = g.tenToThirtyMinutes + 1,
                fifteenToThirtyMinutes = g.fifteenToThirtyMinutes + 1
            )
            else -> g.copy(overThirtyMinutes = g.overThirtyMinutes + 1)
        }
        replaceActive(run.copy(requestGaps = next))
    }

    /// 캐시를 새로 만든 이유를 적습니다. 생성에 성공한 뒤에만 부릅니다.
    ///
    /// **잠금이 필요합니다.** 배경의 캐시 갱신에서 불리므로 다른 기록과 동시에
    /// 읽고-고치고-쓰면 한쪽이 사라집니다. `5cde1a3`에서 위 함수를 끼워 넣다가
    /// 이 표시가 옆 함수로 밀려나 한동안 빠져 있었습니다.
    @Synchronized
    fun observeCacheCreateReason(reason: CacheCreateReason, model: String) {
        if (!isGeminiModelId(model)) return
        val run = _state.value.activeRun ?: return
        val old = run.cache
        replaceActive(run.copy(cache = old.copy(
            createReasons = old.createReasons +
                (reason to (old.createReasons[reason] ?: 0) + 1)
        )))
    }

    private fun replaceActive(run: MeasurementRun) = update(_state.value.copy(activeRun = run))

    private fun update(value: MeasurementLedger) {
        _state.value = value
        file.parentFile?.mkdirs()
        file.writeText(Codec.json.encodeToString(value))
    }

    private fun load(): MeasurementLedger = runCatching {
        if (file.exists()) Codec.json.decodeFromString<MeasurementLedger>(file.readText()) else MeasurementLedger()
    }.getOrDefault(MeasurementLedger())

    companion object {
        @Volatile private var instance: OptimizationMeasurementStore? = null
        fun get(context: Context): OptimizationMeasurementStore = instance ?: synchronized(this) {
            instance ?: OptimizationMeasurementStore(
                File(File(context.applicationContext.filesDir, "KakaoSapiens"), "optimization_measurements.json")
            ).also { instance = it }
        }
    }
}
