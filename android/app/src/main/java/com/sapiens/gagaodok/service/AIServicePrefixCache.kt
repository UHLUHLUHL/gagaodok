package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.data.CacheCreateReason
import com.sapiens.gagaodok.data.CacheDropReason
import com.sapiens.gagaodok.data.CacheDecision
import com.sapiens.gagaodok.data.CacheObservation
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.Codec
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID

// 명시적 캐시(cachedContents)를 만들고 쓰고 버리는 규칙입니다.
// 언제 만들고 언제 안 만드는지가 요금의 대부분을 정합니다.
/// Gemini의 implicit 캐시는 "완전히 똑같은 요청"이 짧은 간격으로 반복될 때만 걸립니다.
/// 채팅처럼 턴이 계속 붙는 패턴에서는 접두사가 같아도 적중하지 않아 실측 적중률이 0%였습니다.
/// 그래서 대화 접두사를 명시적 캐시(cachedContents)로 올려두고 새 턴만 보냅니다.
@Serializable
internal data class PrefixCache(
    val name: String,          // cachedContents/xxxx
    val coveredTurns: Int,     // 이 캐시가 덮는 contents 앞부분의 개수
    val fingerprint: String,   // 덮은 구간이 편집되지 않았는지 확인하는 지문
    val expiresAtMillis: Long,
    /// 이 캐시에 올라가 있는 토큰 수입니다. 다시 만들 값어치가 있는지 따질 때 씁니다.
    /// 예전 파일에는 없던 값이라 기본값을 둡니다.
    val tokenCount: Int = 0,
    /// 예전 파일에는 없으므로 3.7로만 해석합니다. 다른 모델에 재사용하지 않습니다.
    val modelIdentifier: String = AIModel.GEMINI_37_FLASH.rawValue,
    /// 이 캐시를 만든 시각입니다. 실제로 산 시간만큼만 보관료를 적으려고 둡니다.
    /// 예전 파일에는 없으므로 0이면 정산을 건너뜁니다.
    val createdAtMillis: Long = 0L,
    /// 만들 때 대화 끝에서 몇 엔트리를 일부러 캐시 밖에 뒀는지입니다.
    ///
    /// `coveredTurns + lagEntries`가 만들 당시의 대화 길이입니다. 그 뒤로 얼마나
    /// 새로 붙었는지를 재려면 이 값이 있어야 합니다 — 물린 만큼은 처음부터 꼬리에
    /// 있었으므로 "새로 붙은 것"이 아닙니다. 예전 파일에는 없으므로 0입니다.
    val lagEntries: Int = 0,
    /// 만들 당시 요약이 몇 턴까지 덮고 있었는지입니다.
    ///
    /// 대화가 짧아진 이유가 "답을 다시 받아서"인지 "요약이 원문을 접어서"인지
    /// 가르는 데 씁니다. **크기로 추측하면 안 됩니다** — `coveredTurns`는 과거
    /// 어느 시점의 값이고 지금 요청 길이와는 기준 시점이 다릅니다. 둘을 빼서
    /// 원인을 맞히려 하면 우연히 비슷해질 때 틀립니다.
    ///
    /// 옛 파일에는 없으므로 -1(모름)입니다.
    val digestCoveredTurns: Int = -1
)

// 15분에서 30분으로 올립니다.
//
// **보관료보다 다시 만드는 값이 훨씬 큽니다.** 실사용 장부에서 캐시 생성에 올린 토큰
// (725만)이 일반 입력 토큰(677만)보다 많았습니다. 평균 22,862토큰짜리 캐시를 만들어
// 4.1번 읽고 버리고 다시 만들고 있었습니다.
//
// 다시 만드는 방아쇠는 꼬리 크기가 아니라 아래 `CACHE_REFRESH_TTL_FLOOR_MILLIS`였습니다.
// 만료 4분 전이면 꼬리가 작아도 새로 만들기 때문에, 15분 캐시는 생성 11분 만에,
// 30분 캐시는 26분 만에 후보가 됩니다. 실측에서 사용자 발화 간격의 83.6%가 5분
// 이내이고 한 세션이 평균 11.35턴이므로, 대화 한 판은 대략 25~35분 이어집니다.
// 15분은 그 절반만 덮고 세션마다 접두사를 두 번 통째로 다시 올렸습니다.
//
// **이 값은 모형으로 고른 후보이지 증명된 최적값이 아닙니다.** 실사용 비교는
// 캐시 생성 원인별 횟수(`CacheCreateReason`)로 합니다. TTL 연장의 효과는 총액이
// 아니라 `EXPIRING_SOON` 비율의 감소로 읽어야 다른 변경과 섞이지 않습니다.
//
// 바꿀 때는 `MeasurementPolicy.current()`가 이 값을 따라오는지 반드시 함께 봅니다.
// 예전에는 그쪽이 900을 하드코딩해서, 정책을 바꿔도 측정 기록은 옛 값을 가리켰습니다.
internal const val CACHE_TTL_SECONDS = 1800

// Gemini 3.7 Flash 명시적 캐시는 4,096토큰 미만이면 생성이 거부됩니다. 로컬 추정값이
// 실제보다 조금 클 수 있어 약 12% 여유를 둡니다. 짧은 방에서 실패할 캐시 요청을 보내지 않습니다.
internal const val MINIMUM_CACHE_TOKENS = 4600

// 캐시를 다시 만들 기준입니다. 자세한 셈은 `refreshPrefixCache`에 적었습니다.
// 짧은 대화에서 몇 마디 붙었다고 다시 만들지 않게 하는 바닥값입니다.
internal const val CACHE_REFRESH_MIN_TAIL_TOKENS = 2000

// 캐시가 덮는 범위를 대화 끝에서 이만큼 뒤로 물립니다. 사용자 한 마디와 답 한 번입니다.
//
// **캐시가 대화 전체를 덮으면 답을 다시 받을 때마다 캐시가 깨집니다.** 사용자가 자기
// 메시지를 눌러 고치면 그 뒤가 잘려 나가 대화가 캐시보다 짧아지고, 그러면 캐시를
// 통째로 버립니다(`SHRUNK`). 실측 run-9에서 재생성 65회 중 36회가 이것이었고,
// 그 36번은 요청이 캐시 없이 전액으로 나갔습니다.
//
// 마지막 교환을 캐시 밖에 두면 그 교환을 다시 받아도 접두사는 그대로입니다. 대신
// 그 교환이 매 요청에 정가로 실리므로 **공짜가 아닙니다.** 손익분기는 382요청당
// `SHRUNK` 6회이고(현재 36회), 그 아래로 내려가는 경우는 `prefixCacheLagEntries`가
// 막습니다. 더 물리면 막는 양은 거의 안 늘고 꼬리 값만 커집니다.
internal const val CACHE_LAG_ENTRIES = 2

// 옛 캐시를 만났을 때만 쓰는 크기 기준입니다. 아래 주 판단이 실패할 때의 보조입니다.
internal const val REROLL_SHRINK_MAX_ENTRIES = 4

/// 이 줄어듦이 "답을 다시 받은 것"인가.
///
/// **줄어드는 이유가 둘인데 대응이 정반대입니다.**
/// - 답을 다시 받으면 마지막 한두 엔트리만 잘립니다. 물려서 막아야 합니다.
/// - 요약이 진행되면 원문 창이 `THRESHOLD_TURNS`(80)에서 `VERBATIM_WINDOW_TURNS`(30)로
///   접히며 수십 엔트리가 한꺼번에 줍니다. 막을 수도, 막을 필요도 없습니다.
///
/// **크기 차이로 맞히려 하면 안 됩니다.** 처음에 그렇게 썼다가 코덱스 검토에서
/// 걸렸습니다. `coveredTurns`는 과거 어느 시점에 만들어진 캐시의 접두사 길이이고
/// `newSize`는 지금 요청의 길이입니다. **기준 시점이 다른 두 수를 빼고 있어서**,
/// 오래된 캐시 길이와 요약 뒤 길이가 우연히 비슷하면 정상 요약을 재요청으로
/// 오인합니다. 그래서 요약이 진행됐는지를 **부르는 쪽이 알려 줍니다** — 추측할
/// 필요가 없는 사실입니다.
///
/// 크기 기준은 옛 파일에서 온 캐시(`digestCoveredTurns == -1`)에만 씁니다.
internal fun isRerollShrink(
    cacheDigestCoveredTurns: Int,
    requestDigestCoveredTurns: Int,
    coveredTurns: Int,
    newSize: Int
): Boolean {
    // **길이가 그대로인 것이 오히려 재요청의 표시입니다.**
    //
    // 처음에는 "재요청은 최소한 답 하나를 지우므로 1 이상 줄어든다"고 적고 `< 1`에서
    // 걸렀습니다. 틀렸습니다. 캐시는 답변이 저장되기 **전**, 방금 보낸 요청의
    // `contents`로 만들어집니다(`AIServiceConversation.kt`의 `refreshPrefixCache`
    // 호출부). 그래서 `coveredTurns`는 "사용자 메시지까지"의 길이입니다.
    //
    //   캐시 생성 63 → 답변 저장 64 → 답을 다시 받음 63
    //
    // 재요청은 길이를 **줄이는 것이 아니라 되돌립니다.** 차이는 0입니다. `< 1`은
    // 실사용의 네 가지 재요청(일반 재생성·같은 문구·일부 수정·전면 수정)을 전부
    // 놓쳤습니다. AI 응답이 말풍선 여럿으로 나뉘어도 `ConversationTurn.from`이 한
    // 턴으로 묶으므로 언제나 정확히 하나만 지워집니다.
    //
    // 부르는 쪽이 `contents.size <= coveredTurns`일 때만 들어오므로 음수는 나오지
    // 않지만, 조건이 바뀌어도 여기서 무너지지 않게 남겨 둡니다.
    // 회귀 검사는 `RerollShrinkFlowTest`가 실제 경로로 잡습니다.
    if (coveredTurns - newSize < 0) return false
    // 요약이 더 덮게 됐으면 원문이 접힌 것입니다. 크기는 볼 것도 없습니다.
    if (cacheDigestCoveredTurns >= 0) {
        return requestDigestCoveredTurns == cacheDigestCoveredTurns
    }
    // 옛 캐시라 요약 진행 여부를 모릅니다. 크기로만 가릅니다.
    return coveredTurns - newSize <= REROLL_SHRINK_MAX_ENTRIES
}

/// 이 방에서 캐시를 몇 엔트리 뒤로 물릴지 정합니다.
///
/// 물리는 것이 손해인 세 경우를 여기서 걸러 냅니다. 아무 방에나 물리면 고쳐 쓰지
/// 않는 방은 얻는 것 없이 꼬리 값만 더 냅니다.
internal fun prefixCacheLagEntries(
    entryCount: Int,
    laggedPrefixTokens: Int,
    shrinkProne: Boolean
): Int {
    // 잘려 나간 적이 없는 방입니다. 물릴 이유가 없습니다.
    if (!shrinkProne) return 0
    // 물리고 나면 접두사가 남지 않습니다.
    if (entryCount <= CACHE_LAG_ENTRIES) return 0
    // 물리다가 최소치 아래로 내려가면 캐시가 **아예 안 만들어집니다.** 아끼려다
    // 그 방의 캐시를 통째로 잃는 쪽이 훨씬 비쌉니다.
    if (laggedPrefixTokens < MINIMUM_CACHE_TOKENS) return 0
    return CACHE_LAG_ENTRIES
}

// TTL이 이만큼도 안 남았으면 꼬리가 짧아도 새로 만듭니다. 그대로 두면
// 곧 만료되어 다음 요청이 통째로 전액이 됩니다.
internal const val CACHE_REFRESH_TTL_FLOOR_MILLIS = 240_000L

// 직전 요청이 이 안에 있었으면 "대화 중"으로 봅니다. 그때만 첫 캐시를 만듭니다.
internal const val CACHE_BURST_WINDOW_MILLIS = 300_000L

internal fun cacheKey(roomId: UUID, model: AIModel): String = "${roomId}|${model.rawValue}"

internal fun normalizePrefixCacheMap(caches: Map<String, PrefixCache>): MutableMap<String, PrefixCache> =
    caches.entries.associate { (storedKey, cache) ->
        val key = if ('|' in storedKey) storedKey else "$storedKey|${cache.modelIdentifier}"
        key to cache
    }.toMutableMap()

/// "이 방은 답을 다시 받는 방"이라는 표시를 읽습니다.
///
/// 못 읽으면 빈 것으로 칩니다. 캐시를 아끼려는 표시일 뿐이라, 없으면 예전처럼
/// 동작하면 됩니다. 여기서 예외가 나가면 그 방은 대화 자체가 막힙니다.
internal fun readShrinkProneRooms(file: File): MutableSet<String> = runCatching {
    Codec.json.decodeFromString<Set<String>>(file.readText()).toMutableSet()
}.getOrElse { mutableSetOf() }

/// 표시를 적어 둡니다. 실패해도 조용히 넘어갑니다 — 다음 실행에서 한 번 더
/// 겪을 뿐이고, 그것 때문에 대화를 막을 이유는 없습니다.
internal fun writeShrinkProneRooms(file: File, keys: Set<String>) {
    runCatching { file.writeText(Codec.json.encodeToString(keys)) }
}

internal fun AIService.persistCaches() {
    val snapshot = synchronized(prefixCaches) { prefixCaches.toMap() }
    scope.launch { runCatching { cacheFile.writeText(Codec.json.encodeToString(snapshot)) } }
}

internal fun AIService.usablePrefixCache(
    roomId: UUID,
    model: AIModel,
    contents: List<JSONObject>,
    system: String,
    apiKey: String,
    /// 이번 요청에서 요약이 몇 턴까지 덮고 있는지입니다(`ConversationCompactor.Plan.coveredTurns`).
    digestCoveredTurns: Int
): PrefixCache? {
    val key = cacheKey(roomId, model)
    val cache = synchronized(prefixCaches) { prefixCaches[key] } ?: return null
    if (cache.modelIdentifier != model.rawValue) {
        dropCache(key, deleteRemote = false, apiKey = apiKey, reason = CacheDropReason.MODEL_CHANGED)
        return null
    }

    // 만료된 것은 서버에도 없으므로 지울 것이 없습니다.
    if (cache.expiresAtMillis <= System.currentTimeMillis() + 30_000) {
        dropCache(key, deleteRemote = false, apiKey = apiKey, reason = CacheDropReason.EXPIRED)
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
        // 조금만 줄었으면 답을 다시 받은 것입니다. 이 방은 고쳐 쓰는 방이니 다음
        // 캐시는 마지막 교환을 밖에 두고 만들어, 같은 일이 또 나도 접두사가
        // 살아남게 합니다. 한 번 겪고 나서 켜는 이유는, 고쳐 쓰지 않는 방까지
        // 꼬리 값을 물게 하지 않기 위해서입니다.
        //
        // 요약이 접은 것이면 표시하지 않습니다 — 그것까지 세면 요약이 도는 모든
        // 방이 결국 표시되고, 고쳐 쓰지 않는 방도 꼬리 값을 물게 됩니다.
        if (isRerollShrink(
                cacheDigestCoveredTurns = cache.digestCoveredTurns,
                requestDigestCoveredTurns = digestCoveredTurns,
                coveredTurns = cache.coveredTurns,
                newSize = contents.size
            )
        ) markShrinkProne(key)
        dropCache(key, deleteRemote = true, apiKey = apiKey, reason = CacheDropReason.SHRUNK)
        return null
    }
    if (fingerprint(contents.take(cache.coveredTurns), system) != cache.fingerprint) {
        dropCache(key, deleteRemote = true, apiKey = apiKey, reason = CacheDropReason.FINGERPRINT_CHANGED)
        return null
    }
    return cache
}

/// 이 방을 "답을 다시 받는 방"으로 적어 둡니다.
///
/// **디스크에 남깁니다.** 예전에는 메모리에만 뒀는데, 표시는 `SHRUNK`을 한 번
/// 겪어야 켜지는 반면 프로세스는 하루에도 몇 번씩 새로 뜹니다. 실기기 계측에서
/// 저녁부터 아침 사이에 대화 묶음 5번·프로세스 재시작 최소 2번이 있었고, 그 구간
/// 캐시는 끝까지 `lagEntries = 0`이었습니다 — 물림이 한 번도 안 켜졌습니다.
/// 방마다 한 번만 내면 되는 값을 앱을 켤 때마다 다시 내고 있었습니다.
internal fun AIService.markShrinkProne(key: String) {
    if (!shrinkProneRooms.add(key)) return          // 이미 적혀 있으면 파일을 건드리지 않습니다.
    // **쓰는 시점에 다시 모읍니다.** 미리 찍어 두면, 두 방이 거의 같이 표시됐을 때
    // 늦게 도착한 쓰기가 옛 목록으로 덮어써서 한쪽이 사라집니다. 그러면 그 방은
    // 다음 실행에서 값을 한 번 더 냅니다.
    scope.launch { writeShrinkProneRooms(shrinkProneFile, shrinkProneRooms.toSet()) }
}

/// 이 캐시가 산 시간을 보관량(토큰·시간)으로 환산합니다.
///
/// **모르면 0을 돌려줍니다.** 만든 시각이 없는 옛 캐시나 크기를 못 받은 캐시는
/// 지어내지 않고 빠뜨립니다. 시계가 뒤로 조정돼 음수가 나오는 경우도 0입니다 —
/// 그대로 더하면 장부가 거꾸로 줄어듭니다.
internal fun cacheLeaseTokenHours(cache: PrefixCache?, now: Long): Double {
    if (cache == null || cache.tokenCount <= 0 || cache.createdAtMillis <= 0L) return 0.0
    val hours = (now - cache.createdAtMillis).coerceAtLeast(0L) / 3_600_000.0
    return cache.tokenCount * hours
}

/// 로컬 기록에서 지우고, 서버에 남아 있을 것이면 그것도 지웁니다.
///
/// 서버 쪽을 안 지우면 아무도 안 쓰는 캐시가 TTL이 다할 때까지 보관료를 먹습니다.
internal fun AIService.dropCache(
    key: String,
    deleteRemote: Boolean,
    apiKey: String,
    reason: CacheDropReason
) {
    // **왜 버렸는지를 남겨야 다음 생성의 이유를 알 수 있습니다.**
    //
    // 버리고 나면 다음 생성에서는 `previous == null`이라 "이 방에 캐시가 없다"로만
    // 보입니다. 그래서 만료로 버린 것과 처음 만드는 것이 구분되지 않았고, TTL을
    // 늘려서 줄이려던 사건이 `FIRST`에 섞였습니다.
    val removed = synchronized(prefixCaches) { prefixCaches.remove(key) }
    if (removed != null) cacheDropReasons[key] = reason
    // **버리는 캐시도 보관료를 냈습니다.**
    //
    // 예전에는 `refreshPrefixCache`가 이전 캐시를 교체할 때만 적었습니다. 그런데
    // 실측 run-9에서 캐시 생성 74회 중 교체는 11회(15%)뿐이고, 나머지 63회는
    // 여기로 버려졌습니다. 그 63개가 산 시간이 어디에도 안 적혔습니다.
    // 실제 청구서와 대조하니 장부가 보관량의 65%밖에 세지 않았습니다.
    val leased = cacheLeaseTokenHours(removed, System.currentTimeMillis())
    if (leased > 0) {
        val roomId = runCatching { UUID.fromString(key.substringBefore('|')) }.getOrNull()
        val model = AIModel.fromStoredValue(key.substringAfter('|'))
        if (roomId != null && model != null) usage.recordCacheLeaseEnd(roomId, model, leased)
    }
    persistCaches()
    if (deleteRemote && removed != null) {
        scope.launch { deleteCache(removed.name, apiKey) }
    }
}

/// 직전 요청 시각을 꺼내면서 지금 시각으로 갱신합니다.
internal fun AIService.markRequest(roomId: UUID, model: AIModel): Long? = synchronized(lastRequestAt) {
    val key = cacheKey(roomId, model)
    val previous = lastRequestAt[key]
    lastRequestAt[key] = System.currentTimeMillis()
    previous
}

internal suspend fun AIService.refreshPrefixCache(
    roomId: UUID,
    model: AIModel,
    contents: List<JSONObject>,
    system: String,
    apiKey: String,
    previousRequestAt: Long?,
    /// 이번 요청의 요약 적용 범위입니다. 캐시에 적어 두었다가, 다음에 대화가
    /// 짧아졌을 때 그 원인이 요약인지 재요청인지 가르는 데 씁니다.
    digestCoveredTurns: Int,
    measure: Boolean = false
) {
    val key = cacheKey(roomId, model)
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
        val systemTokens = TokenEstimator.textTokens(system)

        // 물렸을 때의 접두사를 **먼저 재고** 그것으로 물릴지 정합니다. 물리고 나서
        // 최소치에 걸리면 캐시가 아예 안 만들어지므로, 순서를 바꾸면 판단이 틀립니다.
        // 물릴 방에서만 잽니다. `estimateTokens`는 사진 헤더까지 디코드하므로
        // 안 물릴 방에서 두 번 도는 것은 그냥 낭비입니다.
        val shrinkProne = key in shrinkProneRooms
        val laggedPrefixTokens = if (shrinkProne) {
            estimateTokens(contents.dropLast(CACHE_LAG_ENTRIES.coerceAtMost(contents.size))) + systemTokens
        } else 0
        val lag = prefixCacheLagEntries(
            entryCount = contents.size,
            laggedPrefixTokens = laggedPrefixTokens,
            shrinkProne = shrinkProne
        )
        // 캐시에 올릴 부분입니다. 물린 꼬리는 매 요청에 따로 실려 나갑니다.
        val prefix = if (lag > 0) contents.dropLast(lag) else contents
        val estimated = if (lag > 0) laggedPrefixTokens else estimateTokens(contents) + systemTokens
        fun observe(decision: CacheDecision, actualTokens: Int = 0) {
            if (measure) measurement.observeCache(
                CacheObservation(key, estimated, decision, actualTokens)
            )
        }
        if (estimated < MINIMUM_CACHE_TOKENS) {
            observe(CacheDecision.BELOW_MINIMUM)
            return
        }

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
            if (!ongoing) {
                observe(CacheDecision.NOT_BURST)
                return
            }
        }

        var reason = if (previous == null) CacheCreateReason.from(cacheDropReasons[key])
            else CacheCreateReason.PREFIX_CHANGED
        if (previous != null) {
            // 이미 같은 구간을 덮고 있으면 다시 만들 것이 없습니다.
            // `coveredTurns + lagEntries`가 만들 당시의 대화 길이입니다. 물린 꼬리는
            // 처음부터 캐시 밖이었으므로 "덮을 것이 남았다"로 세면 안 됩니다.
            if (previous.coveredTurns + previous.lagEntries >= contents.size &&
                previous.expiresAtMillis > now + 60_000
            ) {
                observe(CacheDecision.CACHE_CURRENT)
                return
            }

            // **매 턴 다시 만들지 않습니다.**
            //
            // 예전에는 답변을 받을 때마다 대화 접두사 전체를 새 캐시로 올리고
            // 옛것을 지웠습니다. 한 턴 아끼자고 수만 토큰을 매번 다시 올린 셈입니다.
            // 캐시를 만드는 요청은 그 자체로 청구되고 보관료도 따로 붙는 반면,
            // 안 만들고 넘어갔을 때 더 내는 것은 **새로 붙은 꼬리만큼**뿐입니다.
            //
            // 그래서 꼬리가 캐시의 5분의 1보다 커졌을 때만 새로 만듭니다.
            // 그 아래에서는 새로 만드는 값이 아끼는 값보다 큽니다.
            // 만든 뒤에 **새로 붙은** 만큼만 셉니다. 물린 꼬리까지 꼬리로 세면
            // 갱신 주기가 그만큼 짧아져, 물린 대가를 재생성 횟수로 또 냅니다.
            val tail = estimateTokens(contents.drop(previous.coveredTurns + previous.lagEntries))
            val worthIt = tail >= maxOf(CACHE_REFRESH_MIN_TAIL_TOKENS, previous.tokenCount / 5)
            val expiringSoon = previous.expiresAtMillis <= now + CACHE_REFRESH_TTL_FLOOR_MILLIS
            if (!worthIt && !expiringSoon) {
                observe(CacheDecision.TAIL_TOO_SMALL)
                return
            }
            // **TTL을 바꾼 효과는 `EXPIRED`와 `EXPIRING_SOON`의 합으로 읽습니다.**
            // 캐시가 살아 있을 때 미리 갱신하면 여기, 이미 죽은 뒤면 `EXPIRED`입니다.
            // 이 구분이 없으면 30분이 도움이 됐는지 총액만 보고는 알 수 없고,
            // 같은 시기에 들어간 다른 변경과 섞입니다.
            reason = if (worthIt) CacheCreateReason.TAIL_GREW else CacheCreateReason.EXPIRING_SOON
        }
        observe(CacheDecision.CREATE_ATTEMPT)
        val payload = JSONObject()
            .put("model", "models/${model.rawValue}")
            .put("systemInstruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", system))))
            .put("contents", JSONArray().apply { prefix.forEach { put(it) } })
            .put("ttl", "${CACHE_TTL_SECONDS}s")

        val request = Request.Builder()
            .url("$GEMINI_BASE/cachedContents")
            .addHeader("Content-Type", "application/json")
            .addHeader("x-goog-api-key", apiKey)
            .post(payload.toString().toRequestBody(JSON_MEDIA))
            .build()

        // 캐시는 요금 최적화 수단일 뿐이라 실패해도 대화에는 영향이 없습니다. 조용히 넘어갑니다.
        val json = try {
            client.newCall(request).execute().use {
                if (!it.isSuccessful) {
                    observe(CacheDecision.HTTP_FAILURE)
                    return
                }
                JSONObject(it.body?.string().orEmpty())
            }
        } catch (_: Throwable) {
            observe(CacheDecision.LOCAL_FAILURE)
            return
        }
        val name = json.optString("name").takeIf { it.isNotEmpty() } ?: run {
            observe(CacheDecision.LOCAL_FAILURE)
            return
        }

        val cachedTokens = json.optJSONObject("usageMetadata")?.optInt("totalTokenCount") ?: 0
        observe(CacheDecision.CREATE_SUCCESS, cachedTokens)
        if (measure) measurement.observeCacheCreateReason(reason)
        // 다 썼으므로 지웁니다. 남겨두면 다음 생성이 옛 사유를 다시 씁니다.
        cacheDropReasons.remove(key)
        synchronized(prefixCaches) {
            prefixCaches[key] = PrefixCache(
                name = name,
                coveredTurns = prefix.size,
                fingerprint = fingerprint(prefix, system),
                expiresAtMillis = System.currentTimeMillis() + CACHE_TTL_SECONDS * 1000L,
                tokenCount = if (cachedTokens > 0) cachedTokens else estimated,
                modelIdentifier = model.rawValue,
                createdAtMillis = System.currentTimeMillis(),
                lagEntries = lag,
                digestCoveredTurns = digestCoveredTurns
            )
        }
        persistCaches()

        // 올린 토큰을 적습니다.
        //
        // **올린 토큰을 입력 요금으로 칩니다.** 캐시를 만드는 요청이 청구되는지
        // 문서로 확인하지는 못했습니다. 확실하지 않을 때는 비싼 쪽으로 잡습니다 —
        // 화면의 숫자가 실제보다 적은 것이 많은 것보다 나쁩니다.
        if (cachedTokens > 0) {
            usage.recordCacheCreation(roomId, model, tokens = cachedTokens)
        }

        // 이전 캐시는 보관 요금이 붙으므로 새 캐시가 자리 잡은 뒤 지웁니다.
        // 지울 때 **실제로 산 시간만큼만** 보관량을 적습니다. 예전에는 만들 때
        // TTL 전량을 더해서, 교체로 일찍 끝난 캐시의 보관 시간을 과대평가했습니다.
        previous?.let {
            val hours = cacheLeaseTokenHours(it, System.currentTimeMillis())
            if (hours > 0) usage.recordCacheLeaseEnd(roomId, model, hours)
            deleteCache(it.name, apiKey)
        }
    } finally {
        synchronized(refreshingRooms) { refreshingRooms -= key }
    }
}

internal fun AIService.deleteCache(name: String, apiKey: String) {
    runCatching {
        client.newCall(
            Request.Builder().url("$GEMINI_BASE/$name")
                .addHeader("x-goog-api-key", apiKey)
                .delete().build()
        ).execute().close()
    }
}

internal fun AIService.fingerprint(contents: List<JSONObject>, system: String): String {
    val digest = MessageDigest.getInstance("SHA-256")
    digest.update(system.toByteArray())
    // JSONObject.toString()은 키 순서를 넣은 순서대로 유지합니다.
    // contents를 만드는 코드가 한 곳뿐이라 같은 대화면 같은 문자열이 나옵니다.
    contents.forEach { digest.update(it.toString().toByteArray()) }
    return digest.digest().joinToString("") { "%02x".format(it) }
}

/// Gemini `contents` 배열 하나가 몇 토큰쯤 되는지 어림합니다.
internal fun AIService.estimateTokens(contents: List<JSONObject>): Int {
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
