package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.data.ModelTokenUsage
import com.sapiens.gagaodok.data.MeasurementCache
import com.sapiens.gagaodok.data.MeasurementLedger
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
private const val CACHE_TTL_MILLIS = 15 * 60_000L

@Serializable
internal data class UsagePatternExport(
    val schemaVersion: Int = 1,
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
    val schemaVersion: Int = 2,
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
            in (CACHE_BURST_MILLIS + 1)..CACHE_TTL_MILLIS -> fiveToFifteen += 1
            in (CACHE_TTL_MILLIS + 1)..SESSION_GAP_MILLIS -> fifteenToThirty += 1
            else -> overThirty += 1
        }
    }
    return UserGapBuckets(underOne, oneToFive, fiveToFifteen, fifteenToThirty, overThirty)
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
