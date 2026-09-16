import Foundation
import CryptoKit

/// 명시적 캐시(`cachedContents`)를 만들고 쓰고 버리는 규칙입니다.
///
/// 언제 만들고 언제 안 만드는지가 요금의 대부분을 정합니다.
extension GeminiService {
    // Gemini의 implicit 캐시는 "완전히 똑같은 요청"이 짧은 간격으로 반복될 때만 걸립니다.
    // 채팅처럼 턴이 계속 붙는 패턴에서는 접두사가 같아도 적중하지 않아 실측 적중률이 0%였습니다.
    // 그래서 대화 접두사를 명시적 캐시(cachedContents)로 올려두고 새 턴만 보냅니다. 실측 99.7%.
    //
    // 기록 형식은 `GeminiCachePolicy.swift`에 있습니다. 옛 파일을 읽는 규칙을 따로
    // 검사하려고 서비스 밖으로 뺐습니다.
    typealias PrefixCache = GeminiPrefixCache

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
        let now = Date()
        var result: [UUID: PrefixCache] = [:]
        var expired: [(UUID, PrefixCache)] = []
        for (key, cache) in stored {
            guard let id = UUID(uuidString: key) else { continue }
            // 이미 만료된 것은 되살리지 않습니다. 서버에도 없습니다.
            if cache.expiresAt > now { result[id] = cache } else { expired.append((id, cache)) }
        }
        if !expired.isEmpty { settleExpiredCaches(expired, survivors: result) }
        return result
    }

    /// 앱이 꺼진 사이 만료된 캐시의 보관량을 장부에 적습니다.
    ///
    /// 예전에는 조용히 걸러내기만 해서 그 구간이 장부에서 빠질 수 있었습니다.
    /// 끝난 시각은 앱을 켠 지금이 아니라 **만료 시각**입니다.
    ///
    /// **파일부터 줄이고, 그것이 성공했을 때만 적습니다.** 순서가 반대면 쓰기가
    /// 실패했을 때 다음 실행에서 같은 캐시를 또 적습니다. 보관량은 적게 나오는 편이
    /// 많게 나오는 것보다 낫습니다 — 많으면 없는 절감을 있다고 읽게 됩니다.
    ///
    /// 이 함수는 `prefixCaches`가 만들어지는 도중에 불리므로 그 속성을 건드리지 않습니다.
    private static func settleExpiredCaches(_ expired: [(UUID, PrefixCache)], survivors: [UUID: PrefixCache]) {
        let snapshot = survivors.reduce(into: [String: PrefixCache]()) { $0[$1.key.uuidString] = $1.value }
        guard let data = try? JSONEncoder().encode(snapshot),
              (try? data.write(to: prefixCacheStoreURL, options: .atomic)) != nil else { return }
        let entries = expired.compactMap { id, cache -> (UUID, AIModel, Double)? in
            let hours = cache.leaseTokenHoursAtExpiry
            guard hours > 0, let model = AIModel(storedValue: cache.modelIdentifier) else { return nil }
            return (id, model, hours)
        }
        guard !entries.isEmpty else { return }
        Task { @MainActor in
            for (id, model, hours) in entries {
                TokenUsageManager.shared.recordCacheLeaseEnd(roomId: id, model: model, tokenHours: hours)
            }
        }
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
    // 근거는 `GeminiCachePolicy.minimumCacheTokens`에 적었습니다. 예전 1,200은 옛 모델 기준이었습니다.
    static let minimumCacheTokens = GeminiCachePolicy.minimumCacheTokens

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
        model: AIModel,
        contents: [[String: Any]],
        system: String,
        apiKey: String
    ) -> PrefixCache? {
        guard let cache = prefixCaches[roomId] else { return nil }

        // **다른 모델로 만든 캐시는 쓸 수 없습니다.** 붙이면 서버가 거절하고,
        // 스트리밍 중이면 캐시 없이 다시 보낼 수도 없어 그대로 실패합니다.
        // 서버에는 아직 살아 있으므로 지워야 보관료가 멈춥니다.
        guard cache.modelIdentifier == model.rawValue else {
            dropCache(for: roomId, deleteRemote: true, apiKey: apiKey)
            return nil
        }

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
        // 버리는 캐시가 산 만큼 보관량을 적습니다. 만료된 것은 만료 시각까지만 셉니다.
        settleLease(of: removed, roomId: roomId, at: Date())
        if deleteRemote {
            Task { await self.deleteCache(named: removed.name, apiKey: apiKey) }
        }
    }

    /// 캐시가 산 만큼 보관량을 장부에 적습니다. 만료 시각을 넘겨 세지 않습니다.
    func settleLease(of cache: PrefixCache, roomId: UUID, at end: Date) {
        let hours = cache.leaseTokenHours(until: end)
        guard hours > 0, let model = AIModel(storedValue: cache.modelIdentifier) else { return }
        Task { @MainActor in
            TokenUsageManager.shared.recordCacheLeaseEnd(roomId: roomId, model: model, tokenHours: hours)
        }
    }

    func refreshPrefixCache(
        roomId: UUID,
        model: AIModel,
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
            // 대화에 쓰는 모델로 만들어야 합니다. 예전에는 3.7로 박아 두었고, 대화도
            // 3.7로만 나갔기 때문에 어긋남이 드러나지 않았습니다.
            "model": "models/\(model.rawValue)",
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
        let createdAt = Date()
        // 네트워크를 기다리는 사이 다른 요청이 이전 캐시를 이미 버렸을 수 있습니다
        // (`dropCache`가 정산과 원격 삭제까지 마칩니다). 그때 여기서 또 정산하면
        // 같은 캐시가 두 번 적힙니다. 아직 그 자리에 있을 때만 여기서 처리합니다.
        let previousStillHeld = previous.map { prefixCaches[roomId]?.name == $0.name } ?? false
        prefixCaches[roomId] = PrefixCache(
            name: name,
            coveredTurns: contents.count,
            fingerprint: fingerprint(contents, system: system),
            expiresAt: createdAt.addingTimeInterval(TimeInterval(Self.cacheTTLSeconds)),
            tokenCount: cachedTokens > 0 ? cachedTokens : estimatedTokens,
            modelIdentifier: model.rawValue,
            createdAt: createdAt
        )

        // 올린 토큰을 적습니다. **요금에는 넣지 않습니다** — 실제 청구서에 캐시 생성
        // 항목이 없었습니다(`TokenUsageManager.costUSD` 참고). 몇 번 다시 만드는지는
        // 진단에 필요하므로 개수는 계속 셉니다.
        //
        // 보관량은 여기서 적지 않습니다. 예전에는 만들 때 TTL 전체를 미리 적었는데,
        // 교체로 일찍 끝난 캐시가 과대 계상됐습니다. 이제 끝날 때 산 만큼 적습니다.
        if cachedTokens > 0 {
            await MainActor.run {
                TokenUsageManager.shared.recordCacheCreation(roomId: roomId, model: model, tokens: cachedTokens)
            }
        }

        // 이전 캐시는 보관 요금이 붙으므로 새 캐시가 자리 잡은 뒤 지웁니다.
        // 지우기 전에 산 만큼 적습니다.
        if let previous, previousStillHeld {
            settleLease(of: previous, roomId: roomId, at: createdAt)
            await deleteCache(named: previous.name, apiKey: apiKey)
        }
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
