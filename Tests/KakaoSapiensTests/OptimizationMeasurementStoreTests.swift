import Foundation

/// 맥 측정 장부를 확인합니다. 폰(`OptimizationMeasurementStore.kt`)과 같은 형식이어야 합니다.
///
/// 실행:
///   swiftc -parse-as-library Tests/KakaoSapiensTests/OptimizationMeasurementStoreTests.swift \
///     Sources/KakaoSapiens/Services/OptimizationMeasurementStore.swift \
///     Sources/KakaoSapiens/Services/GeminiCachePolicy.swift \
///     Sources/KakaoSapiens/Models/AIModel.swift -o /tmp/measurement-tests && /tmp/measurement-tests
@main
struct OptimizationMeasurementStoreTests {
    @MainActor
    static func main() {
        runLifecycle()
        recordsOnlyWhileMeasuring()
        hitIsWhatServerReported()
        separatesWorkloads()
        cacheBucketsSkipAttempts()
        createReasonFollowsDrop()
        requestGapBuckets()
        digestStreakIgnoresFreeSkips()
        policyReadsLiveConstants()
        jsonShapeMatchesPhone()
        readsPhoneLedger()
        survivesReload()
        requestLogKeepsOrder()
        requestLogFallsBackToNow()
        requestLogCapsOldest()
        readsPhoneRequestLog()
        separatesModels()
        cacheCountsOnlyGemini()
        readsPhoneModelColumn()
        separatesDigestByModel()
        print("OptimizationMeasurementStoreTests: 모두 통과")
    }

    @MainActor
    static func store(at time: Double = 1_000) -> OptimizationMeasurementStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("measure-\(UUID().uuidString).json")
        return OptimizationMeasurementStore(fileURL: url, clock: { Date(timeIntervalSince1970: time) })
    }

    static func chat(room: String = "r", input: Int = 100, cached: Int = 0, output: Int = 10,
                     ttft: Int = 0, total: Int = 0, thoughts: Int = 0,
                     workload: MeasurementWorkload = .CHAT,
                     model: String? = "gemini-3.8-flash") -> RequestObservation {
        RequestObservation(roomKey: room, inputTokens: input, cachedInputTokens: cached, outputTokens: output,
                           estimatedPromptTokens: input, ttftMillis: ttft, totalMillis: total,
                           thoughtsTokens: thoughts, workload: workload, model: model)
    }

    @MainActor
    static func runLifecycle() {
        let s = store()
        precondition(s.start(), "처음 시작은 된다")
        precondition(!s.start(), "진행 중에는 또 시작하지 않는다")
        precondition(s.stop(), "진행 중이면 끝낸다")
        precondition(!s.stop(), "진행 중이 아니면 끝낼 것이 없다")
        s.start()
        precondition(s.ledger.activeRun?.id == 2, "회차 번호는 이어진다")
        s.clear()
        precondition(s.ledger.activeRun == nil && s.ledger.completedRuns.isEmpty, "삭제하면 다 지운다")
    }

    @MainActor
    static func recordsOnlyWhileMeasuring() {
        let s = store()
        s.observeRequest(chat())
        s.observeCache(.NOT_BURST, estimatedPrefixTokens: 5_000, model: "gemini-3.8-flash")
        s.observeDigest(.COMMITTED, coverageBefore: 0, coverageAfter: 50, model: "gemini-3.8-flash")
        precondition(s.ledger == MeasurementLedger(), "측정 중이 아니면 아무것도 안 적는다")
    }

    // 캐시를 붙였다는 사실이 아니라, 서버가 캐시에서 읽었다고 보고한 것으로 센다.
    @MainActor
    static func hitIsWhatServerReported() {
        let s = store()
        s.start()
        s.observeRequest(chat(cached: 0, ttft: 300, total: 900))
        s.observeRequest(chat(input: 30_000, cached: 25_000, ttft: 2_000, total: 1_000))
        let r = s.ledger.activeRun!.requests
        precondition(r.requestCount == 2)
        precondition(r.cacheHitRequests == 1, "캐시에서 읽은 요청만 적중")
        precondition(r.inputTokensMax == 30_000, "최댓값을 남긴다")
        precondition(r.ttftMillisMax == 2_000 && r.totalMillisTotal == 1_900, "시간 합계와 최댓값")
    }

    // 섞으면 채팅 지연과 요약의 사고 토큰이 한 통에 담긴다.
    @MainActor
    static func separatesWorkloads() {
        let s = store()
        s.start()
        s.observeRequest(chat(room: "a"))
        s.observeRequest(chat(room: "a", thoughts: 3_000, workload: .MEMORY))
        let run = s.ledger.activeRun!
        precondition(run.requests.requestCount == 2, "합계에는 둘 다")
        precondition(run.requestsByWorkload["CHAT"]?.requestCount == 1)
        precondition(run.requestsByWorkload["MEMORY"]?.thoughtsTokensMax == 3_000, "요약의 사고량을 따로 본다")
        precondition(run.roomRequestCounts["a"] == 2)
    }

    // 시도는 과정이라 크기 분포에서 뺀다(폰과 같음).
    @MainActor
    static func cacheBucketsSkipAttempts() {
        let s = store()
        s.start()
        s.observeCache(.BELOW_MINIMUM, estimatedPrefixTokens: 3_000, model: "gemini-3.8-flash")
        s.observeCache(.CREATE_ATTEMPT, estimatedPrefixTokens: 20_000, model: "gemini-3.8-flash")
        s.observeCache(.CREATE_SUCCESS, estimatedPrefixTokens: 20_000, actualCacheTokens: 18_000, model: "gemini-3.8-flash")
        s.observeCache(.NOT_BURST, estimatedPrefixTokens: 4_300, model: "gemini-3.8-flash")
        let c = s.ledger.activeRun!.cache
        precondition(c.decisionCounts == ["BELOW_MINIMUM": 1, "CREATE_ATTEMPT": 1, "CREATE_SUCCESS": 1, "NOT_BURST": 1])
        precondition(c.prefixTokenBuckets == [1, 1, 0, 0, 1], "시도는 분포에 안 넣는다: \(c.prefixTokenBuckets)")
        precondition(c.actualCacheTokens == 18_000)
    }

    // 버린 이유가 없으면 처음, 있으면 그 이유로 이어진다. 폰에서 이걸 뭉쳐 TTL 효과를 못 쟀다.
    @MainActor
    static func createReasonFollowsDrop() {
        precondition(CacheCreateReason.from(nil) == .FIRST)
        precondition(CacheCreateReason.from(.EXPIRED) == .EXPIRED)
        precondition(CacheCreateReason.from(.SHRUNK) == .SHRUNK)
        precondition(CacheCreateReason.from(.MODEL_CHANGED) == .MODEL_CHANGED)
        precondition(CacheCreateReason.from(.FINGERPRINT_CHANGED) == .FINGERPRINT_CHANGED)
        let s = store()
        s.start()
        s.observeCacheCreateReason(.EXPIRING_SOON, model: "gemini-3.8-flash")
        s.observeCacheCreateReason(.EXPIRING_SOON, model: "gemini-3.8-flash")
        precondition(s.ledger.activeRun!.cache.createReasons == ["EXPIRING_SOON": 2])
    }

    // 5분은 burst 기준, 30분은 TTL. 모르는 것은 "오래됨"이 아니다.
    @MainActor
    static func requestGapBuckets() {
        let s = store()
        s.start()
        let now = Date(timeIntervalSince1970: 100_000)
        for minutes in [1.0, 5.0, 7.0, 10.0, 20.0, 30.0, 90.0] {
            s.observeRequestGap(previous: now.addingTimeInterval(-minutes * 60), now: now)
        }
        s.observeRequestGap(previous: nil, now: now)
        s.observeRequestGap(previous: now.addingTimeInterval(60), now: now)
        let g = s.ledger.activeRun!.requestGaps
        precondition(g.withinFiveMinutes == 2, "1분·정확히 5분")
        precondition(g.fiveToTenMinutes == 2, "7분·정확히 10분")
        precondition(g.tenToThirtyMinutes == 2, "20분·정확히 30분")
        precondition(g.fifteenToThirtyMinutes == 2 && g.tenToFifteenMinutes == 0, "20분·30분은 15~30분 칸")
        // 맥의 TTL이 15분이라 15분 경계가 없으면 15분 대 30분을 판정할 수 없다.
        let t = store()
        t.start()
        for minutes in [12.0, 15.0, 16.0] {
            t.observeRequestGap(previous: now.addingTimeInterval(-minutes * 60), now: now)
        }
        let h = t.ledger.activeRun!.requestGaps
        precondition(h.tenToFifteenMinutes == 2, "12분·정확히 15분")
        precondition(h.fifteenToThirtyMinutes == 1, "16분")
        precondition(h.tenToThirtyMinutes == 3, "기존 칸은 두 칸의 합")
        precondition(g.overThirtyMinutes == 1, "90분")
        precondition(g.unknown == 2, "재시작 뒤 첫 요청과 거꾸로 간 시계")
    }

    // 무료 건너뜀을 실패로 세면, 실제로 돈을 쓴 실패가 몇 번 이어졌는지가 묻힌다.
    @MainActor
    static func digestStreakIgnoresFreeSkips() {
        let s = store()
        s.start()
        s.observeDigest(.NOT_STOP, coverageBefore: 280, coverageAfter: 280, failureDetail: "MAX_TOKENS", model: "gemini-3.8-flash")
        s.observeDigest(.BACKOFF_SKIPPED, coverageBefore: 0, coverageAfter: 0, model: "gemini-3.8-flash")
        s.observeDigest(.NOT_STOP, coverageBefore: 280, coverageAfter: 280, failureDetail: "MAX_TOKENS", model: "gemini-3.8-flash")
        var m = s.ledger.activeRun!.memory
        precondition(m.attempts == 3 && m.paidAttempts == 2, "건너뜀은 유료가 아니다")
        precondition(m.maxConsecutivePaidFailures == 2, "건너뜀이 끼어도 연속 실패는 이어진다")
        precondition(m.failureDetails == ["MAX_TOKENS": 2])
        s.observeDigest(.COMMITTED, coverageBefore: 280, coverageAfter: 330, model: "gemini-3.8-flash")
        s.observeDigest(.NOT_STOP, coverageBefore: 330, coverageAfter: 330, failureDetail: "MAX_TOKENS", model: "gemini-3.8-flash")
        m = s.ledger.activeRun!.memory
        precondition(m.committed == 1 && m.coverageAdvanced == 50 && m.lastCommittedCoverage == 330)
        precondition(m.maxConsecutivePaidFailures == 2, "성공하면 연속 실패가 다시 시작된다")
        precondition(m.outcomeCounts == ["NOT_STOP": 3, "BACKOFF_SKIPPED": 1, "COMMITTED": 1])
    }

    // 기록 구간에 실제로 돌고 있는 값을 담아야 구간끼리 견줄 수 있다.
    @MainActor
    static func policyReadsLiveConstants() {
        let p = MeasurementPolicy.current()
        precondition(p.minimumCacheTokens == GeminiCachePolicy.minimumCacheTokens)
        precondition(p.cacheTtlSeconds == GeminiCachePolicy.cacheTTLSeconds)
        precondition(p.burstWindowSeconds == Int(GeminiCachePolicy.burstWindowSeconds))
        precondition(p.refreshTailMinimumTokens == GeminiCachePolicy.refreshTailMinimumTokens)
        precondition(p.officialMinimumCacheTokens == 4_096)
    }

    // 폰과 같은 키로 적혀야 두 기록을 같은 방법으로 읽는다. 사전은 배열이 아니라 객체여야 한다.
    @MainActor
    static func jsonShapeMatchesPhone() {
        let s = store()
        s.start()
        s.observeRequest(chat())
        s.observeCache(.CACHE_CURRENT, estimatedPrefixTokens: 9_000, model: "gemini-3.8-flash")
        let data = try! Data(contentsOf: s.fileURL)
        let root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(root["schemaVersion"] as? Int == 1)
        precondition(root["platform"] as? String == "mac")
        let run = root["activeRun"] as! [String: Any]
        for key in ["id", "startedAtMillis", "policy", "requests", "cache", "requestsByWorkload",
                    "memory", "roomRequestCounts", "requestGaps", "requestLog", "requestLogDropped"] {
            precondition(run[key] != nil, "폰과 같은 키가 있어야 한다: \(key)")
        }
        precondition(run["endedAtMillis"] == nil, "진행 중인 회차에는 끝난 시각이 없다")
        let cache = run["cache"] as! [String: Any]
        precondition(cache["decisionCounts"] is [String: Any], "사전은 객체로 적는다")
        precondition((run["requestsByWorkload"] as? [String: Any])?["CHAT"] != nil, "작업 이름이 키")
        precondition(run["startedAtMillis"] as? Int == 1_000_000, "밀리초로 적는다")
    }

    // 실제 폰 장부의 모양을 줄인 표본이다. 맥이 읽을 수 있어야 한다.
    @MainActor
    static func readsPhoneLedger() {
        let phone = #"""
        {"schemaVersion":1,"activeRun":{"id":9,"startedAtMillis":1789047813583,
         "policy":{"minimumCacheTokens":4600,"officialMinimumCacheTokens":4096,"cacheTtlSeconds":1800,
                   "burstWindowSeconds":300,"refreshTailMinimumTokens":2000},
         "requests":{"requestCount":471,"inputTokens":13434561,"cachedInputTokens":11014185,
                     "outputTokens":165318,"cacheHitRequests":407,
                     "prompt":{"stableSystemTokens":10,"digestTokens":20,"digestEventTokens":15}},
         "cache":{"decisionCounts":{"NOT_BURST":42,"CACHE_CURRENT":24},"createReasons":{"SHRUNK":41},
                  "prefixTokenBuckets":[3,1,17,0,402],"actualCacheTokens":2100931},
         "requestsByWorkload":{"CHAT":{"requestCount":467},"MEMORY":{"requestCount":4,"thoughtsTokensMax":10262}},
         "memory":{"attempts":4,"committed":4,"outcomeCounts":{"COMMITTED":4},"lastCommittedCoverage":650,
                   "finishReasons":{"old":1}},
         "roomRequestCounts":{"e3d62961":450},
         "requestGaps":{"withinFiveMinutes":3}},
         "completedRuns":[{"id":1,"startedAtMillis":1,"endedAtMillis":2,"policy":{}}]}
        """#
        let ledger = try! JSONDecoder().decode(MeasurementLedger.self, from: Data(phone.utf8))
        let run = ledger.activeRun!
        precondition(ledger.platform == "mac", "폰 기록에는 없는 키라 기본값")
        precondition(run.policy.cacheTtlSeconds == 1_800)
        precondition(run.requests.requestCount == 471 && run.requests.cacheHitRequests == 407)
        precondition(run.requests.prompt.digestEventTokens == 15, "계층별 필드를 읽는다")
        precondition(run.cache.decisionCounts["CACHE_CURRENT"] == 24)
        precondition(run.requestsByWorkload["MEMORY"]?.thoughtsTokensMax == 10_262)
        precondition(run.memory.lastCommittedCoverage == 650)
        precondition(run.requestGaps.withinFiveMinutes == 3 && run.requestGaps.unknown == 0, "빠진 키는 0")
        precondition(ledger.completedRuns.first?.endedAtMillis == 2)
        precondition(ledger.completedRuns.first?.policy == MeasurementPolicy(), "빈 정책은 기본값")
    }

    // 앱을 다시 켜도 회차가 이어진다.
    @MainActor
    static func survivesReload() {
        let s = store()
        s.start()
        s.observeRequest(chat(room: "x"))
        s.stop()
        s.start()
        let reloaded = OptimizationMeasurementStore(fileURL: s.fileURL)
        precondition(reloaded.ledger == s.ledger, "파일에서 그대로 읽힌다")
        precondition(reloaded.ledger.completedRuns.first?.roomRequestCounts == ["x": 1])
        precondition(reloaded.isMeasuring)
    }

    // 간격을 구간으로만 세면 순서가 사라진다. 요청마다 시각과 토큰을 남겨 TTL을 다시 돌려 볼 수 있게 한다.
    @MainActor
    static func requestLogKeepsOrder() {
        let s = store()
        s.start()
        var first = chat(room: "a", input: 27_000, cached: 0)
        first.sentAt = Date(timeIntervalSince1970: 100)
        first.explicitCache = false
        var second = chat(room: "a", input: 27_500, cached: 24_000, output: 50)
        second.sentAt = Date(timeIntervalSince1970: 200)
        second.explicitCache = true
        s.observeRequest(first)
        s.observeRequest(second)
        let log = s.ledger.activeRun!.requestLog
        precondition(log.map(\.atMillis) == [100_000, 200_000], "보낸 시각을 밀리초로, 순서대로")
        precondition(log[1] == RequestLogEntry(atMillis: 200_000, roomKey: "a", workload: .CHAT, inputTokens: 27_500,
                                               cachedInputTokens: 24_000, outputTokens: 50, explicitCache: true,
                                               model: "gemini-3.8-flash"))
        let reloaded = OptimizationMeasurementStore(fileURL: s.fileURL)
        precondition(reloaded.ledger.activeRun?.requestLog == log, "다시 읽어도 그대로")
    }

    @MainActor
    static func requestLogFallsBackToNow() {
        let s = store(at: 5)
        s.start()
        var memory = chat(workload: .MEMORY)
        memory.unreported = true
        s.observeRequest(memory)
        let log = s.ledger.activeRun!.requestLog
        precondition(log.count == 1)
        let entry = log[0]
        precondition(entry.atMillis == 5_000, "보낸 시각을 모르면 기록 시각")
        precondition(entry.explicitCache == nil && entry.unreported && entry.workload == .MEMORY)
    }

    @MainActor
    static func requestLogCapsOldest() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString).json")
        let s = OptimizationMeasurementStore(fileURL: url, logLimit: 5, clock: { Date(timeIntervalSince1970: 1) })
        s.start()
        for i in 0..<8 {
            var o = chat()
            o.sentAt = Date(timeIntervalSince1970: Double(i))
            s.observeRequest(o)
        }
        let run = s.ledger.activeRun!
        precondition(run.requestLog.count == 5 && run.requestLog.first?.atMillis == 3_000, "오래된 줄부터 버린다")
        precondition(run.requestLogDropped == 3 && run.requests.requestCount == 8, "버린 수를 세고 합계는 유지")
    }

    // 폰이 쓴 요청 기록을 맥이 읽는다. 옛 파일(기록 없음)도 읽는다.
    @MainActor
    static func readsPhoneRequestLog() {
        let phone = #"{"activeRun":{"id":11,"startedAtMillis":1,"policy":{},"requestLog":[{"atMillis":42,"roomKey":"e3d6","workload":"MEMORY","inputTokens":9,"explicitCache":false},{"atMillis":43,"roomKey":"e3d6"}],"requestLogDropped":2}}"#
        let run = try! JSONDecoder().decode(MeasurementLedger.self, from: Data(phone.utf8)).activeRun!
        precondition(run.requestLog.count == 2 && run.requestLogDropped == 2)
        precondition(run.requestLog[0].workload == .MEMORY && run.requestLog[0].explicitCache == false)
        precondition(run.requestLog[1].workload == .CHAT && run.requestLog[1].explicitCache == nil, "빠진 칸은 기본값")
        let old = #"{"activeRun":{"id":1,"startedAtMillis":1,"policy":{}}}"#
        let oldRun = try! JSONDecoder().decode(MeasurementLedger.self, from: Data(old.utf8)).activeRun!
        precondition(oldRun.requestLog.isEmpty && oldRun.requestLogDropped == 0)
    }

    // Gemini와 DeepSeek를 한 회차에서 함께 잰다. 모델별 합계가 따로 쌓여야 한다.
    @MainActor
    static func separatesModels() {
        let s = store()
        s.start()
        s.observeRequest(chat(input: 27_000, cached: 24_000))
        s.observeRequest(chat(input: 20_000, cached: 19_000, model: "deepseek-flash"))
        s.observeRequest(chat(input: 1, model: nil))
        let run = s.ledger.activeRun!
        precondition(run.requestLog.map(\.model) == ["gemini-3.8-flash", "deepseek-flash", nil])
        precondition(run.byModel["gemini-3.8-flash"]?.requests.cachedInputTokens == 24_000)
        precondition(run.byModel["deepseek-flash"]?.requests.requestCount == 1)
        precondition(run.byModel["deepseek-flash"]?.requestsByWorkload["CHAT"]?.requestCount == 1)
        precondition(run.byModel.count == 2, "모르는 모델은 모델별 합계에 넣지 않는다")
        precondition(run.requests.requestCount == 2, "기존 합계는 Gemini와 모름만 센다")
        precondition(run.requestsByWorkload["CHAT"]?.requestCount == 2 && run.roomRequestCounts == ["r": 2])
        let text = String(decoding: try! Data(contentsOf: s.fileURL), as: UTF8.self)
        precondition(text.contains("\"byModel\""), "폰과 같은 키")
        let reloaded = OptimizationMeasurementStore(fileURL: s.fileURL)
        precondition(reloaded.ledger == s.ledger, "다시 읽어도 그대로")
    }

    // 캐시 판정·생성 이유는 Gemini 규칙의 효과를 재는 숫자다. 다른 모델은 세지 않는다.
    @MainActor
    static func cacheCountsOnlyGemini() {
        let s = store()
        s.start()
        s.observeCache(.CREATE_SUCCESS, estimatedPrefixTokens: 20_000, actualCacheTokens: 18_000, model: "deepseek-flash")
        s.observeCacheCreateReason(.FIRST, model: "deepseek-flash")
        s.observeCache(.CACHE_CURRENT, estimatedPrefixTokens: 9_000, model: "gemini-3.7-flash")
        let c = s.ledger.activeRun!.cache
        precondition(c.decisionCounts == ["CACHE_CURRENT": 1])
        precondition(c.createReasons.isEmpty && c.actualCacheTokens == 0)
        precondition(!isGeminiModelId(nil) && !isGeminiModelId("gpt-5.6-luna"))
    }

    // 폰이 모델 칸을 채워 쓴 기록을 맥이 읽는다. 칸이 없는 옛 줄은 모름(nil)이다.
    @MainActor
    static func readsPhoneModelColumn() {
        let phone = #"{"activeRun":{"id":10,"startedAtMillis":1,"policy":{},"byModel":{"deepseek-flash":{"requests":{"requestCount":2},"memory":{"attempts":3,"outcomeCounts":{"PARSE_FAILED":1}}}},"requestLog":[{"atMillis":1,"roomKey":"a"},{"atMillis":2,"roomKey":"a","model":"deepseek-flash"}]}}"#
        let run = try! JSONDecoder().decode(MeasurementLedger.self, from: Data(phone.utf8)).activeRun!
        precondition(run.requestLog.map(\.model) == [nil, "deepseek-flash"])
        precondition(run.byModel["deepseek-flash"]?.requests.requestCount == 2)
        precondition(run.byModel["deepseek-flash"]?.memory.outcomeCounts["PARSE_FAILED"] == 1, "폰 기억 갈래 이름도 읽는다")
    }

    // 요약 결과도 모델별로 쌓고, 기존 합계는 Gemini만 센다. 연속 실패도 장부마다 센다(폰과 같음).
    @MainActor
    static func separatesDigestByModel() {
        let s = store()
        s.start()
        s.observeDigest(.NOT_STOP, coverageBefore: 100, coverageAfter: 100, failureDetail: "MAX_TOKENS", model: "gemini-3.8-flash")
        s.observeDigest(.COMMITTED, coverageBefore: 100, coverageAfter: 150, model: "deepseek-flash")
        s.observeDigest(.NOT_STOP, coverageBefore: 100, coverageAfter: 100, failureDetail: "MAX_TOKENS", model: "gemini-3.8-flash")
        let run = s.ledger.activeRun!
        precondition(run.memory.attempts == 2 && run.memory.committed == 0)
        precondition(run.memory.maxConsecutivePaidFailures == 2, "다른 모델 성공이 Gemini 연쇄를 끊지 않는다")
        precondition(run.byModel["gemini-3.8-flash"]?.memory == run.memory)
        let ds = run.byModel["deepseek-flash"]!.memory
        precondition(ds.attempts == 1 && ds.committed == 1 && ds.lastCommittedCoverage == 150)
        let reloaded = OptimizationMeasurementStore(fileURL: s.fileURL)
        precondition(reloaded.ledger == s.ledger, "다시 읽어도 그대로")
    }
}
