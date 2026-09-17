import Foundation
import Combine

// 캐시·요약 정책이 실제로 어떻게 움직이는지 재는 장부입니다.
//
// **폰(`android/.../data/OptimizationMeasurementStore.kt`)과 JSON 모양이 같습니다.**
// 필드 이름·열거 이름을 맞춰 두었으므로 두 앱의 기록을 같은 방법으로 읽을 수
// 있습니다. 맥 기록에는 `platform: "mac"`이 붙습니다 — 폰은 모르는 키라 무시합니다.
//
// **대화 내용은 담지 않습니다.** 요청 수, 토큰 수, 캐시 판정과 사유, 방 ID뿐입니다.
//
// 옛 파일에 없는 키는 기본값으로 읽습니다. 필드를 더할 때 이름을 바꾸지 말고
// 더하기만 하십시오. 폰에서 이름만 바꾼 필드가 옛 기록을 조용히 버린 적이 있습니다.

/// 기록 구간이 시작될 때의 캐시 정책입니다. 구간끼리 견줄 때 어느 정책이었는지 봅니다.
struct MeasurementPolicy: Codable, Equatable {
    var minimumCacheTokens: Int = 4_600
    var officialMinimumCacheTokens: Int = 4_096
    var cacheTtlSeconds: Int = 900
    var burstWindowSeconds: Int = 300
    var refreshTailMinimumTokens: Int = 2_000

    /// **실제로 돌고 있는 값을 읽습니다.** 여기서 숫자를 다시 적으면 정책을 바꿔도
    /// 기록은 옛 값을 가리킵니다. 폰에서 실제로 그랬습니다.
    static func current() -> MeasurementPolicy {
        MeasurementPolicy(
            minimumCacheTokens: GeminiCachePolicy.minimumCacheTokens,
            cacheTtlSeconds: GeminiCachePolicy.cacheTTLSeconds,
            burstWindowSeconds: Int(GeminiCachePolicy.burstWindowSeconds),
            refreshTailMinimumTokens: GeminiCachePolicy.refreshTailMinimumTokens
        )
    }

    init(
        minimumCacheTokens: Int = 4_600,
        cacheTtlSeconds: Int = 900,
        burstWindowSeconds: Int = 300,
        refreshTailMinimumTokens: Int = 2_000
    ) {
        self.minimumCacheTokens = minimumCacheTokens
        self.cacheTtlSeconds = cacheTtlSeconds
        self.burstWindowSeconds = burstWindowSeconds
        self.refreshTailMinimumTokens = refreshTailMinimumTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minimumCacheTokens = c.value(.minimumCacheTokens, 4_600)
        officialMinimumCacheTokens = c.value(.officialMinimumCacheTokens, 4_096)
        cacheTtlSeconds = c.value(.cacheTtlSeconds, 900)
        burstWindowSeconds = c.value(.burstWindowSeconds, 300)
        refreshTailMinimumTokens = c.value(.refreshTailMinimumTokens, 2_000)
    }
}

/// 캐시를 만들지 말지 정한 결과입니다.
enum CacheDecision: String, Codable, CaseIterable {
    case BELOW_MINIMUM, NOT_BURST, CACHE_CURRENT, TAIL_TOO_SMALL
    case CREATE_ATTEMPT, CREATE_SUCCESS, HTTP_FAILURE, LOCAL_FAILURE
}

/// 캐시를 버린 이유입니다. 다음에 새로 만들 때의 이유로 이어집니다.
enum CacheDropReason: String, Codable {
    /// 수명이 다했습니다. 서버가 캐시를 못 찾았을 때도 여기입니다.
    case EXPIRED
    /// 다른 모델로 바뀌었습니다.
    case MODEL_CHANGED
    /// 대화가 캐시가 덮는 길이보다 짧아졌습니다. 재요청·과거 수정·요약 전진이 여기 옵니다.
    case SHRUNK
    /// 덮고 있던 구간의 글이 바뀌었습니다.
    case FINGERPRINT_CHANGED
}

/// 캐시를 새로 만든 이유입니다.
///
/// TTL의 효과는 총액이 아니라 `EXPIRED`와 `EXPIRING_SOON`의 합으로 읽습니다.
enum CacheCreateReason: String, Codable {
    case FIRST, EXPIRED, EXPIRING_SOON, TAIL_GREW, MODEL_CHANGED, SHRUNK, FINGERPRINT_CHANGED, PREFIX_CHANGED

    /// 직전에 버린 이유로부터 정합니다. 버린 기록이 없으면 이 방에 캐시가 있었던 적이 없습니다.
    static func from(_ drop: CacheDropReason?) -> CacheCreateReason {
        switch drop {
        case nil: return .FIRST
        case .EXPIRED?: return .EXPIRED
        case .MODEL_CHANGED?: return .MODEL_CHANGED
        case .SHRUNK?: return .SHRUNK
        case .FINGERPRINT_CHANGED?: return .FINGERPRINT_CHANGED
        }
    }
}

/// 요청이 무엇을 하러 나갔는지입니다. 섞으면 채팅 지연과 요약의 사고 토큰이 한 통에 담깁니다.
enum MeasurementWorkload: String, Codable {
    case CHAT, MEMORY
}

/// 구간 요약 한 번이 어떻게 끝났는지입니다. 이름은 폰의 `PhoneMemoryOutcome`에서 가져왔습니다.
///
/// 맥의 요약은 폰의 3계층 기억이 아니라 한 층짜리 구간 요약이라, 폰에만 있는 갈래
/// (전환·상태 검증 등)는 없습니다.
enum DigestOutcome: String, Codable {
    /// 재시도 대기 중이라 보내지 않았습니다.
    case BACKOFF_SKIPPED
    /// 같은 방의 요약이 이미 돌고 있습니다.
    case ALREADY_RUNNING
    /// 그 사이 다른 요청이 같은 구간을 채웠습니다.
    case NO_PENDING
    /// 응답에 후보가 없습니다.
    case NO_CANDIDATE
    /// 종료 사유가 `STOP`이 아닙니다. 대개 출력 한도에 먼저 걸린 것입니다.
    case NOT_STOP
    /// 요약 글이 비어 있습니다.
    case SEGMENT_TOO_LONG
    /// 요청이 실패했습니다.
    case EXCEPTION
    /// 저장했습니다.
    case COMMITTED

    /// 유료 요청을 보낸 뒤에 끝났는지입니다. 반복 비용의 원인은 이것뿐입니다.
    var paid: Bool {
        switch self {
        case .BACKOFF_SKIPPED, .ALREADY_RUNNING, .NO_PENDING: return false
        default: return true
        }
    }

    var advancesCoverage: Bool { self == .COMMITTED }
}

struct PromptTokenBreakdown: Codable, Equatable {
    var stableSystemTokens = 0
    var personaAndRoomTokens = 0
    var digestTokens = 0
    var recentConversationTokens = 0
    var dynamicGuidanceTokens = 0
    /// 3계층 기억의 계층별 분량입니다. 맥은 한 층짜리 요약이라 0입니다(합계는 `digestTokens`).
    var digestEventTokens = 0
    var digestStateTokens = 0
    var digestOverheadTokens = 0

    init(
        stableSystemTokens: Int = 0, personaAndRoomTokens: Int = 0, digestTokens: Int = 0,
        recentConversationTokens: Int = 0, dynamicGuidanceTokens: Int = 0
    ) {
        self.stableSystemTokens = stableSystemTokens
        self.personaAndRoomTokens = personaAndRoomTokens
        self.digestTokens = digestTokens
        self.recentConversationTokens = recentConversationTokens
        self.dynamicGuidanceTokens = dynamicGuidanceTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stableSystemTokens = c.value(.stableSystemTokens, 0)
        personaAndRoomTokens = c.value(.personaAndRoomTokens, 0)
        digestTokens = c.value(.digestTokens, 0)
        recentConversationTokens = c.value(.recentConversationTokens, 0)
        dynamicGuidanceTokens = c.value(.dynamicGuidanceTokens, 0)
        digestEventTokens = c.value(.digestEventTokens, 0)
        digestStateTokens = c.value(.digestStateTokens, 0)
        digestOverheadTokens = c.value(.digestOverheadTokens, 0)
    }

    func adding(_ o: PromptTokenBreakdown) -> PromptTokenBreakdown {
        var r = self
        r.stableSystemTokens += o.stableSystemTokens
        r.personaAndRoomTokens += o.personaAndRoomTokens
        r.digestTokens += o.digestTokens
        r.recentConversationTokens += o.recentConversationTokens
        r.dynamicGuidanceTokens += o.dynamicGuidanceTokens
        r.digestEventTokens += o.digestEventTokens
        r.digestStateTokens += o.digestStateTokens
        r.digestOverheadTokens += o.digestOverheadTokens
        return r
    }
}

/// 요청 사이 간격의 분포입니다. 5분은 burst 기준, 15분은 맥의 TTL, 30분은 폰의 TTL입니다.
///
/// **10~30분은 15분에서 한 번 더 나눕니다.** 맥의 TTL이 15분이라, 한 칸으로 두면
/// 15분 전에 돌아온 건지 후에 돌아온 건지 가를 수 없어 15분 대 30분을 판정하지
/// 못합니다. 기존 `tenToThirtyMinutes`는 옛 기록과 견주려고 **두 칸의 합**으로 계속
/// 셉니다 — 전체를 더할 때는 이 칸이나 나눈 두 칸 중 한쪽만 더하십시오.
///
/// 판정 기준: 쉬었다 돌아온 경우 가운데 15~30분 사이 비율이 약 15%를 넘으면 30분이
/// 15분보다 이득입니다(15분 더 두는 보관료 ÷ 그 사이 돌아와 아끼는 입력 값).
struct RequestGapCounts: Codable, Equatable {
    /// 앱을 다시 켠 뒤 첫 요청입니다. 모르는 것을 "오래됐다"로 세면 TTL 판단이 틀어집니다.
    var unknown = 0
    var withinFiveMinutes = 0
    var fiveToTenMinutes = 0
    var tenToThirtyMinutes = 0
    var tenToFifteenMinutes = 0
    var fifteenToThirtyMinutes = 0
    var overThirtyMinutes = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unknown = c.value(.unknown, 0)
        withinFiveMinutes = c.value(.withinFiveMinutes, 0)
        fiveToTenMinutes = c.value(.fiveToTenMinutes, 0)
        tenToThirtyMinutes = c.value(.tenToThirtyMinutes, 0)
        tenToFifteenMinutes = c.value(.tenToFifteenMinutes, 0)
        fifteenToThirtyMinutes = c.value(.fifteenToThirtyMinutes, 0)
        overThirtyMinutes = c.value(.overThirtyMinutes, 0)
    }

    mutating func add(previous: Date?, now: Date) {
        guard let previous else { unknown += 1; return }
        let gap = now.timeIntervalSince(previous)
        switch gap {
        case ..<0: unknown += 1
        case ...300: withinFiveMinutes += 1
        case ...600: fiveToTenMinutes += 1
        case ...900: tenToThirtyMinutes += 1; tenToFifteenMinutes += 1
        case ...1800: tenToThirtyMinutes += 1; fifteenToThirtyMinutes += 1
        default: overThirtyMinutes += 1
        }
    }
}

/// 요청 한 건의 관측값입니다.
struct RequestObservation {
    var roomKey: String
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var estimatedPromptTokens: Int
    var unreported = false
    var prompt = PromptTokenBreakdown()
    /// 요청을 보낸 뒤 첫 글자가 오기까지(ms). 한 번에 받는 요청은 전체 시간과 같습니다.
    var ttftMillis = 0
    var totalMillis = 0
    /// 사고 토큰입니다. 요금은 출력에 합산되지만 느린 이유를 가리려면 따로 봅니다.
    var thoughtsTokens = 0
    var workload: MeasurementWorkload = .CHAT
    /// 요청을 보낸 시각입니다. 모르면 기록하는 시각으로 대신합니다.
    var sentAt: Date? = nil
    /// 명시적 캐시를 붙여 보냈는지입니다. 모르면 `nil`입니다.
    /// 캐시 토큰이 있는데 이것이 `false`면 서버의 암묵 캐시가 읽힌 것입니다.
    var explicitCache: Bool? = nil
}

/// 요청 한 번의 기록입니다. 대화 내용은 담지 않습니다. 필드는 폰(`RequestLogEntry`)과 같습니다.
struct RequestLogEntry: Codable, Equatable {
    var atMillis: Int
    var roomKey: String
    var workload: MeasurementWorkload = .CHAT
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var unreported = false
    var explicitCache: Bool? = nil

    init(atMillis: Int, roomKey: String, workload: MeasurementWorkload = .CHAT, inputTokens: Int = 0,
         cachedInputTokens: Int = 0, outputTokens: Int = 0, unreported: Bool = false, explicitCache: Bool? = nil) {
        self.atMillis = atMillis
        self.roomKey = roomKey
        self.workload = workload
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.unreported = unreported
        self.explicitCache = explicitCache
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        atMillis = try c.decode(Int.self, forKey: .atMillis)
        roomKey = c.value(.roomKey, "")
        workload = c.value(.workload, .CHAT)
        inputTokens = c.value(.inputTokens, 0)
        cachedInputTokens = c.value(.cachedInputTokens, 0)
        outputTokens = c.value(.outputTokens, 0)
        unreported = c.value(.unreported, false)
        explicitCache = (try? c.decodeIfPresent(Bool.self, forKey: .explicitCache)) ?? nil
    }
}

/// 한 회차에 남기는 요청 기록의 상한입니다. 폰과 같은 값입니다.
/// 기록할 때마다 파일 전체를 다시 쓰므로 크게 잡지 않습니다(한 줄 약 180바이트, 0.5MB 안팎).
/// 넘으면 오래된 줄부터 버리고 버린 수를 셉니다. 합계(`requests`)는 계속 셉니다.
let requestLogLimit = 3000

struct MeasurementRequests: Codable, Equatable {
    var requestCount = 0
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var estimatedPromptTokens = 0
    var unreportedRequests = 0
    var cacheHitRequests = 0
    var prompt = PromptTokenBreakdown()
    /// 합계와 함께 **최댓값**을 둡니다. 느린 한 건이 평균에 묻히지 않게 합니다.
    var ttftMillisTotal = 0
    var ttftMillisMax = 0
    var totalMillisTotal = 0
    var totalMillisMax = 0
    var inputTokensMax = 0
    var thoughtsTokens = 0
    var thoughtsTokensMax = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestCount = c.value(.requestCount, 0)
        inputTokens = c.value(.inputTokens, 0)
        cachedInputTokens = c.value(.cachedInputTokens, 0)
        outputTokens = c.value(.outputTokens, 0)
        estimatedPromptTokens = c.value(.estimatedPromptTokens, 0)
        unreportedRequests = c.value(.unreportedRequests, 0)
        cacheHitRequests = c.value(.cacheHitRequests, 0)
        prompt = c.value(.prompt, PromptTokenBreakdown())
        ttftMillisTotal = c.value(.ttftMillisTotal, 0)
        ttftMillisMax = c.value(.ttftMillisMax, 0)
        totalMillisTotal = c.value(.totalMillisTotal, 0)
        totalMillisMax = c.value(.totalMillisMax, 0)
        inputTokensMax = c.value(.inputTokensMax, 0)
        thoughtsTokens = c.value(.thoughtsTokens, 0)
        thoughtsTokensMax = c.value(.thoughtsTokensMax, 0)
    }

    mutating func add(_ o: RequestObservation) {
        requestCount += 1
        inputTokens += max(0, o.inputTokens)
        cachedInputTokens += max(0, o.cachedInputTokens)
        outputTokens += max(0, o.outputTokens)
        estimatedPromptTokens += max(0, o.estimatedPromptTokens)
        if o.unreported { unreportedRequests += 1 }
        // 캐시를 붙였다는 사실이 아니라, 서버가 캐시에서 읽었다고 보고한 것으로 셉니다.
        if o.cachedInputTokens > 0 { cacheHitRequests += 1 }
        prompt = prompt.adding(o.prompt)
        ttftMillisTotal += max(0, o.ttftMillis)
        ttftMillisMax = max(ttftMillisMax, o.ttftMillis)
        totalMillisTotal += max(0, o.totalMillis)
        totalMillisMax = max(totalMillisMax, o.totalMillis)
        inputTokensMax = max(inputTokensMax, o.inputTokens)
        thoughtsTokens += max(0, o.thoughtsTokens)
        thoughtsTokensMax = max(thoughtsTokensMax, o.thoughtsTokens)
    }
}

struct MeasurementCache: Codable, Equatable {
    /// 열거 이름을 키로 씁니다. Swift는 열거 키 사전을 배열로 적으므로 문자열로 둡니다.
    var decisionCounts: [String: Int] = [:]
    var createReasons: [String: Int] = [:]
    /// 추정 접두사 크기의 분포입니다: <4,096 / 4,096~4,599 / 4,600~8,191 / 8,192~16,383 / 그 이상.
    var prefixTokenBuckets: [Int] = [0, 0, 0, 0, 0]
    var actualCacheTokens = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decisionCounts = c.value(.decisionCounts, [:])
        createReasons = c.value(.createReasons, [:])
        prefixTokenBuckets = c.value(.prefixTokenBuckets, [0, 0, 0, 0, 0])
        actualCacheTokens = c.value(.actualCacheTokens, 0)
    }

    static func bucket(for tokens: Int) -> Int {
        switch tokens {
        case ..<4_096: return 0
        case ..<4_600: return 1
        case ..<8_192: return 2
        case ..<16_384: return 3
        default: return 4
        }
    }
}

/// 요약이 실제로 진전되고 있는지 봅니다.
///
/// **`paidAttempts`가 큰데 `coverageAdvanced`가 0이면 돈만 쓰고 제자리입니다.**
struct MeasurementMemory: Codable, Equatable {
    var attempts = 0
    var paidAttempts = 0
    var committed = 0
    var coverageAdvanced = 0
    var outcomeCounts: [String: Int] = [:]
    var lastCommittedCoverage = 0
    var maxConsecutivePaidFailures = 0
    var migrationAttempts = 0
    /// 실패 사유별 횟수입니다. `MAX_TOKENS`면 예산 부족, `SAFETY`면 예산과 무관합니다.
    var failureDetails: [String: Int] = [:]
    var droppedLoopRules = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attempts = c.value(.attempts, 0)
        paidAttempts = c.value(.paidAttempts, 0)
        committed = c.value(.committed, 0)
        coverageAdvanced = c.value(.coverageAdvanced, 0)
        outcomeCounts = c.value(.outcomeCounts, [:])
        lastCommittedCoverage = c.value(.lastCommittedCoverage, 0)
        maxConsecutivePaidFailures = c.value(.maxConsecutivePaidFailures, 0)
        migrationAttempts = c.value(.migrationAttempts, 0)
        failureDetails = c.value(.failureDetails, [:])
        droppedLoopRules = c.value(.droppedLoopRules, 0)
    }
}

struct MeasurementRun: Codable, Equatable {
    var id: Int
    var startedAtMillis: Int
    var endedAtMillis: Int?
    var policy: MeasurementPolicy
    var requests = MeasurementRequests()
    var cache = MeasurementCache()
    var requestsByWorkload: [String: MeasurementRequests] = [:]
    var memory = MeasurementMemory()
    var roomRequestCounts: [String: Int] = [:]
    var requestGaps = RequestGapCounts()
    /// 요청마다 시각과 토큰을 남긴 목록입니다. 옛 기록에는 없습니다.
    ///
    /// 간격을 구간으로만 세면 요청의 순서가 사라집니다. 캐시 수명은 캐시를 만든 시각부터
    /// 흐르므로, 어떤 TTL이 싼지는 이 순서를 그대로 다시 돌려 봐야 정할 수 있습니다.
    var requestLog: [RequestLogEntry] = []
    var requestLogDropped = 0

    init(id: Int, startedAtMillis: Int, policy: MeasurementPolicy) {
        self.id = id
        self.startedAtMillis = startedAtMillis
        self.policy = policy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        startedAtMillis = try c.decode(Int.self, forKey: .startedAtMillis)
        endedAtMillis = try c.decodeIfPresent(Int.self, forKey: .endedAtMillis)
        policy = c.value(.policy, MeasurementPolicy())
        requests = c.value(.requests, MeasurementRequests())
        cache = c.value(.cache, MeasurementCache())
        requestsByWorkload = c.value(.requestsByWorkload, [:])
        memory = c.value(.memory, MeasurementMemory())
        roomRequestCounts = c.value(.roomRequestCounts, [:])
        requestGaps = c.value(.requestGaps, RequestGapCounts())
        requestLog = c.value(.requestLog, [])
        requestLogDropped = c.value(.requestLogDropped, 0)
    }
}

struct MeasurementLedger: Codable, Equatable {
    var schemaVersion = 1
    var platform = "mac"
    var activeRun: MeasurementRun?
    var completedRuns: [MeasurementRun] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.value(.schemaVersion, 1)
        platform = c.value(.platform, "mac")
        activeRun = try c.decodeIfPresent(MeasurementRun.self, forKey: .activeRun)
        completedRuns = c.value(.completedRuns, [])
    }
}

extension KeyedDecodingContainer {
    /// 없거나 읽을 수 없으면 기본값입니다. 옛 파일과 새 필드를 함께 받기 위한 것입니다.
    fileprivate func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

/// 측정 장부입니다. **메인 액터에서만 고칩니다** — 그것이 잠금입니다.
///
/// 폰에서는 기록 함수 하나가 잠금 표시를 잃어 배경 작업과 겹칠 수 있었습니다.
/// 여기서는 모든 기록이 메인 액터를 거치므로 그런 누락이 생길 자리가 없습니다.
@MainActor
final class OptimizationMeasurementStore: ObservableObject {
    static let shared = OptimizationMeasurementStore(fileURL: {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KakaoSapiens", isDirectory: true)
        return base.appendingPathComponent("optimization_measurements.json")
    }())

    @Published private(set) var ledger: MeasurementLedger
    let fileURL: URL
    private let clock: () -> Date
    private var consecutivePaidFailures = 0

    private let logLimit: Int

    init(fileURL: URL, logLimit: Int = requestLogLimit, clock: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.logLimit = logLimit
        self.clock = clock
        ledger = (try? JSONDecoder().decode(MeasurementLedger.self, from: Data(contentsOf: fileURL)))
            ?? MeasurementLedger()
    }

    var isMeasuring: Bool { ledger.activeRun != nil }

    private var nowMillis: Int { Int(clock().timeIntervalSince1970 * 1000) }

    @discardableResult
    func start(policy: MeasurementPolicy = .current()) -> Bool {
        guard ledger.activeRun == nil else { return false }
        let nextId = (ledger.completedRuns.map(\.id).max() ?? 0) + 1
        var next = ledger
        next.activeRun = MeasurementRun(id: nextId, startedAtMillis: nowMillis, policy: policy)
        consecutivePaidFailures = 0
        update(next)
        return true
    }

    @discardableResult
    func stop() -> Bool {
        guard var run = ledger.activeRun else { return false }
        run.endedAtMillis = nowMillis
        var next = ledger
        next.activeRun = nil
        next.completedRuns.append(run)
        update(next)
        return true
    }

    func clear() {
        consecutivePaidFailures = 0
        update(MeasurementLedger())
    }

    func observeRequest(_ o: RequestObservation) {
        mutateRun { run in
            run.requests.add(o)
            run.requestsByWorkload[o.workload.rawValue, default: MeasurementRequests()].add(o)
            run.roomRequestCounts[o.roomKey, default: 0] += 1
            run.requestLog.append(RequestLogEntry(
                atMillis: o.sentAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? nowMillis,
                roomKey: o.roomKey,
                workload: o.workload,
                inputTokens: max(0, o.inputTokens),
                cachedInputTokens: max(0, o.cachedInputTokens),
                outputTokens: max(0, o.outputTokens),
                unreported: o.unreported,
                explicitCache: o.explicitCache
            ))
            let overflow = max(0, run.requestLog.count - logLimit)
            if overflow > 0 {
                run.requestLog.removeFirst(overflow)
                run.requestLogDropped += overflow
            }
        }
    }

    func observeCache(_ decision: CacheDecision, estimatedPrefixTokens: Int, actualCacheTokens: Int = 0) {
        mutateRun { run in
            run.cache.decisionCounts[decision.rawValue, default: 0] += 1
            // 시도는 판정이 아니라 과정이라 크기 분포에서 뺍니다(폰과 같음).
            if decision != .CREATE_ATTEMPT {
                while run.cache.prefixTokenBuckets.count < 5 { run.cache.prefixTokenBuckets.append(0) }
                run.cache.prefixTokenBuckets[MeasurementCache.bucket(for: estimatedPrefixTokens)] += 1
            }
            run.cache.actualCacheTokens += max(0, actualCacheTokens)
        }
    }

    /// 캐시를 새로 만든 이유를 적습니다. 생성에 성공한 뒤에만 부릅니다.
    func observeCacheCreateReason(_ reason: CacheCreateReason) {
        mutateRun { $0.cache.createReasons[reason.rawValue, default: 0] += 1 }
    }

    func observeRequestGap(previous: Date?, now: Date) {
        mutateRun { $0.requestGaps.add(previous: previous, now: now) }
    }

    /// 요약 한 번의 결과입니다. **무료 건너뜀은 연속 실패로 세지 않습니다** —
    /// 그것까지 세면 실제로 돈을 쓴 실패가 몇 번 이어졌는지가 묻힙니다.
    func observeDigest(_ outcome: DigestOutcome, coverageBefore: Int, coverageAfter: Int, failureDetail: String? = nil) {
        guard ledger.activeRun != nil else { return }
        if outcome.advancesCoverage { consecutivePaidFailures = 0 }
        else if outcome.paid { consecutivePaidFailures += 1 }
        let streak = consecutivePaidFailures
        mutateRun { run in
            var m = run.memory
            m.attempts += 1
            if outcome.paid { m.paidAttempts += 1 }
            if outcome.advancesCoverage {
                m.committed += 1
                m.lastCommittedCoverage = coverageAfter
            }
            m.coverageAdvanced += max(0, coverageAfter - coverageBefore)
            m.outcomeCounts[outcome.rawValue, default: 0] += 1
            m.maxConsecutivePaidFailures = max(m.maxConsecutivePaidFailures, streak)
            if let failureDetail { m.failureDetails[failureDetail, default: 0] += 1 }
            run.memory = m
        }
    }

    private func mutateRun(_ change: (inout MeasurementRun) -> Void) {
        guard var run = ledger.activeRun else { return }
        change(&run)
        var next = ledger
        next.activeRun = run
        update(next)
    }

    private func update(_ value: MeasurementLedger) {
        ledger = value
        let url = fileURL
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
