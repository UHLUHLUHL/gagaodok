import Foundation
import CryptoKit

/// 명시적 캐시(`cachedContents`)를 만들고 쓰고 버리는 규칙입니다.
///
/// 언제 만들고 언제 안 만드는지가 요금의 대부분을 정합니다.
extension GeminiService {
    // Gemini의 implicit 캐시는 "완전히 똑같은 요청"이 짧은 간격으로 반복될 때만 걸립니다.
    // 채팅처럼 턴이 계속 붙는 패턴에서는 접두사가 같아도 적중하지 않아 실측 적중률이 0%였습니다.
    // 그래서 대화 접두사를 명시적 캐시(cachedContents)로 올려두고 새 턴만 보냅니다. 실측 99.7%.
    struct PrefixCache: Codable {
        let name: String          // cachedContents/xxxx
        let coveredTurns: Int     // 이 캐시가 덮는 contents 앞부분의 개수
        let fingerprint: String   // 덮은 구간이 편집되지 않았는지 확인하는 지문
        let expiresAt: Date
        /// 이 캐시에 올라가 있는 토큰 수입니다. 다시 만들 값어치가 있는지 따질 때 씁니다.
        /// 예전 파일에는 없던 값이라 기본값을 둡니다.
        var tokenCount: Int = 0

        enum CodingKeys: String, CodingKey {
            case name, coveredTurns, fingerprint, expiresAt, tokenCount
        }

        init(name: String, coveredTurns: Int, fingerprint: String, expiresAt: Date, tokenCount: Int = 0) {
            self.name = name
            self.coveredTurns = coveredTurns
            self.fingerprint = fingerprint
            self.expiresAt = expiresAt
            self.tokenCount = tokenCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            coveredTurns = try container.decode(Int.self, forKey: .coveredTurns)
            fingerprint = try container.decode(String.self, forKey: .fingerprint)
            expiresAt = try container.decode(Date.self, forKey: .expiresAt)
            tokenCount = try container.decodeIfPresent(Int.self, forKey: .tokenCount) ?? 0
        }
    }

    // 캐시 이름을 메모리에만 두면 앱을 껐다 켤 때마다 서버에 살아 있는 캐시를 버리고
    // 첫 요청을 전액으로 냅니다. TTL이 남아 있으면 이어서 쓰도록 디스크에 적어 둡니다.
    static let prefixCacheStoreURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KakaoSapiens", isDirectory: true)
        return base.appendingPathComponent("prefix_caches.json")
    }()

    static func loadPrefixCaches() -> [UUID: PrefixCache] {
        guard let data = try? Data(contentsOf: prefixCacheStoreURL),
              let stored = try? JSONDecoder().decode([String: PrefixCache].self, from: data) else { return [:] }
        var result: [UUID: PrefixCache] = [:]
        for (key, cache) in stored {
            // 이미 만료된 것은 되살리지 않습니다. 서버에도 없습니다.
            guard let id = UUID(uuidString: key), cache.expiresAt > Date() else { continue }
            result[id] = cache
        }
        return result
    }

    func persistPrefixCaches() {
        let snapshot = prefixCaches.reduce(into: [String: PrefixCache]()) { $0[$1.key.uuidString] = $1.value }
        let url = Self.prefixCacheStoreURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
    /// 직전 요청 시각을 꺼내면서 지금 시각으로 갱신합니다.
    ///
    /// **읽기 전에** 꺼내야 직전 값이 나옵니다. 읽고 나서 갱신하면 항상 자기 자신을
    /// 보게 되어 "대화 중인지" 판단이 무의미해집니다.
    func markRequest(_ roomId: UUID) -> Date? {
        let previous = lastRequestAt[roomId]
        lastRequestAt[roomId] = Date()
        return previous
    }

    static let cacheTTLSeconds = 900
    // 명시적 캐시는 1,024토큰 미만이면 생성이 거부됩니다. 어림값이 실제보다 조금 클 수 있으므로
    // 여유를 둡니다. 그래도 거부되면 캐시 없이 그냥 진행하므로 대화에는 영향이 없습니다.
    static let minimumCacheTokens = 1200

    // 캐시를 다시 만들 기준입니다. 자세한 셈은 `refreshPrefixCache`에 적었습니다.
    // 짧은 대화에서 몇 마디 붙었다고 다시 만들지 않게 하는 바닥값입니다. **정한 값입니다.**
    static let cacheRefreshMinTailTokens = 2000

    // TTL이 이만큼도 안 남았으면 꼬리가 짧아도 새로 만듭니다. 그대로 두면
    // 곧 만료되어 다음 요청이 통째로 전액이 됩니다.
    static let cacheRefreshTTLFloor: TimeInterval = 240

    // 직전 요청이 이 안에 있었으면 "대화 중"으로 봅니다. 그때만 첫 캐시를 만듭니다.
    // **정한 값입니다.** 실제 사용 기록을 보고 뽑은 값이 아닙니다.
    static let cacheBurstWindow: TimeInterval = 300

    func usablePrefixCache(
        for roomId: UUID,
        contents: [[String: Any]],
        system: String,
        apiKey: String
    ) -> PrefixCache? {
        guard let cache = prefixCaches[roomId] else { return nil }

        // 만료된 것은 서버에도 없으므로 지울 것이 없습니다.
        guard cache.expiresAt > Date().addingTimeInterval(30) else {
            dropCache(for: roomId, deleteRemote: false, apiKey: apiKey)
            return nil
        }

        // 캐시가 덮는 만큼의 턴이 남아 있고, 그 구간이 편집되지 않았을 때만 재사용합니다.
        //
        // **여기서 그냥 `nil`만 돌려주면 안 됩니다.** 예전에는 그랬는데, 메시지를
        // 하나 고치거나 지워서 대화가 짧아지면 이 조건에 걸려 캐시를 안 쓰고,
        // 갱신하는 쪽은 "이미 더 많이 덮는 캐시가 있다"며 그냥 돌아갔습니다.
        // 그래서 그 방은 대화가 예전 길이를 되찾을 때까지 캐시 없이 전액을 내면서,
        // 쓰지도 않는 캐시의 **보관료는 계속 냈습니다.** 지금은 버리고 다시 만듭니다.
        guard contents.count > cache.coveredTurns else {
            dropCache(for: roomId, deleteRemote: true, apiKey: apiKey)
            return nil
        }
        guard fingerprint(Array(contents.prefix(cache.coveredTurns)), system: system) == cache.fingerprint else {
            dropCache(for: roomId, deleteRemote: true, apiKey: apiKey)
            return nil
        }
        return cache
    }

    /// 로컬 기록에서 지우고, 서버에 남아 있을 것이면 그것도 지웁니다.
    ///
    /// 서버 쪽을 안 지우면 아무도 안 쓰는 캐시가 TTL이 다할 때까지 보관료를 먹습니다.
    func dropCache(for roomId: UUID, deleteRemote: Bool, apiKey: String) {
        guard let removed = prefixCaches[roomId] else { return }
        prefixCaches[roomId] = nil
        if deleteRemote {
            Task { await self.deleteCache(named: removed.name, apiKey: apiKey) }
        }
    }

    func refreshPrefixCache(
        roomId: UUID,
        contents: [[String: Any]],
        system: String,
        apiKey: String,
        previousRequestAt: Date?
    ) async {
        // 갱신 도중에는 URL 요청에서 액터가 풀리므로, 막지 않으면 같은 방에 대해
        // 갱신이 겹치면서 캐시가 여러 개 만들어지고 이전 것이 지워지지 않습니다.
        guard !refreshingRooms.contains(roomId) else { return }
        refreshingRooms.insert(roomId)
        defer { refreshingRooms.remove(roomId) }

        let now = Date()

        // 사진도 함께 셉니다. 글자만 세던 시절에는 사진이 0자로 잡혀서,
        // 사진이 많아 제일 비싼 방이 바로 그 이유로 캐시를 못 받았습니다.
        let estimatedTokens = TokenEstimator.estimatedTokens(contents: contents)
            + TokenEstimator.textTokens(system)
        guard estimatedTokens >= Self.minimumCacheTokens else { return }

        let previous = prefixCaches[roomId]

        if previous == nil {
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
            guard let previousRequestAt,
                  now.timeIntervalSince(previousRequestAt) <= Self.cacheBurstWindow else { return }
        }

        if let previous {
            // 이미 같은 구간을 덮고 있으면 다시 만들 것이 없습니다.
            if previous.coveredTurns >= contents.count,
               previous.expiresAt > now.addingTimeInterval(60) {
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
            let tail = TokenEstimator.estimatedTokens(
                contents: Array(contents.dropFirst(previous.coveredTurns)))
            let worthIt = tail >= max(Self.cacheRefreshMinTailTokens, previous.tokenCount / 5)
            let expiringSoon = previous.expiresAt <= now.addingTimeInterval(Self.cacheRefreshTTLFloor)
            guard worthIt || expiringSoon else { return }
        }

        guard let url = URL(string: "\(Self.geminiBaseURL)/cachedContents") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 30

        let payload: [String: Any] = [
            "model": "models/\(AIModel.gemini37Flash.rawValue)",
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "ttl": "\(Self.cacheTTLSeconds)s"
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else { return }
        request.httpBody = httpBody

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else {
            // 캐시는 요금 최적화 수단일 뿐이라 실패해도 대화에는 영향이 없습니다. 조용히 넘어갑니다.
            return
        }

        let cachedTokens = intValue((json["usageMetadata"] as? [String: Any])?["totalTokenCount"])
        prefixCaches[roomId] = PrefixCache(
            name: name,
            coveredTurns: contents.count,
            fingerprint: fingerprint(contents, system: system),
            expiresAt: Date().addingTimeInterval(TimeInterval(Self.cacheTTLSeconds)),
            tokenCount: cachedTokens > 0 ? cachedTokens : estimatedTokens
        )

        // 올린 토큰과 보관량을 함께 적습니다.
        //
        // **올린 토큰을 입력 요금으로 칩니다.** 예전에는 보관료만 적어서, 캐시를
        // 매 턴 새로 만드는 동안 그 비용이 앱 화면에서 통째로 사라져 있었습니다.
        //
        // 보관량은 실제 보관 시간이 아니라 TTL 전체로 잡습니다. 다음 갱신 때
        // 이전 것을 지우므로 실제로는 그보다 짧습니다. 이것도 넉넉한 쪽입니다.
        if cachedTokens > 0 {
            await MainActor.run {
                TokenUsageManager.shared.recordCacheCreation(
                    roomId: roomId,
                    model: .gemini37Flash,
                    tokens: cachedTokens,
                    tokenHours: Double(cachedTokens) * (Double(Self.cacheTTLSeconds) / 3600.0)
                )
            }
        }

        // 이전 캐시는 보관 요금이 붙으므로 새 캐시가 자리 잡은 뒤 지웁니다.
        if let previous { await deleteCache(named: previous.name, apiKey: apiKey) }
    }

    func deleteCache(named name: String, apiKey: String) async {
        guard let url = URL(string: "\(Self.geminiBaseURL)/\(name)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 15
        _ = try? await URLSession.shared.data(for: request)
    }

    func fingerprint(_ contents: [[String: Any]], system: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(system.utf8))
        for item in contents {
            guard let data = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) else { continue }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

}
