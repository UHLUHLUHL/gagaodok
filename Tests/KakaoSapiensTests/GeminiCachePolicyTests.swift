import Foundation

/// 폰과 맞춘 캐시·요약·요금 규칙을 확인합니다.
///
/// 실행:
///   swiftc -parse-as-library Tests/KakaoSapiensTests/GeminiCachePolicyTests.swift \
///     Sources/KakaoSapiens/Services/GeminiCachePolicy.swift \
///     Sources/KakaoSapiens/Services/TokenUsageManager.swift \
///     Sources/KakaoSapiens/Models/AIModel.swift -o /tmp/cache-policy-tests && /tmp/cache-policy-tests
@main
struct GeminiCachePolicyTests {
    static func main() {
        minimumFollowsOfficialFloor()
        legacyCacheFileReadsAsGemini37()
        newCacheFieldsRoundTrip()
        leaseCountsOnlyLivedTime()
        leaseNeverPassesExpiry()
        leaseSkipsUnknowns()
        digestThinkingIsLowered()
        digestBudgetLeavesRoomForThinking()
        digestRetryBacksOff()
        cacheCreationIsNotBilled()
        exchangeRateMatchesBill()
        print("GeminiCachePolicyTests: 모두 통과")
    }

    // 공식 최소치는 3.8·3.7 모두 4,096이다. 예전 1,200은 옛 모델 기준이었다.
    static func minimumFollowsOfficialFloor() {
        precondition(GeminiCachePolicy.minimumCacheTokens >= 4096, "공식 최소치보다 작으면 서버가 거부할 요청을 보낸다")
        precondition(GeminiCachePolicy.minimumCacheTokens == 4600, "폰과 같은 값이어야 한다")
    }

    // 옛 파일에는 모델과 생성 시각이 없다. 옛 캐시는 전부 3.7로 만들어졌으므로 3.7로 읽고,
    // 생성 시각은 모르므로 비워 둔다 — 지어내지 않는다.
    static func legacyCacheFileReadsAsGemini37() {
        let json = #"{"name":"cachedContents/x","coveredTurns":12,"fingerprint":"f","expiresAt":800000000,"tokenCount":27000}"#
        let cache = try! JSONDecoder().decode(GeminiPrefixCache.self, from: Data(json.utf8))
        precondition(cache.modelIdentifier == AIModel.gemini37Flash.rawValue, "옛 캐시는 3.7로 읽어야 한다")
        precondition(cache.createdAt == nil, "옛 캐시의 생성 시각은 모른다")
        precondition(cache.leaseTokenHoursAtExpiry == 0, "생성 시각을 모르면 보관량을 적지 않는다")
    }

    static func newCacheFieldsRoundTrip() {
        let created = Date(timeIntervalSinceReferenceDate: 1_000)
        let cache = GeminiPrefixCache(
            name: "cachedContents/y", coveredTurns: 5, fingerprint: "g",
            expiresAt: created.addingTimeInterval(900), tokenCount: 5_000,
            modelIdentifier: AIModel.gemini38Flash.rawValue, createdAt: created
        )
        let data = try! JSONEncoder().encode(cache)
        let back = try! JSONDecoder().decode(GeminiPrefixCache.self, from: data)
        precondition(back.modelIdentifier == AIModel.gemini38Flash.rawValue, "모델이 저장되어야 캐시가 모델에 묶인다")
        precondition(back.createdAt == created, "생성 시각이 저장되어야 산 시간을 셀 수 있다")
    }

    // 30분 산 27,000토큰 캐시 = 13,500 토큰·시간.
    static func leaseCountsOnlyLivedTime() {
        let created = Date(timeIntervalSinceReferenceDate: 0)
        let hours = GeminiCachePolicy.leaseTokenHours(
            tokenCount: 27_000, createdAt: created, until: created.addingTimeInterval(1_800))
        precondition(abs(hours - 13_500) < 1e-9, "산 시간만큼 적어야 한다: \(hours)")
    }

    // 앱이 꺼진 사이 만료된 캐시를 다음 날 버려도, 만료 시각까지만 센다.
    static func leaseNeverPassesExpiry() {
        let created = Date(timeIntervalSinceReferenceDate: 0)
        let cache = GeminiPrefixCache(
            name: "c", coveredTurns: 1, fingerprint: "f",
            expiresAt: created.addingTimeInterval(900), tokenCount: 27_000, createdAt: created
        )
        let nextDay = created.addingTimeInterval(24 * 3600)
        precondition(abs(cache.leaseTokenHours(until: nextDay) - 6_750) < 1e-9, "만료 뒤 시간은 세지 않는다")
        precondition(abs(cache.leaseTokenHoursAtExpiry - 6_750) < 1e-9, "만료 시각까지가 전부다")
    }

    static func leaseSkipsUnknowns() {
        let t = Date(timeIntervalSinceReferenceDate: 100)
        precondition(GeminiCachePolicy.leaseTokenHours(tokenCount: 0, createdAt: t, until: t.addingTimeInterval(60)) == 0,
                     "크기를 모르면 적지 않는다")
        precondition(GeminiCachePolicy.leaseTokenHours(tokenCount: 27_000, createdAt: t, until: t.addingTimeInterval(-60)) == 0,
                     "시계가 거꾸로 가도 음수를 적지 않는다")
    }

    // high에서는 사고가 예산의 96%를 먹어 요약이 잘려 버려졌다(폰 실측, 같은 3.7).
    static func digestThinkingIsLowered() {
        precondition(GeminiCachePolicy.digestThinkingLevel == "low", "요약 사고 수준은 폰과 같이 low")
    }

    // 예전 맥은 본문 2,700만 줬다. 사고 몫을 따로 얹어야 본문 자리가 남는다.
    static func digestBudgetLeavesRoomForThinking() {
        let budget = GeminiCachePolicy.outputBudget(bodyTokens: 2_700)
        precondition(budget == 2_700 + 8_192, "본문에 사고 몫을 더한다: \(budget)")
        precondition(GeminiCachePolicy.outputBudget(bodyTokens: 100_000) == 65_536, "모델 한도를 넘지 않는다")
    }

    // 실패하면 다음 메시지에서 바로 다시 하지 않는다. 15분부터 두 배씩, 6시간에서 멈춘다.
    static func digestRetryBacksOff() {
        let d = GeminiCachePolicy.digestRetryDelay
        precondition(d(1) == 15 * 60, "첫 실패 뒤 15분")
        precondition(d(2) == 30 * 60, "두 번째 30분")
        precondition(d(3) == 60 * 60, "세 번째 1시간")
        precondition(d(6) == 6 * 3600, "여섯 번째에서 상한")
        precondition(d(50) == 6 * 3600, "더 늘지 않는다")
        precondition(d(0) == 15 * 60, "이상한 입력도 최소값")
    }

    // 실제 청구서에 캐시 생성 항목이 없었다. 개수는 세되 요금에는 안 넣는다.
    static func cacheCreationIsNotBilled() {
        let withCreation = ModelTokenUsage(inputTokens: 1_000, cacheCreateTokens: 50_000, outputTokens: 100)
        let without = ModelTokenUsage(inputTokens: 1_000, outputTokens: 100)
        precondition(withCreation.costUSD(for: .gemini38Flash) == without.costUSD(for: .gemini38Flash),
                     "캐시에 올린 토큰은 요금에 들어가지 않는다")
        precondition(withCreation.adding(withCreation).cacheCreateTokens == 100_000, "개수는 계속 센다")
    }

    // 청구서 세 항목을 역산하면 모두 1,383이다.
    static func exchangeRateMatchesBill() {
        precondition(defaultUsageExchangeRate == 1383, "환율 기본값은 청구서 역산값")
        let usd = RoomTokenUsage(promptTokens: 1_000_000).costUSD()
        precondition(abs(RoomTokenUsage(promptTokens: 1_000_000).costKRW() - usd * 1383) < 1e-9,
                     "기본 환율이 적용되어야 한다")
    }
}
