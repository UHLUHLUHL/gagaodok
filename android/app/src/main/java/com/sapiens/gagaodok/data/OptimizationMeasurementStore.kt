package com.sapiens.gagaodok.data

import android.content.Context
import com.sapiens.gagaodok.model.Codec
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
    companion object { fun current() = MeasurementPolicy() }
}

@Serializable
enum class CacheDecision {
    BELOW_MINIMUM, NOT_BURST, CACHE_CURRENT, TAIL_TOO_SMALL,
    CREATE_ATTEMPT, CREATE_SUCCESS, HTTP_FAILURE, LOCAL_FAILURE
}

data class RequestObservation(
    val roomKey: String,
    val inputTokens: Int,
    val cachedInputTokens: Int,
    val outputTokens: Int,
    val estimatedPromptTokens: Int,
    val unreported: Boolean = false,
    val prompt: PromptTokenBreakdown = PromptTokenBreakdown()
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
    val prompt: PromptTokenBreakdown = PromptTokenBreakdown()
)

@Serializable
data class MeasurementCache(
    val decisionCounts: Map<CacheDecision, Int> = emptyMap(),
    val prefixTokenBuckets: List<Int> = List(5) { 0 },
    val actualCacheTokens: Long = 0
)

@Serializable
data class MeasurementRun(
    val id: Int,
    val startedAtMillis: Long,
    val endedAtMillis: Long? = null,
    val policy: MeasurementPolicy,
    val requests: MeasurementRequests = MeasurementRequests(),
    val cache: MeasurementCache = MeasurementCache(),
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
            prompt = old.prompt.adding(observation.prompt)
        )
        val rooms = run.roomRequestCounts +
            (observation.roomKey to (run.roomRequestCounts[observation.roomKey] ?: 0) + 1)
        replaceActive(run.copy(requests = requests, roomRequestCounts = rooms))
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
