import Foundation
import SwiftUI

public struct ModelTokenUsage: Codable, Equatable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var cacheWriteTokens: Int
    public var outputTokens: Int
    public var requestCount: Int
    /// 명시적 캐시를 올려둔 누적량입니다. 토큰 수 × 보관 시간으로 요금이 매겨집니다.
    public var cacheStorageTokenHours: Double

    public init(
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        outputTokens: Int = 0,
        requestCount: Int = 0,
        cacheStorageTokenHours: Double = 0
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.requestCount = requestCount
        self.cacheStorageTokenHours = cacheStorageTokenHours
    }

    // 이전 버전 장부에는 보관량 항목이 없었습니다. 없으면 0으로 읽습니다.
    private enum CodingKeys: String, CodingKey {
        case inputTokens, cachedInputTokens, cacheWriteTokens, outputTokens, requestCount, cacheStorageTokenHours
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        cacheWriteTokens = try container.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        requestCount = try container.decodeIfPresent(Int.self, forKey: .requestCount) ?? 0
        cacheStorageTokenHours = try container.decodeIfPresent(Double.self, forKey: .cacheStorageTokenHours) ?? 0
    }

    public var totalTokens: Int { inputTokens + outputTokens }
    public var cacheEligibleInputTokens: Int { max(inputTokens, cachedInputTokens + cacheWriteTokens) }
    public var cacheHitRate: Double {
        guard cacheEligibleInputTokens > 0 else { return 0 }
        return min(1, Double(cachedInputTokens) / Double(cacheEligibleInputTokens))
    }

    public func costUSD(for model: AIModel) -> Double {
        let cached = min(cachedInputTokens, inputTokens)
        let writes = min(cacheWriteTokens, max(0, inputTokens - cached))
        let regular = max(0, inputTokens - cached - writes)
        return Double(regular) / 1_000_000 * model.inputPricePerMillion
            + Double(cached) / 1_000_000 * model.cachedInputPricePerMillion
            + Double(writes) / 1_000_000 * model.inputPricePerMillion * model.cacheWriteMultiplier
            + Double(outputTokens) / 1_000_000 * model.outputPricePerMillion
            + cacheStorageCostUSD(for: model)
    }

    /// 명시적 캐시 보관료입니다. 절감액에 비하면 작지만 실제로 청구되는 항목입니다.
    public func cacheStorageCostUSD(for model: AIModel) -> Double {
        cacheStorageTokenHours / 1_000_000 * model.cacheStoragePricePerMillionPerHour
    }

    public func costWithoutCacheUSD(for model: AIModel) -> Double {
        Double(inputTokens) / 1_000_000 * model.inputPricePerMillion
            + Double(outputTokens) / 1_000_000 * model.outputPricePerMillion
    }

    public func adding(_ other: ModelTokenUsage) -> ModelTokenUsage {
        ModelTokenUsage(
            inputTokens: inputTokens + other.inputTokens,
            cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
            cacheWriteTokens: cacheWriteTokens + other.cacheWriteTokens,
            outputTokens: outputTokens + other.outputTokens,
            requestCount: requestCount + other.requestCount,
            cacheStorageTokenHours: cacheStorageTokenHours + other.cacheStorageTokenHours
        )
    }
}

// 이전 UI와 저장 데이터 호환을 위한 합산 표현입니다.
public struct RoomTokenUsage: Codable, Equatable {
    public var promptTokens: Int
    public var candidatesTokens: Int
    public var cachedTokens: Int
    public var totalTokens: Int { promptTokens + candidatesTokens }

    public init(promptTokens: Int = 0, candidatesTokens: Int = 0, cachedTokens: Int = 0) {
        self.promptTokens = promptTokens
        self.candidatesTokens = candidatesTokens
        self.cachedTokens = cachedTokens
    }

    public func costUSD() -> Double {
        ModelTokenUsage(
            inputTokens: promptTokens,
            cachedInputTokens: cachedTokens,
            outputTokens: candidatesTokens
        ).costUSD(for: .gemini37Flash)
    }

    public func costKRW(exchangeRate: Double = 1420.0) -> Double { costUSD() * exchangeRate }
}

private struct UsageLedger: Codable {
    var rooms: [String: [String: ModelTokenUsage]]
}

@MainActor
public final class TokenUsageManager: ObservableObject {
    public static let shared = TokenUsageManager()

    @Published public private(set) var usageByRoom: [UUID: [AIModel: ModelTokenUsage]] = [:]
    @Published public var exchangeRate: Double = 1420.0 {
        didSet { UserDefaults.standard.set(exchangeRate, forKey: "usageExchangeRate") }
    }

    private let usageFileURL: URL

    private init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = appSupport?.appendingPathComponent("KakaoSapiens", isDirectory: true) ?? fileManager.temporaryDirectory
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        usageFileURL = dir.appendingPathComponent("token_usage.json")
        let savedRate = UserDefaults.standard.double(forKey: "usageExchangeRate")
        if savedRate > 0 { exchangeRate = savedRate }
        loadUsage()
        bootstrapExistingHistoryIfEmpty()
    }

    public func recordUsage(
        roomId: UUID,
        model: AIModel,
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        cacheStorageTokenHours: Double = 0
    ) {
        var room = usageByRoom[roomId] ?? [:]
        let delta = ModelTokenUsage(
            inputTokens: max(0, inputTokens),
            cachedInputTokens: max(0, cachedInputTokens),
            cacheWriteTokens: max(0, cacheWriteTokens),
            outputTokens: max(0, outputTokens),
            requestCount: 1,
            cacheStorageTokenHours: max(0, cacheStorageTokenHours)
        )
        room[model] = (room[model] ?? ModelTokenUsage()).adding(delta)
        usageByRoom[roomId] = room
        saveUsage()
    }

    // 기존 호출부 호환. 새 코드는 모델을 명시합니다.
    public func recordUsage(roomId: UUID, promptTokens: Int, candidatesTokens: Int) {
        recordUsage(
            roomId: roomId,
            model: .gemini37Flash,
            inputTokens: promptTokens,
            outputTokens: candidatesTokens
        )
    }

    /// 캐시 보관량만 따로 더합니다. 요청 횟수는 늘리지 않습니다.
    public func recordCacheStorage(roomId: UUID, model: AIModel, tokenHours: Double) {
        guard tokenHours > 0 else { return }
        var room = usageByRoom[roomId] ?? [:]
        var entry = room[model] ?? ModelTokenUsage()
        entry.cacheStorageTokenHours += tokenHours
        room[model] = entry
        usageByRoom[roomId] = room
        saveUsage()
    }

    public func usage(for roomId: UUID, model: AIModel) -> ModelTokenUsage {
        usageByRoom[roomId]?[model] ?? ModelTokenUsage()
    }

    public func totalUsage(for model: AIModel) -> ModelTokenUsage {
        usageByRoom.values.reduce(ModelTokenUsage()) { partial, room in
            partial.adding(room[model] ?? ModelTokenUsage())
        }
    }

    public func getUsage(for roomId: UUID) -> RoomTokenUsage {
        let total = AIModel.allCases.reduce(ModelTokenUsage()) { partial, model in
            partial.adding(usage(for: roomId, model: model))
        }
        return RoomTokenUsage(
            promptTokens: total.inputTokens,
            candidatesTokens: total.outputTokens,
            cachedTokens: total.cachedInputTokens
        )
    }

    public var totalPromptTokens: Int { AIModel.allCases.reduce(0) { $0 + totalUsage(for: $1).inputTokens } }
    public var totalCandidatesTokens: Int { AIModel.allCases.reduce(0) { $0 + totalUsage(for: $1).outputTokens } }
    public var totalCachedTokens: Int { AIModel.allCases.reduce(0) { $0 + totalUsage(for: $1).cachedInputTokens } }
    public var totalTokens: Int { totalPromptTokens + totalCandidatesTokens }
    public var totalCostUSD: Double {
        AIModel.allCases.reduce(0) { $0 + totalUsage(for: $1).costUSD(for: $1) }
    }
    public var totalCostKRW: Double { totalCostUSD * exchangeRate }
    public var totalSavingsUSD: Double {
        AIModel.allCases.reduce(0) {
            let usage = totalUsage(for: $1)
            return $0 + max(0, usage.costWithoutCacheUSD(for: $1) - usage.costUSD(for: $1))
        }
    }
    public var overallCacheHitRate: Double {
        guard totalPromptTokens > 0 else { return 0 }
        return Double(totalCachedTokens) / Double(totalPromptTokens)
    }

    public func costUSD(for roomId: UUID) -> Double {
        AIModel.allCases.reduce(0) { $0 + usage(for: roomId, model: $1).costUSD(for: $1) }
    }

    public func resetAllUsage() {
        usageByRoom.removeAll()
        saveUsage()
    }

    private func saveUsage() {
        let rooms = usageByRoom.reduce(into: [String: [String: ModelTokenUsage]]()) { result, pair in
            result[pair.key.uuidString] = pair.value.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value }
        }
        guard let data = try? JSONEncoder().encode(UsageLedger(rooms: rooms)) else { return }
        try? data.write(to: usageFileURL, options: .atomic)
    }

    private func loadUsage() {
        guard let data = try? Data(contentsOf: usageFileURL) else { return }

        if let ledger = try? JSONDecoder().decode(UsageLedger.self, from: data) {
            // 3.6 시절 키는 3.7로 접히기 때문에 덮어쓰지 않고 합산해야 기록이 보존됩니다.
            var migrated = false
            usageByRoom = ledger.rooms.reduce(into: [:]) { result, pair in
                guard let roomId = UUID(uuidString: pair.key) else { return }
                result[roomId] = pair.value.reduce(into: [AIModel: ModelTokenUsage]()) { models, modelPair in
                    guard let model = AIModel(storedValue: modelPair.key) else { return }
                    if model.rawValue != modelPair.key { migrated = true }
                    models[model] = (models[model] ?? ModelTokenUsage()).adding(modelPair.value)
                }
            }
            // 다음 실행부터는 새 식별자만 읽도록 장부를 한 번 정규화해 둡니다.
            if migrated { saveUsage() }
            return
        }

        // v1의 Gemini 전용 파일을 새 모델별 장부로 자동 마이그레이션합니다.
        if let legacy = try? JSONDecoder().decode([String: RoomTokenUsage].self, from: data) {
            for (key, value) in legacy {
                guard let roomId = UUID(uuidString: key) else { continue }
                usageByRoom[roomId] = [
                    .gemini37Flash: ModelTokenUsage(
                        inputTokens: value.promptTokens,
                        outputTokens: value.candidatesTokens
                    )
                ]
            }
            saveUsage()
        }
    }

    // 예전에는 여기서 과거 대화를 글자 수로 추정해 장부에 채워 넣었습니다.
    // 그런데 그 추정이 실제 청구액과 구분 없이 합산되어 대시보드 숫자 전체를 믿을 수 없게 만들었고,
    // 계수(글자수 × 1.6)도 실측한 한국어 토큰 밀도(약 2.4자당 1토큰)와 4배 가까이 어긋나 있었습니다.
    // 이제는 API가 실제로 보고한 값만 기록합니다.
    private func bootstrapExistingHistoryIfEmpty() {}
}
