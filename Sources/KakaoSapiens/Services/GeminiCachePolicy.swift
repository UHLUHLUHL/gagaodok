import Foundation

/// 캐시와 구간 요약의 판단 규칙 가운데 네트워크·저장소와 무관한 부분입니다.
///
/// 따로 떼어 둔 이유는 검사입니다. `GeminiService`는 액터라 이 규칙들만 골라
/// 확인하기 어렵습니다. 여기 있는 것은 입력만으로 답이 정해집니다.
///
/// 폰(`android/.../AIServicePrefixCache.kt`, `AIServiceTransport.kt`)과 같은 값을
/// 씁니다. 두 앱이 같은 청구서를 받으므로 규칙이 갈릴 이유가 없습니다.
enum GeminiCachePolicy {
    /// 명시적 캐시를 만들 최소 크기입니다(로컬 추정 기준).
    ///
    /// **공식 최소치는 4,096토큰입니다.** Gemini 3.8·3.7 Flash 모두 그렇습니다
    /// (https://ai.google.dev/gemini-api/docs/generate-content/caching).
    /// 예전 값 1,200은 1,024토큰이 최소이던 옛 모델 기준이 남은 것이었습니다.
    /// 폰은 2026-08-21에 올렸고 맥은 그때 따라가지 않았습니다.
    ///
    /// 그 사이 크기의 방은 서버가 거부할 요청을 보내고 있었습니다. 대화에는 영향이
    /// 없지만, 대화가 이어지는 동안 요청마다 다시 시도했습니다.
    ///
    /// 약 12% 여유는 로컬 추정이 실제보다 크게 나오는 몫입니다. 폰 실측에서 추정기가
    /// 20~28% 크게 센 적도 있어 경계에서는 거부될 수 있습니다. 다만 낮게 틀리면
    /// 헛요청이고 높게 틀리면 캐시를 받을 방이 정가를 내므로, 낮은 쪽이 쌉니다.
    static let minimumCacheTokens = 4600

    /// 명시적 캐시의 수명(초)입니다. 폰은 1,800입니다 — 맥은 아직 옮기지 않았습니다.
    static let cacheTTLSeconds = 900

    /// 캐시가 덮은 뒤로 이만큼 새로 붙어야 다시 만듭니다(캐시 크기의 1/5과 비교해 큰 쪽).
    /// **정한 값입니다.**
    static let refreshTailMinimumTokens = 2000

    /// 수명이 이만큼도 안 남았으면 꼬리가 짧아도 새로 만듭니다.
    static let refreshTTLFloorSeconds: TimeInterval = 240

    /// 직전 요청이 이 안에 있었으면 "대화 중"으로 보고, 그때만 첫 캐시를 만듭니다.
    /// **정한 값입니다.** 실제 사용 기록을 보고 뽑은 값이 아닙니다.
    static let burstWindowSeconds: TimeInterval = 300

    /// 한 캐시가 산 동안의 보관량(토큰·시간)입니다.
    ///
    /// **모르면 0입니다.** 만든 시각이 없는 옛 기록이나 크기를 못 받은 캐시는
    /// 지어내지 않습니다. 시계가 뒤로 가서 음수가 나와도 0입니다 — 더하면 장부가 준다.
    ///
    /// 예전에는 만들 때 TTL 전체를 미리 적었습니다. 교체로 일찍 끝난 캐시는 과대,
    /// 반대로 앱이 꺼진 사이 만료된 캐시는 이 방식으로도 맞았지만 폰과 규칙이 달랐습니다.
    /// 이제 끝날 때 실제로 산 만큼만 적습니다.
    static func leaseTokenHours(tokenCount: Int, createdAt: Date?, until end: Date) -> Double {
        guard tokenCount > 0, let createdAt else { return 0 }
        let hours = max(0, end.timeIntervalSince(createdAt)) / 3600
        return Double(tokenCount) * hours
    }

    // MARK: - 재생성 보호

    /// 캐시가 덮는 범위를 대화 끝에서 이만큼 뒤로 물립니다. 사용자 한 마디와 답 한 번입니다.
    ///
    /// **캐시가 대화 전체를 덮으면 답을 다시 받을 때마다 캐시가 깨집니다.** 메시지를
    /// 고쳐 보내면 그 뒤가 잘려 대화가 캐시보다 짧아지고, 캐시를 통째로 버립니다
    /// (`SHRUNK`). 그 요청은 전체를 정가로 냅니다. 마지막 교환을 캐시 밖에 두면 그
    /// 교환을 몇 번 다시 받아도 앞부분은 그대로입니다.
    ///
    /// 대신 그 두 칸은 매 요청 정가로 나가므로 공짜가 아닙니다. 그래서 한 번이라도
    /// 캐시가 재요청으로 깨진 방에서만 켭니다. 폰(`CACHE_LAG_ENTRIES`)에서 켠 뒤
    /// 44요청 동안 재요청 탓 `SHRUNK`이 0건이었습니다.
    static let cacheLagEntries = 2

    /// 요약 진행 여부를 모르는 옛 캐시에만 쓰는 크기 기준입니다.
    static let rerollShrinkMaxEntries = 4

    /// 이 줄어듦이 "답을 다시 받은 것"인가.
    ///
    /// **길이가 그대로인 것이 오히려 재요청의 표시입니다.** 캐시는 답변이 저장되기
    /// **전**의 요청으로 만들어지므로 `coveredTurns`는 "사용자 메시지까지"의 길이입니다.
    ///
    ///     캐시 생성 63 → 답변 저장 64 → 답을 다시 받음 63
    ///
    /// 재요청은 길이를 줄이는 게 아니라 되돌립니다. 폰에서 처음에 "1 이상 줄어야
    /// 재요청"이라고 적었다가 실사용의 재요청을 전부 놓쳤습니다(`a1a9c6e`).
    ///
    /// 요약이 전진했으면 원문이 접힌 것이라 재요청이 아닙니다. 크기로 추측하지 않고
    /// 부르는 쪽이 요약 범위를 알려 줍니다 — 기준 시점이 다른 두 수를 빼면 우연히
    /// 비슷해질 때 틀립니다(폰 `7a0f9bb`).
    static func isRerollShrink(
        cacheDigestCoveredTurns: Int,
        requestDigestCoveredTurns: Int,
        coveredTurns: Int,
        newSize: Int
    ) -> Bool {
        if coveredTurns - newSize < 0 { return false }
        if cacheDigestCoveredTurns >= 0 {
            return requestDigestCoveredTurns == cacheDigestCoveredTurns
        }
        return coveredTurns - newSize <= rerollShrinkMaxEntries
    }

    /// 이 방에서 캐시를 몇 칸 물릴지 정합니다. 물리면 손해인 세 경우를 거릅니다.
    static func lagEntries(entryCount: Int, laggedPrefixTokens: Int, shrinkProne: Bool) -> Int {
        // 재요청으로 깨진 적이 없는 방입니다. 물리면 꼬리 값만 더 냅니다.
        guard shrinkProne else { return 0 }
        // 물리고 나면 접두사가 남지 않습니다.
        guard entryCount > cacheLagEntries else { return 0 }
        // 물리다가 최소치 아래로 내려가면 캐시가 **아예 안 만들어집니다.**
        guard laggedPrefixTokens >= minimumCacheTokens else { return 0 }
        return cacheLagEntries
    }

    /// 재요청으로 캐시가 깨진 적이 있는 방·모델 목록을 읽습니다. 못 읽으면 빈 목록입니다 —
    /// 캐시를 아끼려는 표시일 뿐이라, 없으면 예전처럼 동작하면 됩니다.
    static func readShrinkProneRooms(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(keys)
    }

    /// 목록을 적습니다. **디스크에 남깁니다** — 폰에서 메모리에만 두었더니 앱을 켤 때마다
    /// 사라져서, 물림이 실사용에서 한 번도 켜지지 않았습니다(`79f0b8c`).
    @discardableResult
    static func writeShrinkProneRooms(_ keys: Set<String>, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(keys.sorted()) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func shrinkProneKey(roomId: UUID, model: AIModel) -> String {
        "\(roomId.uuidString.lowercased())|\(model.rawValue)"
    }

    // MARK: - 구간 요약

    /// 구간 요약의 사고 수준입니다.
    ///
    /// **`high`에서는 사고가 예산을 거의 다 먹었습니다.** 폰 실측(같은 3.7)에서 3,500을
    /// 주면 3,362(96.1%), 10,692를 주면 10,262(96.0%)를 썼습니다. 주는 만큼 먹으므로
    /// 예산을 늘려도 본문 자리는 그대로였고, 요약이 문장 중간에서 잘려 버려졌습니다.
    /// 폰의 성공률이 8.3%였던 원인이고, 낮춘 뒤 4회 연속 성공했습니다.
    ///
    /// 맥은 같은 3.7·같은 `high`에 예산이 더 작았습니다(2,700). 원문을 규칙대로
    /// 정리하는 일이라, 오래 생각하고 안 나오는 결과보다 만들어져 저장되는 결과가 낫습니다.
    static let digestThinkingLevel = "low"

    /// 사고 몫으로 따로 남겨 두는 출력 예산입니다. `maxOutputTokens`는 사고와 본문이
    /// 함께 쓰는 값이라, 본문만큼만 주면 사고가 먼저 채웁니다.
    static let thinkingHeadroom = 8192

    /// 모델의 한 응답 출력 한도입니다. 채팅 답변 길이로 정한 값과는 다릅니다.
    static let modelMaxOutputTokens = 65_536

    static func outputBudget(bodyTokens: Int) -> Int {
        min(bodyTokens + thinkingHeadroom, modelMaxOutputTokens)
    }

    /// 요약이 연속으로 실패한 뒤 다음 시도까지 기다릴 시간입니다.
    ///
    /// **예전에는 기다리지 않았습니다.** 실패하면 "다음 요청에서 다시 시도"했으므로,
    /// 요약이 계속 실패하는 방은 기준을 넘은 뒤 **보내는 메시지마다 유료 요약을 하나씩
    /// 만들고 버렸습니다.** 맥 방 하나가 280턴에서 요약이 멈춘 채 364턴까지 갔습니다.
    ///
    /// 15분에서 시작해 실패마다 두 배, 6시간에서 멈춥니다(폰과 같음).
    static func digestRetryDelay(consecutiveFailures: Int) -> TimeInterval {
        let steps = min(max(consecutiveFailures - 1, 0), 5)
        let delay = 15 * 60 * pow(2, Double(steps))
        return min(delay, 6 * 3600)
    }
}

/// 명시적 캐시 한 건의 기록입니다. `prefix_caches.json`에 저장됩니다.
///
/// `GeminiService.PrefixCache`는 이 타입의 별칭입니다. 서비스 밖으로 뺀 이유는
/// 옛 파일을 읽는 규칙을 따로 검사하기 위해서입니다.
struct GeminiPrefixCache: Codable {
    let name: String          // cachedContents/xxxx
    let coveredTurns: Int     // 이 캐시가 덮는 contents 앞부분의 개수
    let fingerprint: String   // 덮은 구간이 편집되지 않았는지 확인하는 지문
    let expiresAt: Date
    /// 이 캐시에 올라가 있는 토큰 수입니다. 다시 만들 값어치가 있는지 따질 때 씁니다.
    /// 예전 파일에는 없던 값이라 기본값을 둡니다.
    var tokenCount: Int = 0
    /// 이 캐시를 만든 모델입니다.
    ///
    /// **캐시는 모델에 묶입니다.** 3.7로 만든 캐시를 3.8 요청에 붙이면 서버가
    /// 거절합니다. 예전에는 대화가 모델 선택과 무관하게 3.7로만 나가서 드러나지
    /// 않았습니다. 옛 파일의 캐시는 전부 3.7로 만들어졌으므로 없으면 3.7로 읽습니다.
    var modelIdentifier: String = AIModel.gemini37Flash.rawValue
    /// 만든 시각입니다. 실제로 산 시간만큼 보관량을 적는 데 씁니다.
    /// 옛 파일에는 없으므로 비어 있으면 정산을 건너뜁니다.
    var createdAt: Date?
    /// 만들 때 대화 끝에서 몇 칸을 일부러 캐시 밖에 뒀는지입니다.
    /// `coveredTurns + lagEntries`가 만들 당시의 대화 길이입니다. 옛 파일에는 없으므로 0입니다.
    var lagEntries: Int = 0
    /// 만들 당시 요약이 몇 턴까지 덮고 있었는지입니다. 모르면 -1입니다.
    var digestCoveredTurns: Int = -1

    enum CodingKeys: String, CodingKey {
        case name, coveredTurns, fingerprint, expiresAt, tokenCount, modelIdentifier, createdAt
        case lagEntries, digestCoveredTurns
    }

    init(
        name: String,
        coveredTurns: Int,
        fingerprint: String,
        expiresAt: Date,
        tokenCount: Int = 0,
        modelIdentifier: String = AIModel.gemini37Flash.rawValue,
        createdAt: Date? = nil,
        lagEntries: Int = 0,
        digestCoveredTurns: Int = -1
    ) {
        self.name = name
        self.coveredTurns = coveredTurns
        self.fingerprint = fingerprint
        self.expiresAt = expiresAt
        self.tokenCount = tokenCount
        self.modelIdentifier = modelIdentifier
        self.createdAt = createdAt
        self.lagEntries = lagEntries
        self.digestCoveredTurns = digestCoveredTurns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        coveredTurns = try container.decode(Int.self, forKey: .coveredTurns)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        tokenCount = try container.decodeIfPresent(Int.self, forKey: .tokenCount) ?? 0
        modelIdentifier = try container.decodeIfPresent(String.self, forKey: .modelIdentifier)
            ?? AIModel.gemini37Flash.rawValue
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        lagEntries = try container.decodeIfPresent(Int.self, forKey: .lagEntries) ?? 0
        digestCoveredTurns = try container.decodeIfPresent(Int.self, forKey: .digestCoveredTurns) ?? -1
    }

    var leaseTokenHoursAtExpiry: Double {
        GeminiCachePolicy.leaseTokenHours(tokenCount: tokenCount, createdAt: createdAt, until: expiresAt)
    }

    func leaseTokenHours(until end: Date) -> Double {
        GeminiCachePolicy.leaseTokenHours(tokenCount: tokenCount, createdAt: createdAt, until: min(end, expiresAt))
    }
}
