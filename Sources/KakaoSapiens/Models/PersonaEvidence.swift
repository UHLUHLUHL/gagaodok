import Foundation

/// 말투 대사를 어디서 확인했는지의 등급입니다. 숫자가 작을수록 믿을 만합니다.
///
/// 저장 값은 폰(`PersonaSourceTier`)과 같은 대문자 이름입니다. 나중에 기기 사이에 옮겨도
/// 같은 글자로 읽히게 하려는 것입니다. 모르는 값은 가장 낮은 등급으로 읽습니다.
public enum PersonaSourceTier: String, Codable, CaseIterable, Sendable {
    case officialLocalizedVideo = "OFFICIAL_LOCALIZED_VIDEO"
    case officialOriginalVideo = "OFFICIAL_ORIGINAL_VIDEO"
    case officialText = "OFFICIAL_TEXT"
    case reputableSecondary = "REPUTABLE_SECONDARY"
    case unverified = "UNVERIFIED"

    public var priority: Int {
        switch self {
        case .officialLocalizedVideo: return 0
        case .officialOriginalVideo: return 1
        case .officialText: return 2
        case .reputableSecondary: return 3
        case .unverified: return 4
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try String(from: decoder)
        self = PersonaSourceTier(rawValue: raw) ?? .unverified
    }
}

/// 자동 조사에서 확인한 대사 한 줄과 그 출처입니다. 필드는 폰과 같습니다.
public struct PersonaSampleEvidence: Codable, Equatable, Sendable {
    public var text: String
    public var speaker: String
    public var sourceUrl: String
    public var sourceTitle: String
    public var sourceTier: PersonaSourceTier
    public var edition: String
    public var language: String
    public var timestampSeconds: Int?
    public var contextTag: String
    public var confidence: String
    /// 거의 같은 대사가 몇 번 나왔는지입니다. 중복을 버려도 관찰 횟수는 남깁니다.
    public var similarSampleCount: Int

    public init(
        text: String = "",
        speaker: String = "",
        sourceUrl: String = "",
        sourceTitle: String = "",
        sourceTier: PersonaSourceTier = .unverified,
        edition: String = "",
        language: String = "",
        timestampSeconds: Int? = nil,
        contextTag: String = "",
        confidence: String = "",
        similarSampleCount: Int = 1
    ) {
        self.text = text
        self.speaker = speaker
        self.sourceUrl = sourceUrl
        self.sourceTitle = sourceTitle
        self.sourceTier = sourceTier
        self.edition = edition
        self.language = language
        self.timestampSeconds = timestampSeconds
        self.contextTag = contextTag
        self.confidence = confidence
        self.similarSampleCount = similarSampleCount
    }

    private enum CodingKeys: String, CodingKey {
        case text, speaker, sourceUrl, sourceTitle, sourceTier, edition, language
        case timestampSeconds, contextTag, confidence, similarSampleCount
    }

    // 폰처럼 빠진 필드는 기본값으로 읽습니다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker) ?? ""
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl) ?? ""
        sourceTitle = try c.decodeIfPresent(String.self, forKey: .sourceTitle) ?? ""
        sourceTier = try c.decodeIfPresent(PersonaSourceTier.self, forKey: .sourceTier) ?? .unverified
        edition = try c.decodeIfPresent(String.self, forKey: .edition) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        timestampSeconds = try c.decodeIfPresent(Int.self, forKey: .timestampSeconds)
        contextTag = try c.decodeIfPresent(String.self, forKey: .contextTag) ?? ""
        confidence = try c.decodeIfPresent(String.self, forKey: .confidence) ?? ""
        similarSampleCount = try c.decodeIfPresent(Int.self, forKey: .similarSampleCount) ?? 1
    }
}
