package com.sapiens.gagaodok.data

import android.content.Context
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.Codec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import java.io.File
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

@Serializable
data class ModelTokenUsage(
    val inputTokens: Int = 0,
    val cachedInputTokens: Int = 0,
    /// OpenAI식 캐시 쓰기입니다. **`inputTokens` 안에 들어 있는 부분집합**이라
    /// 요금을 매길 때 입력에서 덜어 냅니다.
    val cacheWriteTokens: Int = 0,
    /// Gemini식 명시적 캐시를 **새로 만드느라 올린** 토큰입니다.
    ///
    /// 이건 별개의 요청(`cachedContents` POST)이라 어떤 `promptTokenCount`에도
    /// 잡히지 않습니다. 그래서 덜어 내지 않고 그대로 더합니다.
    /// 예전에는 이 값을 아예 안 세서, 캐시를 매 턴 새로 만드는 동안 그 비용이
    /// 앱 화면에서 통째로 사라져 있었습니다.
    val cacheCreateTokens: Int = 0,
    val outputTokens: Int = 0,
    val requestCount: Int = 0,
    /// 명시적 캐시를 올려둔 누적량입니다. 토큰 수 × 보관 시간으로 요금이 매겨집니다.
    val cacheStorageTokenHours: Double = 0.0,
    /// 보낸 것은 확실한데 사용량을 못 받은 요청 수입니다.
    ///
    /// 스트림이 첫 조각도 오기 전에 끊기거나, 답변을 도중에 멈췄는데 그때까지
    /// 사용량 조각이 하나도 안 왔을 때입니다. 청구서에는 있고 여기에는 없는
    /// 요청이라, 숫자를 지어내는 대신 **몇 건인지만** 남깁니다.
    val unreportedRequests: Int = 0
) {
    val totalTokens: Int get() = inputTokens + outputTokens

    val cacheEligibleInputTokens: Int
        get() = max(inputTokens, cachedInputTokens + cacheWriteTokens)

    val cacheHitRate: Double
        get() = if (cacheEligibleInputTokens <= 0) 0.0
        else min(1.0, cachedInputTokens.toDouble() / cacheEligibleInputTokens)

    fun costUSD(model: AIModel): Double {
        val cached = min(cachedInputTokens, inputTokens)
        val writes = min(cacheWriteTokens, max(0, inputTokens - cached))
        val regular = max(0, inputTokens - cached - writes)
        return regular / 1_000_000.0 * model.inputPricePerMillion +
            cached / 1_000_000.0 * model.cachedInputPricePerMillion +
            writes / 1_000_000.0 * model.inputPricePerMillion * model.cacheWriteMultiplier +
            cacheCreateTokens / 1_000_000.0 * model.inputPricePerMillion +
            outputTokens / 1_000_000.0 * model.outputPricePerMillion +
            cacheStorageCostUSD(model)
    }

    /// 명시적 캐시 보관료입니다. 절감액에 비하면 작지만 실제로 청구되는 항목입니다.
    fun cacheStorageCostUSD(model: AIModel): Double =
        cacheStorageTokenHours / 1_000_000.0 * model.cacheStoragePricePerMillionPerHour

    fun costWithoutCacheUSD(model: AIModel): Double =
        inputTokens / 1_000_000.0 * model.inputPricePerMillion +
            outputTokens / 1_000_000.0 * model.outputPricePerMillion

    fun adding(other: ModelTokenUsage) = ModelTokenUsage(
        inputTokens = inputTokens + other.inputTokens,
        cachedInputTokens = cachedInputTokens + other.cachedInputTokens,
        cacheWriteTokens = cacheWriteTokens + other.cacheWriteTokens,
        cacheCreateTokens = cacheCreateTokens + other.cacheCreateTokens,
        outputTokens = outputTokens + other.outputTokens,
        requestCount = requestCount + other.requestCount,
        cacheStorageTokenHours = cacheStorageTokenHours + other.cacheStorageTokenHours,
        unreportedRequests = unreportedRequests + other.unreportedRequests
    )
}

@Serializable
private data class UsageLedger(val rooms: Map<String, Map<String, ModelTokenUsage>>)

/// 방마다 모델마다 쓴 토큰과 요금을 적어 둡니다.
///
/// **API가 실제로 보고한 값만 적습니다.** 예전에는 과거 대화를 글자 수로 추정해
/// 채워 넣었는데, 그 추정이 실제 청구액과 구분 없이 합산되어 숫자 전체를
/// 믿을 수 없게 만들었습니다.
class TokenUsageStore private constructor(context: Context) {

    private val file: File = File(
        File(context.applicationContext.filesDir, "KakaoSapiens").apply { if (!exists()) mkdirs() },
        "token_usage.json"
    )
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _usageByRoom = MutableStateFlow<Map<UUID, Map<AIModel, ModelTokenUsage>>>(emptyMap())
    val usageByRoom: StateFlow<Map<UUID, Map<AIModel, ModelTokenUsage>>> = _usageByRoom

    init {
        load()
    }

    fun recordUsage(
        roomId: UUID,
        model: AIModel,
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        cacheStorageTokenHours: Double = 0.0
    ) {
        add(
            roomId, model,
            ModelTokenUsage(
                inputTokens = max(0, inputTokens),
                cachedInputTokens = max(0, cachedInputTokens),
                cacheWriteTokens = max(0, cacheWriteTokens),
                outputTokens = max(0, outputTokens),
                requestCount = 1,
                cacheStorageTokenHours = max(0.0, cacheStorageTokenHours)
            )
        )
    }

    /// 명시적 캐시를 새로 올린 몫입니다. 만든 토큰 수와 보관량을 함께 적습니다.
    fun recordCacheCreation(roomId: UUID, model: AIModel, tokens: Int, tokenHours: Double) {
        if (tokens <= 0 && tokenHours <= 0) return
        add(
            roomId, model,
            ModelTokenUsage(
                cacheCreateTokens = max(0, tokens),
                // 캐시를 만드는 것도 API 요청 한 건입니다. 그동안 이 요청은
                // 횟수에도 안 잡혀서 "메시지 수보다 요청이 적은" 장부가 나왔습니다.
                requestCount = 1,
                cacheStorageTokenHours = max(0.0, tokenHours)
            )
        )
    }

    /// 보냈지만 사용량을 못 받은 요청을 한 건 적습니다.
    fun recordUnreportedRequest(roomId: UUID, model: AIModel) {
        add(roomId, model, ModelTokenUsage(requestCount = 1, unreportedRequests = 1))
    }

    private fun add(roomId: UUID, model: AIModel, delta: ModelTokenUsage) {
        val room = (_usageByRoom.value[roomId] ?: emptyMap()).toMutableMap()
        room[model] = (room[model] ?: ModelTokenUsage()).adding(delta)
        _usageByRoom.value = _usageByRoom.value + (roomId to room)
        save()
    }

    fun usage(roomId: UUID, model: AIModel): ModelTokenUsage =
        _usageByRoom.value[roomId]?.get(model) ?: ModelTokenUsage()

    fun totalUsage(model: AIModel): ModelTokenUsage =
        _usageByRoom.value.values.fold(ModelTokenUsage()) { acc, room ->
            acc.adding(room[model] ?: ModelTokenUsage())
        }

    fun roomTotal(roomId: UUID): ModelTokenUsage =
        AIModel.entries.fold(ModelTokenUsage()) { acc, model -> acc.adding(usage(roomId, model)) }

    val totalPromptTokens: Int get() = AIModel.entries.sumOf { totalUsage(it).inputTokens }
    val totalCandidatesTokens: Int get() = AIModel.entries.sumOf { totalUsage(it).outputTokens }
    val totalCachedTokens: Int get() = AIModel.entries.sumOf { totalUsage(it).cachedInputTokens }
    val totalTokens: Int get() = totalPromptTokens + totalCandidatesTokens

    val totalCostUSD: Double
        get() = AIModel.entries.sumOf { totalUsage(it).costUSD(it) }

    /// 사용량을 못 받은 요청이 몇 건인지입니다. 0이 아니면 화면의 요금이 실제보다 적습니다.
    val totalUnreportedRequests: Int
        get() = AIModel.entries.sumOf { totalUsage(it).unreportedRequests }

    val totalSavingsUSD: Double
        get() = AIModel.entries.sumOf {
            val usage = totalUsage(it)
            max(0.0, usage.costWithoutCacheUSD(it) - usage.costUSD(it))
        }

    val overallCacheHitRate: Double
        get() = if (totalPromptTokens <= 0) 0.0
        else totalCachedTokens.toDouble() / totalPromptTokens

    fun costUSD(roomId: UUID): Double =
        AIModel.entries.sumOf { usage(roomId, it).costUSD(it) }

    fun resetAll() {
        _usageByRoom.value = emptyMap()
        save()
    }

    private fun save() {
        val snapshot = _usageByRoom.value
        scope.launch {
            runCatching {
                val rooms = snapshot.entries.associate { (roomId, models) ->
                    roomId.toString().uppercase() to models.entries.associate { it.key.rawValue to it.value }
                }
                file.writeText(Codec.json.encodeToString(UsageLedger(rooms)))
            }
        }
    }

    private fun load() {
        if (!file.exists()) return
        val text = runCatching { file.readText() }.getOrNull() ?: return

        runCatching { Codec.json.decodeFromString<UsageLedger>(text) }.getOrNull()?.let { ledger ->
            // 3.6 시절 키는 3.7로 접히기 때문에 덮어쓰지 않고 합산해야 기록이 보존됩니다.
            var migrated = false
            _usageByRoom.value = ledger.rooms.mapNotNull { (roomKey, models) ->
                val roomId = runCatching { UUID.fromString(roomKey) }.getOrNull() ?: return@mapNotNull null
                val merged = mutableMapOf<AIModel, ModelTokenUsage>()
                for ((modelKey, usage) in models) {
                    val model = AIModel.fromStoredValue(modelKey) ?: continue
                    if (model.rawValue != modelKey) migrated = true
                    merged[model] = (merged[model] ?: ModelTokenUsage()).adding(usage)
                }
                roomId to merged.toMap()
            }.toMap()
            // 다음 실행부터는 새 식별자만 읽도록 장부를 한 번 정규화해 둡니다.
            if (migrated) save()
        }
    }

    companion object {
        @Volatile
        private var instance: TokenUsageStore? = null

        fun get(context: Context): TokenUsageStore =
            instance ?: synchronized(this) {
                instance ?: TokenUsageStore(context).also { instance = it }
            }
    }
}
