import Foundation
import Security

public enum AIModel: String, CaseIterable, Codable, Identifiable {
    case gemini37Flash = "gemini-3.7-flash"
    case gpt56Luna = "gpt-5.6-luna"

    public var id: String { rawValue }

    // 이전 버전이 저장한 모델 식별자를 현재 모델로 이어 붙입니다.
    // 선택 모델(UserDefaults)과 사용량 장부(token_usage.json)가 모두 rawValue를 키로 쓰기 때문에
    // 이 표가 없으면 3.6 시절에 쌓인 토큰·요금 기록이 조용히 사라집니다.
    private static let legacyIdentifiers: [String: AIModel] = [
        "gemini-3.6-flash": .gemini37Flash
    ]

    public init?(storedValue: String) {
        if let model = AIModel(rawValue: storedValue) {
            self = model
        } else if let model = AIModel.legacyIdentifiers[storedValue] {
            self = model
        } else {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let model = AIModel(storedValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "알 수 없는 모델 식별자입니다: \(raw)"
            )
        }
        self = model
    }

    public var displayName: String {
        switch self {
        case .gemini37Flash: return "Gemini 3.7 Flash"
        case .gpt56Luna: return "GPT-5.6 Luna"
        }
    }

    public var shortName: String {
        switch self {
        case .gemini37Flash: return "Gemini"
        case .gpt56Luna: return "Luna"
        }
    }

    public var providerName: String {
        switch self {
        case .gemini37Flash: return "Google"
        case .gpt56Luna: return "OpenAI"
        }
    }

    // Gemini 3.7 Flash 도입 요금은 2026-12-31까지만 적용되고 2027-01-01부터 정가로 두 배가 됩니다.
    // 대시보드는 "지금 청구되는 금액"을 보여줘야 하므로 단가를 날짜에 따라 고릅니다.
    private static let standardPricingStart: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        var components = DateComponents()
        components.year = 2027
        components.month = 1
        components.day = 1
        return calendar.date(from: components) ?? .distantFuture
    }()

    public static var isIntroductoryPricingActive: Bool { Date() < standardPricingStart }

    public var inputPricePerMillion: Double {
        switch self {
        case .gemini37Flash: return Self.isIntroductoryPricingActive ? 0.75 : 1.50
        case .gpt56Luna: return 1.00
        }
    }

    public var cachedInputPricePerMillion: Double {
        switch self {
        case .gemini37Flash: return Self.isIntroductoryPricingActive ? 0.075 : 0.15
        case .gpt56Luna: return 0.10
        }
    }

    public var outputPricePerMillion: Double {
        switch self {
        case .gemini37Flash: return Self.isIntroductoryPricingActive ? 3.75 : 7.50
        case .gpt56Luna: return 6.00
        }
    }

    /// 명시적 캐시를 1시간 보관할 때 100만 토큰당 요금입니다.
    /// Gemini는 캐시를 올려두는 동안 별도로 보관료가 붙습니다.
    public var cacheStoragePricePerMillionPerHour: Double {
        switch self {
        case .gemini37Flash: return Self.isIntroductoryPricingActive ? 0.50 : 1.00
        case .gpt56Luna: return 0  // OpenAI는 보관료 없이 캐시 쓰기 요금만 받습니다.
        }
    }

    /// 캐시에 처음 써 넣을 때 입력 단가 대비 배수입니다.
    /// OpenAI 계열에만 있는 개념이라 Gemini는 1.0으로 두고 대신 보관료로 계산합니다.
    public var cacheWriteMultiplier: Double {
        switch self {
        case .gemini37Flash: return 1.0
        case .gpt56Luna: return 1.25
        }
    }
}

@MainActor
public final class ModelSelectionManager: ObservableObject {
    public static let shared = ModelSelectionManager()

    @Published public var selectedModel: AIModel {
        didSet { UserDefaults.standard.set(selectedModel.rawValue, forKey: Self.modelKey) }
    }

    private static let modelKey = "selectedAIModel"

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.modelKey)
        self.selectedModel = AIModel(storedValue: saved ?? "") ?? .gemini37Flash
    }

    public var hasOpenAIKey: Bool { KeychainStore.openAIAPIKey != nil }
    public var hasGeminiKey: Bool { KeychainStore.geminiAPIKey != nil }
}

public enum KeychainStore {
    // 공급자마다 키체인 항목을 따로 둡니다. 한쪽 키를 지워도 다른 쪽은 남습니다.
    public enum Credential: String, CaseIterable, Identifiable {
        case gemini
        case openAI

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .gemini: return "Gemini"
            case .openAI: return "OpenAI"
            }
        }

        fileprivate var service: String {
            switch self {
            case .gemini: return "com.sapiens.kakaotalk.gemini-api-key"
            case .openAI: return "com.sapiens.kakaotalk.openai-api-key"
            }
        }

        fileprivate var account: String { rawValue }
    }

    public static func apiKey(for credential: Credential) -> String? {
        var query = baseQuery(for: credential)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    public static func save(_ key: String, for credential: Credential) throws {
        let base = baseQuery(for: credential)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            SecItemDelete(base as CFDictionary)
            return
        }

        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            // 이 맥에서, 로그인 키체인이 열려 있을 때만 읽히게 합니다.
            // iCloud 키체인으로 동기화되거나 백업을 통해 다른 기기로 새지 않습니다.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    public static var openAIAPIKey: String? { apiKey(for: .openAI) }
    public static func saveOpenAIAPIKey(_ key: String) throws { try save(key, for: .openAI) }

    public static var geminiAPIKey: String? { apiKey(for: .gemini) }
    public static func saveGeminiAPIKey(_ key: String) throws { try save(key, for: .gemini) }

    private static func baseQuery(for credential: Credential) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: credential.service,
            kSecAttrAccount as String: credential.account
        ]
    }

    public enum KeychainError: LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .status(let status): return "키체인 저장 오류 (\(status))"
            }
        }
    }
}
