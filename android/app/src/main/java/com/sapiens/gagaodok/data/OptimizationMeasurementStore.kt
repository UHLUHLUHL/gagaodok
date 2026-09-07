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
import kotlinx.serialization.Serializable
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
enum class CacheCreateReason {
    /// 이 방에 캐시가 없어서 처음 만들었습니다.
    FIRST,
    /// 새로 붙은 꼬리가 충분히 커져서 다시 만들었습니다.
    TAIL_GREW,
    /// 곧 만료되어서 다시 만들었습니다. **TTL 연장이 줄이려는 것이 이것입니다.**
    EXPIRING_SOON,
    /// 요약 갱신이나 편집으로 접두사 자체가 바뀌었습니다.
    PREFIX_CHANGED
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
    val workload: MeasurementWorkload = MeasurementWorkload.CHAT
)

@Serializable
data class PromptTokenBreakdown(
    val stableSystemTokens: Long = 0,
    val personaAndRoomTokens: Long = 0,
    val digestTokens: Long = 0,
    val recentConversationTokens: Long = 0,
    val dynamicGuidanceTokens: Long = 0
) {
    fun adding(other: PromptTokenBreakdown) = PromptTokenBreakdown(
        stableSystemTokens + other.stableSystemTokens,
        personaAndRoomTokens + other.personaAndRoomTokens,
        digestTokens + other.digestTokens,
        recentConversationTokens + other.recentConversationTokens,
        dynamicGuidanceTokens + other.dynamicGuidanceTokens
    )
}

data class CacheObservation(
    val roomKey: String,
    val estimatedPrefixTokens: Int,
    val decision: CacheDecision,
    val actualCacheTokens: Int = 0
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
    val migrationAttempts: Int = 0
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
    /// 옛 기록에는 없으므로 기본값을 둡니다.
    val memory: MeasurementMemory = MeasurementMemory(),
    val roomRequestCounts: Map<String, Int> = emptyMap()
)

@Serializable
data class MeasurementLedger(
    val schemaVersion: Int = 1,
    val activeRun: MeasurementRun? = null,
    val completedRuns: List<MeasurementRun> = emptyList()
)

class OptimizationMeasurementStore internal constructor(
    private val file: File,
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
        val old = run.requests
        val requests = old.copy(
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
        val rooms = run.roomRequestCounts +
            (observation.roomKey to (run.roomRequestCounts[observation.roomKey] ?: 0) + 1)
        val perWorkload = run.requestsByWorkload +
            (observation.workload to accumulate(
                run.requestsByWorkload[observation.workload] ?: MeasurementRequests(),
                observation
            ))
        replaceActive(run.copy(
            requests = requests,
            requestsByWorkload = perWorkload,
            roomRequestCounts = rooms
        ))
    }

    @Synchronized
    fun observeCache(observation: CacheObservation) {
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
        val old = run.memory
        val advanced = (observation.coverageAfter - observation.coverageBefore).coerceAtLeast(0)
        consecutivePaidFailures = when {
            observation.outcome.advancesCoverage -> 0
            observation.outcome.paid -> consecutivePaidFailures + 1
            else -> consecutivePaidFailures
        }
        replaceActive(run.copy(memory = old.copy(
            attempts = old.attempts + 1,
            paidAttempts = old.paidAttempts + if (observation.outcome.paid) 1 else 0,
            committed = old.committed + if (observation.outcome.advancesCoverage) 1 else 0,
            coverageAdvanced = old.coverageAdvanced + advanced,
            outcomeCounts = old.outcomeCounts +
                (observation.outcome to (old.outcomeCounts[observation.outcome] ?: 0) + 1),
            lastCommittedCoverage =
                if (observation.outcome.advancesCoverage) observation.coverageAfter
                else old.lastCommittedCoverage,
            maxConsecutivePaidFailures =
                maxOf(old.maxConsecutivePaidFailures, consecutivePaidFailures),
            migrationAttempts = old.migrationAttempts + if (observation.migration) 1 else 0
        )))
    }

    /// `observeMemory` 안에서만 만지므로 별도 잠금이 필요 없습니다.
    private var consecutivePaidFailures = 0

    /// 캐시를 새로 만든 이유를 적습니다. 생성에 성공한 뒤에만 부릅니다.
    @Synchronized
    fun observeCacheCreateReason(reason: CacheCreateReason) {
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
