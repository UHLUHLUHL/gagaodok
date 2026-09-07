package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.data.ModelTokenUsage
import com.sapiens.gagaodok.data.MeasurementCache
import com.sapiens.gagaodok.data.MeasurementLedger
import com.sapiens.gagaodok.data.MeasurementMemory
import com.sapiens.gagaodok.data.MeasurementPolicy
import com.sapiens.gagaodok.data.MeasurementRequests
import com.sapiens.gagaodok.data.MeasurementRun
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.Codec
import com.sapiens.gagaodok.model.MessageSender
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import java.util.UUID

private const val SESSION_GAP_MILLIS = 30 * 60_000L
private const val CACHE_BURST_MILLIS = 5 * 60_000L

/// 지금 동작 중인 캐시 수명입니다. 재사용 모형(`cacheTiming`)은 이것을 따라가야
/// 실제 정책을 반영합니다.
private const val CACHE_TTL_MILLIS = CACHE_TTL_SECONDS * 1000L

/// **간격 버킷의 가운데 경계입니다. 캐시 TTL과 무관하게 고정합니다.**
///
/// 예전에는 이 경계가 곧 TTL이었습니다. 그래서 TTL을 30분으로 올리면 `15~30분`
/// 버킷이 통째로 사라지고, 이미 내보낸 파일과 견줄 수 없게 됩니다. 정책이 바뀌어도
/// **같은 자로 재야** 전후를 비교할 수 있습니다. 버킷은 보고용 눈금이지 정책이 아닙니다.
private const val REPORTING_MID_GAP_MILLIS = 15 * 60_000L

@Serializable
internal data class UsagePatternExport(
    val schemaVersion: Int = 2,
    val privacy: String = "대화 원문, 첨부파일, 방 이름, UUID, API 키, 절대 시각을 포함하지 않음",
    val rooms: List<UsagePatternRoom>
)

@Serializable
internal data class UsagePatternRoom(
    val room: String,
    val mode: String,
    val userMessages: Int,
    val assistantTurns: Int,
    val sessionUserTurns: List<Int>,
    val userGapBuckets: UserGapBuckets,
    /// 위 다섯 칸보다 촘촘한 histogram입니다. 기존 버킷은 이미 내보낸 파일과
    /// 견주려고 그대로 두고, 분석에 필요한 해상도는 여기서 얻습니다.
    ///
    /// 캐시 수명을 견줄 때 5~15분을 한 칸으로 묶으면 10분과 15분을 가를 수 없고,
    /// 30분 초과가 한 칸이면 얼마나 오래 쉬었는지 알 수 없습니다.
    val gapHistogram: GapHistogram,
    val cacheTiming: CacheTimingStats,
    val models: List<UsagePatternModel>
)

@Serializable
internal data class UserGapBuckets(
    val underOneMinute: Int,
    val oneToFiveMinutes: Int,
    val fiveToFifteenMinutes: Int,
    val fifteenToThirtyMinutes: Int,
    val overThirtyMinutes: Int
)

/// 스스로 경계를 밝히는 histogram입니다. 읽는 쪽이 칸의 뜻을 짐작하지 않아도 됩니다.
///
/// `counts[i]`는 `edgeSeconds[i-1]` 초과 `edgeSeconds[i]` 이하이고,
/// 마지막 칸은 `edgeSeconds.last()` 초과입니다. 그래서 `counts`가 하나 더 깁니다.
@Serializable
internal data class GapHistogram(
    val edgeSeconds: List<Int>,
    val counts: List<Int>
)

@Serializable
internal data class CacheTimingStats(
    val eligibleWindows: Int,
    val windowsWithReuse: Int,
    val potentialHits: Int,
    val hitCounts: List<Int>
)

@Serializable
internal data class UsagePatternModel(
    val model: String,
    val inputTokens: Int,
    val cachedInputTokens: Int,
    val cacheWriteTokens: Int,
    val cacheCreateTokens: Int,
    val outputTokens: Int,
    val requestCount: Int,
    val cacheStorageTokenHours: Double,
    val unreportedRequests: Int
)

@Serializable
internal data class OptimizationExport(
    val schemaVersion: Int = 3,
    val privacy: String = "대화 원문, 첨부파일, 방 이름, UUID, API 키, 절대 시각, 프롬프트 원문을 포함하지 않음",
    val currentSnapshot: UsagePatternExport,
    val measurementRuns: List<OptimizationRunExport>
)

@Serializable
internal data class OptimizationRunExport(
    val run: String,
    val status: String,
    val durationMillis: Long,
    val policy: MeasurementPolicy,
    val requests: MeasurementRequests,
    val cache: MeasurementCache,
    /// 기억 갱신이 실제로 진전됐는지입니다. `paidAttempts`가 큰데
    /// `coverageAdvanced`가 0이면 돈만 쓰고 제자리라는 뜻입니다.
    val memory: MeasurementMemory,
    val rooms: List<MeasuredRoomExport>
)

@Serializable
internal data class MeasuredRoomExport(
    val room: String,
    val requestCount: Int,
    val userMessages: Int,
    val userGapBuckets: UserGapBuckets
)

internal fun buildUsagePatternExport(
    rooms: List<ChatRoom>,
    messagesByRoom: Map<UUID, List<ChatMessage>>,
    usageByRoom: Map<UUID, Map<AIModel, ModelTokenUsage>>
): String {
    val exportRooms = rooms.sortedBy { it.createdAt }.mapIndexed { index, room ->
        val messages = messagesByRoom[room.id].orEmpty()
        val userTimes = messages.asSequence()
            .filter { it.sender == MessageSender.USER && !it.deliveryFailed }
            .map { it.timestamp }
            .sorted()
            .toList()
        val sessions = splitSessions(userTimes)
        UsagePatternRoom(
            room = "room-${index + 1}",
            mode = room.resolvedMode.rawValue,
            userMessages = userTimes.size,
            assistantTurns = messages.asSequence()
                .filter { it.sender == MessageSender.SAPIENS }
                .map { it.turnId ?: it.id }
                .distinct()
                .count(),
            sessionUserTurns = sessions.map { it.size },
            userGapBuckets = gapBuckets(userTimes),
            gapHistogram = gapHistogram(userTimes),
            cacheTiming = cacheTiming(sessions),
            models = usageByRoom[room.id].orEmpty().entries
                .sortedBy { it.key.rawValue }
                .map { (model, usage) -> usagePatternModel(model, usage) }
        )
    }
    return Codec.json.encodeToString(UsagePatternExport(rooms = exportRooms))
}

internal fun buildOptimizationExport(
    rooms: List<ChatRoom>,
    messagesByRoom: Map<UUID, List<ChatMessage>>,
    usageByRoom: Map<UUID, Map<AIModel, ModelTokenUsage>>,
    ledger: MeasurementLedger,
    nowMillis: Long = System.currentTimeMillis()
): String {
    val snapshot = Codec.json.decodeFromString<UsagePatternExport>(
        buildUsagePatternExport(rooms, messagesByRoom, usageByRoom)
    )
    val runs = ledger.completedRuns + listOfNotNull(ledger.activeRun)
    val exportedRuns = runs.mapIndexed { runIndex, run ->
        val end = run.endedAtMillis ?: nowMillis
        OptimizationRunExport(
            run = "run-${runIndex + 1}",
            status = if (run.endedAtMillis == null) "active" else "completed",
            durationMillis = (end - run.startedAtMillis).coerceAtLeast(0),
            policy = run.policy,
            requests = run.requests,
            cache = run.cache,
            memory = run.memory,
            rooms = measuredRooms(run, end, rooms, messagesByRoom)
        )
    }
    return Codec.json.encodeToString(
        OptimizationExport(currentSnapshot = snapshot, measurementRuns = exportedRuns)
    )
}

private fun measuredRooms(
    run: MeasurementRun,
    endMillis: Long,
    rooms: List<ChatRoom>,
    messagesByRoom: Map<UUID, List<ChatMessage>>
): List<MeasuredRoomExport> = rooms.sortedBy { it.createdAt }.mapNotNull { room ->
    val times = messagesByRoom[room.id].orEmpty().asSequence()
        .filter { it.sender == MessageSender.USER && !it.deliveryFailed }
        .map { it.timestamp }
        .filter { it in run.startedAtMillis..endMillis }
        .sorted()
        .toList()
    val requests = run.roomRequestCounts[room.id.toString()] ?: 0
    if (times.isEmpty() && requests == 0) return@mapNotNull null
    MeasuredRoomExport(
        room = "room-${rooms.sortedBy { it.createdAt }.indexOf(room) + 1}",
        requestCount = requests,
        userMessages = times.size,
        userGapBuckets = gapBuckets(times)
    )
}

private fun splitSessions(times: List<Long>): List<List<Long>> {
    if (times.isEmpty()) return emptyList()
    val sessions = mutableListOf<MutableList<Long>>()
    times.forEach { timestamp ->
        val current = sessions.lastOrNull()
        if (current == null || timestamp - current.last() > SESSION_GAP_MILLIS) {
            sessions += mutableListOf(timestamp)
        } else {
            current += timestamp
        }
    }
    return sessions
}

private fun gapBuckets(times: List<Long>): UserGapBuckets {
    var underOne = 0
    var oneToFive = 0
    var fiveToFifteen = 0
    var fifteenToThirty = 0
    var overThirty = 0
    times.zipWithNext().forEach { (before, after) ->
        when (after - before) {
            in 0 until 60_000L -> underOne += 1
            in 60_000L..CACHE_BURST_MILLIS -> oneToFive += 1
            in (CACHE_BURST_MILLIS + 1)..REPORTING_MID_GAP_MILLIS -> fiveToFifteen += 1
            in (REPORTING_MID_GAP_MILLIS + 1)..SESSION_GAP_MILLIS -> fifteenToThirty += 1
            else -> overThirty += 1
        }
    }
    return UserGapBuckets(underOne, oneToFive, fiveToFifteen, fifteenToThirty, overThirty)
}

/// 분석에 필요한 해상도로 간격을 셉니다.
///
/// 5~10분과 10~15분을 가르는 이유는 캐시 수명 후보를 견주기 위해서입니다.
/// 30분 위쪽을 1시간·4시간·하루로 나누는 이유는 "얼마나 오래 쉬었는가"가
/// 다음 대화까지 캐시를 남겨 둘 값어치를 정하기 때문입니다.
private val GAP_EDGE_SECONDS = listOf(60, 300, 600, 900, 1_800, 3_600, 14_400, 86_400)

private fun gapHistogram(times: List<Long>): GapHistogram {
    val counts = MutableList(GAP_EDGE_SECONDS.size + 1) { 0 }
    times.zipWithNext().forEach { (before, after) ->
        val seconds = ((after - before).coerceAtLeast(0L) / 1000L)
        val index = GAP_EDGE_SECONDS.indexOfFirst { seconds <= it }
        counts[if (index < 0) GAP_EDGE_SECONDS.size else index] += 1
    }
    return GapHistogram(GAP_EDGE_SECONDS, counts)
}

private fun cacheTiming(sessions: List<List<Long>>): CacheTimingStats {
    val hitCounts = sessions.mapNotNull { times ->
        val triggerIndex = (1 until times.size).firstOrNull { index ->
            times[index] - times[index - 1] <= CACHE_BURST_MILLIS
        } ?: return@mapNotNull null
        val expiresAt = times[triggerIndex] + CACHE_TTL_MILLIS
        times.drop(triggerIndex + 1).count { it <= expiresAt }
    }
    return CacheTimingStats(
        eligibleWindows = hitCounts.size,
        windowsWithReuse = hitCounts.count { it > 0 },
        potentialHits = hitCounts.sum(),
        hitCounts = hitCounts
    )
}

private fun usagePatternModel(model: AIModel, usage: ModelTokenUsage) = UsagePatternModel(
    model = model.rawValue,
    inputTokens = usage.inputTokens,
    cachedInputTokens = usage.cachedInputTokens,
    cacheWriteTokens = usage.cacheWriteTokens,
    cacheCreateTokens = usage.cacheCreateTokens,
    outputTokens = usage.outputTokens,
    requestCount = usage.requestCount,
    cacheStorageTokenHours = usage.cacheStorageTokenHours,
    unreportedRequests = usage.unreportedRequests
)
