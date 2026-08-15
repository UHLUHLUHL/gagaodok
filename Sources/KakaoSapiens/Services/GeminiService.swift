import Foundation
import AppKit
import CryptoKit

public struct GeneratedMessageBubble {
    public let text: String
    public let attachment: ChatAttachment?

    public init(text: String, attachment: ChatAttachment? = nil) {
        self.text = text
        self.attachment = attachment
    }
}

public struct GeneratedAIResponse {
    public let rawText: String
    public let bubbles: [GeneratedMessageBubble]

    public init(rawText: String, bubbles: [GeneratedMessageBubble]) {
        self.rawText = rawText
        self.bubbles = bubbles
    }
}

/// 스트림 조각을 받아 완성된 말풍선만 밖으로 내보냅니다.
///
/// 버퍼는 값 타입이라 스트림 콜백이 여러 번 불려도 상태를 이어가려면 담아 둘 곳이 필요합니다.
/// 문단이 완성되면 기존 말풍선 분리기에 그대로 넘기므로, 그래프 태그 처리나
/// 이름 접두사 제거 같은 규칙이 스트리밍에서도 똑같이 적용됩니다.
public actor StreamBubbleSink {
    private var buffer = StreamingBubbleBuffer()
    private let botName: String
    private let onBubble: @Sendable (GeneratedMessageBubble) async -> Void
    private let makeBubbles: @Sendable (String) async -> [GeneratedMessageBubble]

    public init(
        botName: String,
        onBubble: @escaping @Sendable (GeneratedMessageBubble) async -> Void,
        makeBubbles: @escaping @Sendable (String) async -> [GeneratedMessageBubble]
    ) {
        self.botName = botName
        self.onBubble = onBubble
        self.makeBubbles = makeBubbles
    }

    public func consume(_ piece: String) async {
        for paragraph in buffer.append(piece) {
            for bubble in await makeBubbles(paragraph) { await onBubble(bubble) }
        }
    }

    public func finish() async {
        let rest = buffer.flush()
        guard !rest.isEmpty else { return }
        for bubble in await makeBubbles(rest) { await onBubble(bubble) }
    }
}

public actor GeminiService {
    public static let shared = GeminiService()

    private let resilientSession: URLSession

    // 이 고정 접두사는 두 공급자에서 동일하게 재사용됩니다. 방 이름 같은 동적 값은 끝에 둬 캐시 적중률을 높입니다.
    private let stableSystemPrompt = """
    # 역할
    당신은 사용자의 수학 학습 파트너이자 냉철한 코칭 멘토다. 암기보다 구조와 원리를 이해하도록 돕는다.

    # 지도 방식
    - 사용자가 바로 정답을 요구하지 않았다면 핵심 개념과 첫 실마리를 짚고, 다음 단계를 생각하게 하는 구체적인 질문을 던진다.
    - 사용자가 풀이·정답을 명시적으로 요청하거나 막혔다고 말하면 근거가 포함된 전체 풀이를 간결하고 빠짐없이 제시한다.
    - 틀린 부분은 정확히 지적하고 이유를 설명한다. 좋은 접근은 과장 없이 인정한다.
    - 항상 자연스러운 한국어 존댓말을 쓴다.

    # 카카오톡 말풍선과 수식
    - 답변을 자연스러운 호흡의 짧은 문단으로 나누고 문단 사이에는 빈 줄 하나를 둔다.
    - 짧은 수식은 $...$로 문장 안에 쓴다.
    - 긴 계산, 여러 등호가 이어지는 전개, 핵심 결론식은 $$...$$ 독립 문단으로 쓴다.
    - 같은 설명을 반복하거나 불필요한 서론을 붙이지 않는다.

    # 그래프
    그래프가 학습에 실질적으로 도움이 될 때만 별도 문단에 다음 형식 중 하나를 쓴다.
    [GRAPH: type=cartesian, func=sin(x), xmin=-6.28, xmax=6.28, ymin=-2, ymax=2, title="y = sin(x)"]
    [GRAPH: type=parametric, x=t*cos(t), y=t*sin(t), tmin=0, tmax=6.28, xmin=-7, xmax=7, ymin=-7, ymax=7, title="매개변수 곡선"]
    수식에는 + - * / ^ 와 괄호, 그리고 sin, cos, tan, asin, acos, atan, sinh, cosh, tanh,
    exp, ln, log, sqrt, abs를 쓸 수 있다. 상수 pi와 e도 쓸 수 있고 2x처럼 곱셈 기호를 생략해도 된다.
    직교함수는 변수 x를, 매개변수 곡선은 변수 t를 쓴다. 이 범위를 벗어나는 식은 그래프 태그로 만들지 않는다.
    """

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        resilientSession = URLSession(configuration: configuration)
    }

    public func generateResponse(
        conversation: [ConversationTurn],
        botName: String = "사피엔스",
        roomId: UUID? = nil,
        model requestedModel: AIModel? = nil,
        persona: PersonaStyle? = nil
    ) async throws -> GeneratedAIResponse {
        let model = await MainActor.run { requestedModel ?? ModelSelectionManager.shared.selectedModel }
        let rawText: String
        switch model {
        case .gemini37Flash:
            rawText = try await sendGeminiRequest(
                conversation: conversation, botName: botName, roomId: roomId, persona: persona
            )
        case .gpt56Luna:
            rawText = try await sendOpenAIRequest(
                conversation: conversation, botName: botName, roomId: roomId, persona: persona
            )
        }
        return GeneratedAIResponse(
            rawText: rawText,
            bubbles: parseResponseIntoBubbles(rawText: rawText, botName: botName)
        )
    }

    /// 답변을 말풍선이 완성되는 대로 흘려보냅니다.
    ///
    /// 글자 단위로 올리지 않는 이유는 청크가 수식 한가운데서 끊기기 때문입니다.
    /// `StreamingBubbleBuffer`가 구분자가 모두 닫힌 문단만 통과시키므로
    /// 깨진 수식이 화면에 뜨는 일이 없습니다.
    ///
    /// Gemini만 스트리밍합니다. Luna는 지금처럼 한 번에 받습니다.
    public func streamResponse(
        conversation: [ConversationTurn],
        botName: String = "사피엔스",
        roomId: UUID? = nil,
        model requestedModel: AIModel? = nil,
        persona: PersonaStyle? = nil,
        onBubble: @Sendable @escaping (GeneratedMessageBubble) async -> Void
    ) async throws -> String {
        let model = await MainActor.run { requestedModel ?? ModelSelectionManager.shared.selectedModel }
        guard model == .gemini37Flash else {
            let response = try await generateResponse(
                conversation: conversation, botName: botName, roomId: roomId,
                model: model, persona: persona
            )
            for bubble in response.bubbles { await onBubble(bubble) }
            return response.rawText
        }
        return try await sendGeminiRequest(
            conversation: conversation, botName: botName, roomId: roomId, persona: persona,
            onBubble: onBubble
        )
    }

    /// 캐릭터 이름이나 참고 링크만으로 말투를 조사한 결과입니다.
    public struct PersonaLookup {
        public let confidence: String   // 높음 / 보통 / 낮음
        public let note: String
        public let samples: [String]
        public let styleGuide: String
        public let sources: [String]

        public var isUsable: Bool { !samples.isEmpty || !styleGuide.isEmpty }
    }

    /// 대사를 외우고 있지 않아도 되도록, 이름이나 링크만으로 말투를 조사합니다.
    ///
    /// 검색 그라운딩과 URL 읽기를 함께 켜므로 이름이든 링크든 같은 입구로 처리됩니다.
    /// 스크린샷을 넘기면 거기 적힌 대사도 함께 읽습니다.
    /// 모르는 인물이면 지어내지 않고 확신도를 '낮음'으로 돌려줍니다.
    public func lookupPersona(
        query: String,
        imageBase64: String? = nil,
        imageMimeType: String? = nil
    ) async throws -> PersonaLookup {
        guard let apiKey = KeychainStore.geminiAPIKey else {
            throw serviceError("설정에서 Gemini API 키를 먼저 등록해주세요.")
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty || imageBase64 != nil else {
            throw serviceError("캐릭터 이름이나 참고 링크를 입력해주세요.")
        }

        let instruction = """
        너는 말투 조사관이다. 사용자가 지정한 인물의 말투를 조사해 정리한다.

        먼저 검색이나 주어진 링크·이미지에서 그 인물의 실제 대사를 찾는다. 그 다음 아래 형식으로만 출력한다.

        [확신도] 높음/보통/낮음 중 하나와 한 줄 근거.
        - 실제 대사를 여러 개 찾았으면 '높음'
        - 인물 설명은 찾았지만 대사가 적으면 '보통'
        - 인물을 특정하지 못했으면 '낮음'이라고 솔직히 적고 아래 두 절을 비운다

        [대사]
        찾은 실제 대사를 한 줄에 하나씩, 최대 20줄. 앞에 기호를 붙이지 않는다.
        지어내지 말고 실제로 찾은 것만 적는다. 찾지 못했으면 이 절을 비운다.

        [말투]
        - 문장 끝맺음:
        - 높임 수준:
        - 1인칭과 호칭:
        - 자주 쓰는 표현:
        - 문장 길이와 리듬:
        - 감정 표현:
        - 피해야 할 것:
        - 한 줄 요약:

        없는 사실을 지어내지 않는다. 확실하지 않으면 확신도를 낮춘다.
        """

        var parts: [[String: Any]] = []
        if !trimmedQuery.isEmpty { parts.append(["text": "인물 또는 참고 자료: \(trimmedQuery)"]) }
        if let imageBase64, let imageMimeType {
            parts.append(["text": "아래 이미지에 이 인물의 대사가 있다. 읽어서 활용한다."])
            parts.append(["inlineData": ["mimeType": imageMimeType, "data": imageBase64]])
        }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instruction]]],
            "contents": [["role": "user", "parts": parts]],
            // 이름이면 검색이, 링크가 섞여 있으면 URL 읽기가 각각 동작합니다.
            "tools": [["google_search": [:]], ["url_context": [:]]],
            "generationConfig": [
                "maxOutputTokens": 4096,
                "thinkingConfig": ["thinkingLevel": "medium"]
            ]
        ]

        guard let url = URL(string: "\(Self.geminiBaseURL)/models/\(AIModel.gemini37Flash.rawValue):generateContent") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try validatedJSON(data: data, response: response, provider: "Gemini")
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first,
              let responseParts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
            throw serviceError("말투 조사 결과를 읽을 수 없습니다.")
        }
        let text = responseParts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            throw serviceError(geminiEmptyResponseMessage(finishReason: candidate["finishReason"] as? String))
        }

        var sources: [String] = []
        if let grounding = candidate["groundingMetadata"] as? [String: Any],
           let chunks = grounding["groundingChunks"] as? [[String: Any]] {
            sources = chunks.compactMap { chunk in
                ((chunk["web"] as? [String: Any])?["title"] as? String)
            }
        }
        return Self.parsePersonaLookup(text, sources: sources)
    }

    static func parsePersonaLookup(_ text: String, sources: [String]) -> PersonaLookup {
        var confidence = "보통"
        var note = ""
        var samples: [String] = []
        var guideLines: [String] = []

        enum Section { case none, samples, guide }
        var section = Section.none

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[확신도]") {
                let body = line.replacingOccurrences(of: "[확신도]", with: "").trimmingCharacters(in: .whitespaces)
                for level in ["높음", "보통", "낮음"] where body.hasPrefix(level) {
                    confidence = level
                    note = body.dropFirst(level.count)
                        .trimmingCharacters(in: CharacterSet(charactersIn: " -–—()·,"))
                    break
                }
                if note.isEmpty { note = body }
                section = .none
                continue
            }
            if line.hasPrefix("[대사]") { section = .samples; continue }
            if line.hasPrefix("[말투]") { section = .guide; continue }
            if line.isEmpty { continue }

            switch section {
            case .samples:
                let cleaned = line
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))
                    .trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty { samples.append(cleaned) }
            case .guide:
                guideLines.append(line)
            case .none:
                break
            }
        }

        return PersonaLookup(
            confidence: confidence,
            note: note,
            samples: samples,
            styleGuide: guideLines.joined(separator: "\n"),
            sources: Array(Set(sources)).sorted()
        )
    }

    /// 미리보기에서 던져볼 상황들입니다.
    /// 설명·지적·칭찬은 말투가 가장 크게 갈리는 지점이라, 이 셋만 봐도 결이 맞는지 판단이 섭니다.
    public static let personaPreviewPrompts: [(situation: String, message: String)] = [
        ("설명할 때", "미분이 뭔지 한두 문장으로 짧게 설명해줘."),
        ("틀렸다고 말할 때", "x²의 미분은 2라고 배웠어. 맞지?"),
        ("칭찬할 때", "고마워! 덕분에 이해했어.")
    ]

    /// 저장하기 전에 이 말투가 실제 그 캐릭터 같은지 확인할 수 있도록 짧은 답변을 만듭니다.
    /// 실제 대화와 똑같은 시스템 지침을 쓰므로, 여기서 보이는 결이 채팅방에서도 그대로 나옵니다.
    public func previewPersona(persona: PersonaStyle, botName: String, message: String) async throws -> String {
        guard let apiKey = KeychainStore.geminiAPIKey else {
            throw serviceError("설정에서 Gemini API 키를 먼저 등록해주세요.")
        }
        var enabled = persona
        enabled.isEnabled = true
        let system = systemPrompt(botName: botName, persona: enabled)

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": message]]]],
            "generationConfig": [
                "maxOutputTokens": 2048,
                "thinkingConfig": ["thinkingLevel": "low"]
            ]
        ]
        guard let url = URL(string: "\(Self.geminiBaseURL)/models/\(AIModel.gemini37Flash.rawValue):generateContent") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try validatedJSON(data: data, response: response, provider: "Gemini")
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first,
              let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
            throw serviceError("미리보기를 읽을 수 없습니다.")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw serviceError(geminiEmptyResponseMessage(finishReason: candidate["finishReason"] as? String))
        }
        return text
    }

    /// 뽑아낸 말투 규칙을 사용자의 요청대로 손봅니다.
    ///
    /// 자동 추출은 관찰된 사실만 담기 때문에, 실제로 쓰다 보면
    /// "좀 더 딱딱하게", "이모지 빼줘", "존댓말로 바꿔줘" 같은 조정이 필요합니다.
    /// 원래 규칙을 통째로 다시 쓰지 않고 요청한 부분만 반영합니다.
    public func refinePersonaStyle(
        currentGuide: String,
        instruction: String,
        description: String,
        samples: [String]
    ) async throws -> String {
        guard let apiKey = KeychainStore.geminiAPIKey else {
            throw serviceError("설정에서 Gemini API 키를 먼저 등록해주세요.")
        }
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            throw serviceError("어떻게 고칠지 입력해주세요.")
        }
        let trimmedGuide = currentGuide.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuide.isEmpty else {
            throw serviceError("먼저 말투 규칙을 만들어주세요.")
        }

        let instructionPrompt = """
        너는 말투 규칙 편집자다. 주어진 말투 규칙을 사용자의 요청대로 고친다.

        규칙:
        - 요청과 관련된 항목만 고치고 나머지는 원래 문장을 그대로 둔다.
        - 원래와 같은 '- 항목: 내용' 목록 형식을 유지한다. 항목 이름을 바꾸지 않는다.
        - 요청이 기존 관찰과 충돌하면 요청을 따른다. 사용자가 원하는 방향이 우선이다.
        - 요청에 없는 내용을 새로 지어내지 않는다.
        - 마지막 '- 한 줄 요약:' 항목도 바뀐 내용에 맞게 갱신한다.

        설명이나 인사말 없이 고친 목록만 출력한다.
        """

        var userText = "현재 말투 규칙:\n\(trimmedGuide)\n\n"
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDescription.isEmpty { userText += "인물: \(trimmedDescription)\n\n" }
        if !samples.isEmpty {
            userText += "참고용 실제 대사:\n" + samples.prefix(20).joined(separator: "\n") + "\n\n"
        }
        userText += "고쳐줬으면 하는 방향:\n\(trimmedInstruction)"

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instructionPrompt]]],
            "contents": [["role": "user", "parts": [["text": userText]]]],
            "generationConfig": [
                "maxOutputTokens": 2560,
                "thinkingConfig": ["thinkingLevel": "low"]
            ]
        ]
        guard let url = URL(string: "\(Self.geminiBaseURL)/models/\(AIModel.gemini37Flash.rawValue):generateContent") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try validatedJSON(data: data, response: response, provider: "Gemini")
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first,
              let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
            throw serviceError("교정 결과를 읽을 수 없습니다.")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw serviceError(geminiEmptyResponseMessage(finishReason: candidate["finishReason"] as? String))
        }
        return text
    }

    /// 붙여넣은 대사에서 말투 규칙을 뽑아냅니다.
    ///
    /// 모델에게 "이 캐릭터처럼 말해"라고만 하면 흉내가 흐려집니다.
    /// 관찰 가능한 항목(문장 끝맺음, 호칭, 자주 쓰는 어휘, 문장 길이 등)을 짚어서 적게 하면
    /// 이후 대화에서 재현이 훨씬 안정적입니다.
    public func analyzePersonaStyle(description: String, samples: [String]) async throws -> String {
        guard let apiKey = KeychainStore.geminiAPIKey else {
            throw serviceError("설정에서 Gemini API 키를 먼저 등록해주세요.")
        }
        let joined = samples
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !joined.isEmpty else {
            throw serviceError("말투를 분석할 대사를 먼저 입력해주세요.")
        }

        let instruction = """
        너는 말투 분석가다. 아래 대사를 읽고, 다른 사람이 이 인물의 말투를 그대로 재현할 수 있도록
        관찰된 특징만 한국어로 정리한다. 대사에 없는 특징은 지어내지 않는다.

        다음 항목을 각각 한 줄씩, '- 항목: 내용' 형태로 쓴다. 해당 없으면 그 줄은 생략한다.
        - 문장 끝맺음: 자주 쓰는 어미와 종결 형태를 실제 예와 함께
        - 높임 수준: 반말/존댓말/혼용 중 무엇이며 어떤 상황에서 바뀌는지
        - 1인칭과 호칭: 자기를 뭐라 부르고 상대를 뭐라 부르는지
        - 자주 쓰는 표현: 반복되는 단어·감탄사·말버릇을 원문 그대로
        - 문장 길이와 리듬: 짧게 끊는지 길게 이어붙이는지
        - 감정 표현: 이모지·물결·느낌표 사용 습관
        - 피해야 할 것: 이 인물이 절대 쓰지 않을 법한 말투

        마지막에 '- 한 줄 요약:'으로 전체를 한 문장으로 압축한다.
        설명이나 인사말 없이 목록만 출력한다.
        """

        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instruction]]],
            "generationConfig": [
                "maxOutputTokens": 2048,
                "thinkingConfig": ["thinkingLevel": "low"]
            ]
        ]
        var userText = ""
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDescription.isEmpty { userText += "인물 설명: \(trimmedDescription)\n\n" }
        userText += "대사:\n\(joined)"
        body["contents"] = [["role": "user", "parts": [["text": userText]]]]

        guard let url = URL(string: "\(Self.geminiBaseURL)/models/\(AIModel.gemini37Flash.rawValue):generateContent") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try validatedJSON(data: data, response: response, provider: "Gemini")
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first,
              let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
            throw serviceError("말투 분석 결과를 읽을 수 없습니다.")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw serviceError(geminiEmptyResponseMessage(finishReason: candidate["finishReason"] as? String))
        }
        return text
    }

    /// generateContent에 한 번 보내고 JSON을 돌려줍니다.
    private func postGemini(body: [String: Any], apiKey: String, model: AIModel) async throws -> [String: Any] {
        guard let url = URL(string: "\(Self.geminiBaseURL)/models/\(model.rawValue):generateContent") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await resilientSession.data(for: request)
        return try validatedJSON(data: data, response: response, provider: "Gemini")
    }

    private func systemPrompt(botName: String, persona: PersonaStyle? = nil) -> String {
        var prompt = stableSystemPrompt
        // 말투는 방마다 고정이라 캐시 접두사 안쪽에 두어도 적중률이 떨어지지 않습니다.
        if let section = persona?.promptSection(botName: botName) {
            prompt += "\n\n" + section
        }
        prompt += "\n\n# 현재 대화 설정\n이 대화에서 당신의 이름은 '\(botName)'이다. 자신을 지칭해야 할 때 이 이름을 사용한다."
        return prompt
    }

    // Gemini 3.7 Flash는 사고 토큰도 출력 토큰 예산에서 함께 소모합니다.
    // thinkingLevel이 medium이므로 실제로 보이는 답변 길이보다 여유를 두고 잡습니다.
    private static let geminiMaxOutputTokens = 8192
    private static let geminiBaseURL = "https://generativelanguage.googleapis.com/v1beta"

    // Gemini의 implicit 캐시는 "완전히 똑같은 요청"이 짧은 간격으로 반복될 때만 걸립니다.
    // 채팅처럼 턴이 계속 붙는 패턴에서는 접두사가 같아도 적중하지 않아 실측 적중률이 0%였습니다.
    // 그래서 대화 접두사를 명시적 캐시(cachedContents)로 올려두고 새 턴만 보냅니다. 실측 99.7%.
    private struct PrefixCache {
        let name: String          // cachedContents/xxxx
        let coveredTurns: Int     // 이 캐시가 덮는 contents 앞부분의 개수
        let fingerprint: String   // 덮은 구간이 편집되지 않았는지 확인하는 지문
        let expiresAt: Date
    }

    private var prefixCaches: [UUID: PrefixCache] = [:]
    private var refreshingRooms: Set<UUID> = []
    /// 같은 방의 요약을 두 번 겹쳐 만들지 않도록 막습니다.
    private var summarizingRooms: Set<UUID> = []
    private static let cacheTTLSeconds = 900
    // 명시적 캐시는 1,024토큰 미만이면 생성이 거부됩니다. 어림값이 실제보다 조금 클 수 있으므로
    // 여유를 둡니다. 그래도 거부되면 캐시 없이 그냥 진행하므로 대화에는 영향이 없습니다.
    private static let minimumCacheTokens = 1200

    /// 한 구간을 요약해 방의 요약 목록 뒤에 붙입니다.
    ///
    /// 실패하면 아무것도 바꾸지 않습니다. 그러면 다음 요청에서 같은 구간을 다시 시도하고,
    /// 그때까지는 그 구간이 원문으로 나가므로 대화에는 영향이 없습니다.
    private func appendDigestSegment(roomId: UUID, pending: ConversationCompactor.PendingSegment, apiKey: String) async {
        guard !summarizingRooms.contains(roomId) else { return }
        summarizingRooms.insert(roomId)
        defer { summarizingRooms.remove(roomId) }

        // 그 사이 다른 요청이 같은 구간을 이미 채웠을 수 있습니다.
        let current = await MainActor.run { ChatRoomManager.shared.loadDigestForRoom(roomId: roomId) }
        guard current.coveredTurns < pending.lastTurn else { return }

        guard let text = try? await requestSegmentSummary(
            turns: pending.turns, startingTurn: pending.firstTurn, apiKey: apiKey),
              !text.isEmpty else { return }

        let updated = ConversationDigest(segments: current.segments + [
            ConversationSegment(firstTurn: pending.firstTurn, lastTurn: pending.lastTurn, text: text)
        ])
        await MainActor.run {
            ChatRoomManager.shared.saveDigestForRoom(roomId: roomId, digest: updated)
        }
    }

    private func requestSegmentSummary(turns: [ConversationTurn], startingTurn: Int, apiKey: String) async throws -> String {
        let transcript = ConversationCompactor.transcript(for: turns, startingTurn: startingTurn)
        guard !transcript.isEmpty else { return "" }

        let userText = "다음은 정리할 대화 구간이다.\n\n" + transcript
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": ConversationCompactor.summaryInstruction]]],
            "contents": [["role": "user", "parts": [["text": userText]]]],
            "generationConfig": [
                // 지시한 분량보다 넉넉히 잡습니다. 3.7은 사고 토큰도 이 예산에서 함께 쓰고,
                // 모자라면 문장 한가운데서 잘린 글이 나옵니다.
                "maxOutputTokens": ConversationCompactor.segmentTokenBudget + 1200,
                "thinkingConfig": ["thinkingLevel": "low"]
            ]
        ]

        let json = try await postGemini(body: body, apiKey: apiKey, model: AIModel.gemini37Flash)
        guard let candidates = json["candidates"] as? [[String: Any]],
              let candidate = candidates.first,
              let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
            return ""
        }

        // 잘린 요약은 저장하지 않습니다. 한 번 넣으면 고치지 않는 기록이라
        // 중간에서 끊긴 글이 그 구간의 기억으로 영영 남습니다.
        // 빈 값을 돌려주면 다음 요청에서 같은 구간을 다시 시도합니다.
        if let reason = candidate["finishReason"] as? String, reason != "STOP" {
            return ""
        }

        return parts.compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendGeminiRequest(
        conversation: [ConversationTurn],
        botName: String,
        roomId: UUID?,
        persona: PersonaStyle? = nil,
        onBubble: (@Sendable (GeneratedMessageBubble) async -> Void)? = nil
    ) async throws -> String {
        let model = AIModel.gemini37Flash
        guard let apiKey = KeychainStore.geminiAPIKey else {
            throw serviceError("설정에서 Gemini API 키를 먼저 등록해주세요.")
        }

        // 대화가 아주 길어진 방에서는 앞부분을 구간 요약으로 갈아끼웁니다.
        // 기준에 못 미치면 plan이 원본을 그대로 돌려주므로 짧은 방은 지금까지와 똑같이 동작합니다.
        let digest = roomId.map { ChatRoomManager.shared.loadDigestForRoom(roomId: $0) }
        let plan = ConversationCompactor.plan(conversation: conversation, digest: digest)

        var contents = buildGeminiContents(plan.verbatimTurns)
        if let digestText = plan.digestText {
            contents = digestPreamble(digestText) + contents
        }
        let system = systemPrompt(botName: botName, persona: persona)

        var reusedCache = roomId.flatMap { usablePrefixCache(for: $0, contents: contents, system: system) }

        // 흘려보낼 곳이 있으면 스트리밍으로, 없으면 지금까지처럼 한 번에 받습니다.
        // 스트림은 완성된 문단만 통과시키므로 화면에 깨진 수식이 뜨지 않습니다.
        func run(cache: PrefixCache?) async throws -> (text: String, finishReason: String?, usage: [String: Any]) {
            guard let onBubble else {
                let json = try await performGeminiRequest(
                    contents: contents, system: system, cache: cache, apiKey: apiKey, model: model
                )
                let candidate = (json["candidates"] as? [[String: Any]])?.first
                let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                return (
                    parts.compactMap { $0["text"] as? String }.joined(separator: "\n"),
                    candidate?["finishReason"] as? String,
                    json["usageMetadata"] as? [String: Any] ?? [:]
                )
            }
            let buffer = StreamBubbleSink(botName: botName, onBubble: onBubble) { [weak self] paragraph in
                guard let self else { return [] }
                return await self.parseResponseIntoBubbles(rawText: paragraph, botName: botName)
            }
            let outcome = try await streamGeminiRequest(
                contents: contents, system: system, cache: cache, apiKey: apiKey, model: model
            ) { piece in
                await buffer.consume(piece)
            }
            await buffer.finish()
            return (outcome.text, outcome.finishReason, outcome.usage)
        }

        var result: (text: String, finishReason: String?, usage: [String: Any])
        do {
            result = try await run(cache: reusedCache)
        } catch {
            // 캐시가 서버에서 이미 만료·삭제되었으면 캐시 없이 한 번만 다시 보냅니다.
            // 이미 말풍선을 내보낸 뒤라면 다시 보낼 수 없으므로 그대로 올립니다.
            guard reusedCache != nil, onBubble == nil else { throw error }
            if let roomId { prefixCaches[roomId] = nil }
            reusedCache = nil
            result = try await run(cache: nil)
        }

        if !result.usage.isEmpty, let roomId {
            let usage = result.usage
            let input = intValue(usage["promptTokenCount"])
            let output = intValue(usage["candidatesTokenCount"]) + intValue(usage["thoughtsTokenCount"])
            let cached = intValue(usage["cachedContentTokenCount"])
            await MainActor.run {
                TokenUsageManager.shared.recordUsage(
                    roomId: roomId,
                    model: model,
                    inputTokens: input,
                    outputTokens: output,
                    cachedInputTokens: cached
                )
            }
        }

        let text = result.text
        guard !text.isEmpty else {
            // 답변이 비었을 때 "왜" 비었는지가 3.7에서는 대부분 finishReason에 담겨 옵니다.
            throw serviceError(geminiEmptyResponseMessage(finishReason: result.finishReason))
        }

        // 캐시에는 "방금 실제로 보낸 contents"를 그대로 올립니다.
        // 답변까지 덧붙여 캐시하면 적중률이 몇 %p 높지만, 앱이 다음 턴에 재구성하는 문자열과
        // 한 글자라도 어긋나면 지문 검사에서 통째로 탈락합니다. 보낸 것을 그대로 캐시하면
        // 다음 요청의 앞부분과 반드시 일치하므로, 답변+새 질문 두 턴만 캐시 밖에 남습니다.
        // 답변을 이미 확보한 뒤이므로 화면 표시를 막지 않도록 백그라운드에서 진행합니다.
        if let roomId {
            Task { await self.refreshPrefixCache(roomId: roomId, contents: contents, system: system, apiKey: apiKey) }
        }

        // 요약도 답변을 다 받은 뒤에 만듭니다. 보내기 전에 만들면 그 몇 초가 고스란히 응답 지연이 됩니다.
        if let roomId, let pending = plan.pending {
            Task { await self.appendDigestSegment(roomId: roomId, pending: pending, apiKey: apiKey) }
        }
        return text
    }

    /// 요약을 대화 맨 앞에 놓습니다. Gemini는 첫 턴이 user여야 해서 model 턴으로 한 번 받아 줍니다.
    private func digestPreamble(_ text: String) -> [[String: Any]] {
        [
            ["role": "user", "parts": [["text": text]]],
            ["role": "model", "parts": [["text": "이전 대화 요약을 확인했습니다. 이어서 진행하겠습니다."]]]
        ]
    }

    /// 스트림 한 건의 결과입니다. 사용량과 종료 사유는 마지막 청크에 들어옵니다.
    struct StreamOutcome {
        var text = ""
        var finishReason: String?
        var usage: [String: Any] = [:]
    }

    /// `streamGenerateContent`로 받아 도착하는 대로 흘려보냅니다.
    ///
    /// 완성된 말풍선을 만드는 판단은 `StreamingBubbleBuffer`가 합니다. 여기서는
    /// 서버가 준 조각을 그대로 넘길 뿐이라, 청크가 어디서 끊기든 상관하지 않습니다.
    private func streamGeminiRequest(
        contents: [[String: Any]],
        system: String,
        cache: PrefixCache?,
        apiKey: String,
        model: AIModel,
        onText: @Sendable (String) async -> Void
    ) async throws -> StreamOutcome {
        guard let url = URL(string:
            "\(Self.geminiBaseURL)/models/\(model.rawValue):streamGenerateContent?alt=sse") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(
            withJSONObject: streamBody(contents: contents, system: system, cache: cache))

        let (bytes, response) = try await resilientSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw serviceError("Gemini 응답을 읽을 수 없습니다.")
        }
        guard (200...299).contains(http.statusCode) else {
            // 오류 본문도 스트림으로 오므로 모아서 기존 해석기에 넘깁니다.
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            _ = try validatedJSON(data: raw, response: response, provider: "Gemini")
            throw serviceError("Gemini 요청이 \(http.statusCode) 상태로 끝났습니다.")
        }

        var outcome = StreamOutcome()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let usage = json["usageMetadata"] as? [String: Any] { outcome.usage = usage }
            guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { continue }
            if let reason = candidate["finishReason"] as? String { outcome.finishReason = reason }

            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            let piece = parts.compactMap { $0["text"] as? String }.joined()
            guard !piece.isEmpty else { continue }
            outcome.text += piece
            await onText(piece)
        }
        return outcome
    }

    private func streamBody(contents: [[String: Any]], system: String, cache: PrefixCache?) -> [String: Any] {
        var body: [String: Any] = [
            "generationConfig": [
                "maxOutputTokens": Self.geminiMaxOutputTokens,
                "thinkingConfig": ["thinkingLevel": "medium"]
            ]
        ]
        if let cache {
            body["cachedContent"] = cache.name
            body["contents"] = Array(contents.dropFirst(cache.coveredTurns))
        } else {
            body["systemInstruction"] = ["parts": [["text": system]]]
            body["contents"] = contents
        }
        return body
    }

    private func performGeminiRequest(
        contents: [[String: Any]],
        system: String,
        cache: PrefixCache?,
        apiKey: String,
        model: AIModel
    ) async throws -> [String: Any] {
        guard let url = URL(string: "\(Self.geminiBaseURL)/models/\(model.rawValue):generateContent") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 키를 쿼리 문자열에 붙이면 URL이 남는 곳마다 그대로 노출되므로 헤더로 보냅니다.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 60

        // Gemini 3.x는 temperature·topP·topK·candidateCount를 받지 않고,
        // 사고량은 thinking_budget 숫자가 아니라 thinkingLevel 문자열(low/medium/high)로 지정합니다.
        var body: [String: Any] = [
            "generationConfig": [
                "maxOutputTokens": Self.geminiMaxOutputTokens,
                "thinkingConfig": ["thinkingLevel": "medium"]
            ]
        ]
        if let cache {
            // 캐시에 시스템 지침과 앞부분 대화가 들어 있으므로 남은 턴만 보냅니다.
            // 이때 systemInstruction을 함께 보내면 요청이 거부됩니다.
            body["cachedContent"] = cache.name
            body["contents"] = Array(contents.dropFirst(cache.coveredTurns))
        } else {
            body["systemInstruction"] = ["parts": [["text": system]]]
            body["contents"] = contents
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        return try validatedJSON(data: data, response: response, provider: "Gemini")
    }

    private func usablePrefixCache(for roomId: UUID, contents: [[String: Any]], system: String) -> PrefixCache? {
        guard let cache = prefixCaches[roomId] else { return nil }
        guard cache.expiresAt > Date().addingTimeInterval(30) else {
            prefixCaches[roomId] = nil
            return nil
        }
        // 캐시가 덮는 만큼의 턴이 남아 있고, 그 구간이 편집되지 않았을 때만 재사용합니다.
        guard contents.count > cache.coveredTurns else { return nil }
        guard fingerprint(Array(contents.prefix(cache.coveredTurns)), system: system) == cache.fingerprint else {
            prefixCaches[roomId] = nil
            return nil
        }
        return cache
    }

    private func refreshPrefixCache(roomId: UUID, contents: [[String: Any]], system: String, apiKey: String) async {
        // 갱신 도중에는 URL 요청에서 액터가 풀리므로, 막지 않으면 같은 방에 대해
        // 갱신이 겹치면서 캐시가 여러 개 만들어지고 이전 것이 지워지지 않습니다.
        guard !refreshingRooms.contains(roomId) else { return }
        refreshingRooms.insert(roomId)
        defer { refreshingRooms.remove(roomId) }

        // 이미 같은 구간을 덮는 캐시가 있으면 다시 만들 필요가 없습니다.
        if let existing = prefixCaches[roomId],
           existing.coveredTurns >= contents.count,
           existing.expiresAt > Date().addingTimeInterval(60) {
            return
        }

        // 사진도 함께 셉니다. 글자만 세던 시절에는 사진이 0자로 잡혀서,
        // 사진이 많아 제일 비싼 방이 바로 그 이유로 캐시를 못 받았습니다.
        let estimatedTokens = TokenEstimator.estimatedTokens(contents: contents)
            + TokenEstimator.textTokens(system)
        guard estimatedTokens >= Self.minimumCacheTokens else { return }

        let previous = prefixCaches[roomId]
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

        prefixCaches[roomId] = PrefixCache(
            name: name,
            coveredTurns: contents.count,
            fingerprint: fingerprint(contents, system: system),
            expiresAt: Date().addingTimeInterval(TimeInterval(Self.cacheTTLSeconds))
        )

        // 캐시는 올려둔 토큰 수 × 보관 시간으로 요금이 매겨집니다.
        // 이전 캐시를 바로 지우므로 실제 보관 시간은 다음 갱신까지지만,
        // 최악의 경우인 TTL 전체를 기준으로 잡아 요금을 과소 표시하지 않습니다.
        if let cachedTokens = (json["usageMetadata"] as? [String: Any])?["totalTokenCount"] as? Int {
            let tokenHours = Double(cachedTokens) * (Double(Self.cacheTTLSeconds) / 3600.0)
            await MainActor.run {
                TokenUsageManager.shared.recordCacheStorage(
                    roomId: roomId,
                    model: .gemini37Flash,
                    tokenHours: tokenHours
                )
            }
        }

        // 이전 캐시는 보관 요금이 붙으므로 새 캐시가 자리 잡은 뒤 지웁니다.
        if let previous { await deleteCache(named: previous.name, apiKey: apiKey) }
    }

    private func deleteCache(named name: String, apiKey: String) async {
        guard let url = URL(string: "\(Self.geminiBaseURL)/\(name)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 15
        _ = try? await URLSession.shared.data(for: request)
    }

    private func fingerprint(_ contents: [[String: Any]], system: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(system.utf8))
        for item in contents {
            guard let data = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) else { continue }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func geminiEmptyResponseMessage(finishReason: String?) -> String {
        switch finishReason {
        case "MAX_TOKENS":
            return "답변이 출력 토큰 한도에 먼저 걸렸습니다. 질문을 나눠서 다시 보내주세요."
        case "SAFETY", "PROHIBITED_CONTENT":
            return "Gemini 안전 정책에 걸려 답변이 생성되지 않았습니다. 표현을 바꿔 다시 시도해주세요."
        case "RECITATION":
            return "저작권 보호 정책 때문에 답변이 중단되었습니다. 질문을 다르게 표현해주세요."
        case let reason?:
            return "Gemini가 빈 응답을 반환했습니다. (사유: \(reason))"
        case nil:
            return "Gemini가 빈 응답을 반환했습니다."
        }
    }

    private func sendOpenAIRequest(conversation: [ConversationTurn], botName: String, roomId: UUID?, persona: PersonaStyle? = nil) async throws -> String {
        guard let apiKey = KeychainStore.openAIAPIKey else {
            throw serviceError("설정에서 OpenAI API 키를 먼저 등록해주세요.")
        }
        guard let url = URL(string: "https://api.openai.com/v1/responses") else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Client-Request-Id")
        // 생성은 서버에서 계속 진행시키고, 앱은 짧은 조회 요청으로 완료 여부를 확인합니다.
        // 긴 수학 답변 도중 연결이 한 번 끊겨도 같은 응답을 다시 조회할 수 있습니다.
        request.timeoutInterval = 60

        let cacheKey = "kakao-sapiens-room-\(roomId?.uuidString ?? "default")"
        let body: [String: Any] = [
            "model": AIModel.gpt56Luna.rawValue,
            "instructions": systemPrompt(botName: botName, persona: persona),
            "input": buildOpenAIInput(conversation),
            "prompt_cache_key": cacheKey,
            // 대화가 뒤에 계속 추가되는 메신저에는 implicit 경계가 가장 잘 맞습니다.
            // 이전 사용자 턴까지의 동일한 접두사를 읽고 최신 턴을 다음 요청용으로 기록합니다.
            "prompt_cache_options": ["mode": "implicit", "ttl": "30m"],
            "reasoning": ["effort": "medium", "context": "all_turns"],
            "text": ["verbosity": "medium"],
            "max_output_tokens": 4096,
            "safety_identifier": "kakao-sapiens-local-user",
            "background": true,
            "store": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let initialJSON: [String: Any]
        do {
            // OpenAI 공식 SDK와 같은 범위로 연결 오류·408·409·429·5xx를 최대 2회 재시도합니다.
            // background 요청이라 재시도 성공 후에는 응답 ID 하나만 추적합니다.
            initialJSON = try await openAIJSON(request: request, maxRetries: 2)
        } catch let error as URLError where isTransientNetworkError(error) {
            throw serviceError("네트워크 연결이 불안정해 3회 재시도했지만 요청을 시작하지 못했습니다. 연결을 확인한 뒤 다시 보내주세요.")
        }
        let json = try await waitForOpenAIResponse(initialJSON, apiKey: apiKey)

        if let usage = json["usage"] as? [String: Any], let roomId {
            let input = intValue(usage["input_tokens"])
            let output = intValue(usage["output_tokens"])
            let details = usage["input_tokens_details"] as? [String: Any]
            let cached = intValue(details?["cached_tokens"])
            let writes = intValue(details?["cache_write_tokens"])
            await MainActor.run {
                TokenUsageManager.shared.recordUsage(
                    roomId: roomId,
                    model: .gpt56Luna,
                    inputTokens: input,
                    outputTokens: output,
                    cachedInputTokens: cached,
                    cacheWriteTokens: writes
                )
            }
        }

        if let direct = json["output_text"] as? String, !direct.isEmpty { return direct }
        if let output = json["output"] as? [[String: Any]] {
            let text = output.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
                .compactMap { item -> String? in
                    guard (item["type"] as? String) == "output_text" else { return nil }
                    return item["text"] as? String
                }
                .joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        throw serviceError("OpenAI 응답 형식을 읽을 수 없습니다.")
    }

    private func waitForOpenAIResponse(_ initialJSON: [String: Any], apiKey: String) async throws -> [String: Any] {
        var json = initialJSON
        guard let responseID = json["id"] as? String, !responseID.isEmpty else {
            throw serviceError("OpenAI 응답 ID를 읽을 수 없습니다.")
        }

        // 약 4분 동안 기다립니다. 조회 연결이 잠깐 끊기면 생성을 다시 시작하지 않고
        // 같은 response ID를 재조회하므로 중복 응답 및 중복 과금을 피합니다.
        for attempt in 0..<160 {
            try Task.checkCancellation()
            let status = json["status"] as? String ?? ""
            if status == "completed" { return json }
            if status == "failed" || status == "cancelled" || status == "incomplete" {
                throw serviceError(openAIStatusMessage(json, status: status))
            }

            if attempt > 0 || status == "queued" || status == "in_progress" {
                try await Task.sleep(for: .milliseconds(1500))
            }

            do {
                guard let url = URL(string: "https://api.openai.com/v1/responses/\(responseID)") else {
                    throw URLError(.badURL)
                }
                var pollRequest = URLRequest(url: url)
                pollRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                pollRequest.setValue(UUID().uuidString, forHTTPHeaderField: "X-Client-Request-Id")
                pollRequest.timeoutInterval = 20
                json = try await openAIJSON(request: pollRequest, maxRetries: 2)
            } catch let error as URLError where isTransientNetworkError(error) {
                // 다음 반복에서 같은 ID를 다시 조회합니다.
                continue
            }
        }
        throw serviceError("OpenAI 응답 생성 시간이 너무 오래 걸립니다. 잠시 후 다시 시도해주세요.")
    }

    private func openAIJSON(request: URLRequest, maxRetries: Int) async throws -> [String: Any] {
        var lastError: Error?

        for attempt in 0...maxRetries {
            try Task.checkCancellation()
            do {
                let (data, response) = try await resilientSession.data(for: request)
                if let http = response as? HTTPURLResponse,
                   isRetryableOpenAIStatus(http.statusCode),
                   attempt < maxRetries {
                    let delay = retryDelay(attempt: attempt, response: http)
                    try await Task.sleep(for: .milliseconds(delay))
                    continue
                }
                return try validatedJSON(data: data, response: response, provider: "OpenAI")
            } catch let error as URLError where isTransientNetworkError(error) {
                lastError = error
                guard attempt < maxRetries else { throw error }
                try await Task.sleep(for: .milliseconds(retryDelay(attempt: attempt, response: nil)))
            } catch {
                throw error
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    private func isRetryableOpenAIStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 409 || statusCode == 429 || statusCode >= 500
    }

    private func retryDelay(attempt: Int, response: HTTPURLResponse?) -> Int {
        if let value = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(value), seconds > 0, seconds <= 60 {
            return Int(seconds * 1000)
        }
        // 0.6초 → 1.2초의 짧고 제한된 지수 백오프와 작은 지터입니다.
        let base = 600 * (1 << min(attempt, 4))
        return base + Int.random(in: 0...180)
    }

    private func isTransientNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .notConnectedToInternet, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private func openAIStatusMessage(_ json: [String: Any], status: String) -> String {
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return "OpenAI 오류: \(message)"
        }
        if let details = json["incomplete_details"] as? [String: Any],
           let reason = details["reason"] as? String, !reason.isEmpty {
            return "OpenAI 응답이 완료되지 않았습니다: \(reason)"
        }
        return "OpenAI 응답이 \(status) 상태로 종료되었습니다."
    }

    private func buildGeminiContents(_ conversation: [ConversationTurn]) -> [[String: Any]] {
        conversation.compactMap { turn in
            guard !turn.text.hasPrefix("요청을 처리하는 중 오류가 발생했습니다:") else { return nil }
            var parts: [[String: Any]] = []
            if !turn.text.isEmpty { parts.append(["text": turn.text]) }
            if turn.sender == .user, let attachment = turn.attachment {
                if attachment.type == .image || attachment.mimeType.hasPrefix("image/") || attachment.mimeType == "application/pdf" {
                    parts.append(["inlineData": ["mimeType": attachment.mimeType, "data": attachment.dataBase64]])
                } else if let data = Data(base64Encoded: attachment.dataBase64), let text = String(data: data, encoding: .utf8) {
                    parts.append(["text": "첨부파일 \(attachment.fileName):\n\(text)"])
                }
            }
            // Gemini 3.x는 마지막 user 턴에 텍스트 파트가 있어야 합니다.
            // 설명 없이 사진만 올린 경우를 대비해 기본 지시문을 앞에 넣습니다.
            if turn.sender == .user, turn.text.isEmpty, !parts.isEmpty {
                parts.insert(["text": "첨부한 문제를 풀어주세요."], at: 0)
            }
            guard !parts.isEmpty else { return nil }
            return ["role": turn.sender == .user ? "user" : "model", "parts": parts]
        }
    }

    private func buildOpenAIInput(_ conversation: [ConversationTurn]) -> [[String: Any]] {
        conversation.compactMap { turn in
            if turn.sender == .sapiens {
                // Responses API에서 assistant의 구조화 콘텐츠는 output_text/refusal만 허용됩니다.
                // 간단한 문자열 형식을 사용하면 API가 역할에 맞는 타입으로 변환합니다.
                // 화면에 남아 있는 과거 전송 오류는 대화 컨텍스트와 캐시 접두사에 포함하지 않습니다.
                guard !turn.text.isEmpty,
                      !turn.text.hasPrefix("요청을 처리하는 중 오류가 발생했습니다:") else { return nil }
                return ["role": "assistant", "content": turn.text]
            }

            var text = turn.text
            if let attachment = turn.attachment,
               attachment.type != .image,
               let data = Data(base64Encoded: attachment.dataBase64),
               let attachmentText = String(data: data, encoding: .utf8) {
                if !text.isEmpty { text += "\n\n" }
                text += "첨부파일 \(attachment.fileName):\n\(attachmentText)"
            }

            var content: [[String: Any]] = []
            if !text.isEmpty { content.append(["type": "input_text", "text": text]) }

            if let attachment = turn.attachment, attachment.type == .image {
                content.append([
                    "type": "input_image",
                    "image_url": "data:\(attachment.mimeType);base64,\(attachment.dataBase64)",
                    "detail": "auto"
                ])
            }

            guard !content.isEmpty else { return nil }
            return ["role": "user", "content": content]
        }
    }

    private func validatedJSON(data: Data, response: URLResponse, provider: String) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = parsed?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "HTTP \(http.statusCode)"
            throw serviceError("\(provider) 오류: \(message)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw serviceError("\(provider) 응답이 JSON 형식이 아닙니다.")
        }
        return json
    }

    private func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    private func serviceError(_ message: String) -> NSError {
        NSError(domain: "KakaoSapiens.AIService", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func parseResponseIntoBubbles(rawText: String, botName: String) -> [GeneratedMessageBubble] {
        let cleanText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        var paragraphs = cleanText.components(separatedBy: "\n\n")
        if paragraphs.count == 1 {
            let lines = cleanText.components(separatedBy: "\n")
            if lines.contains(where: { $0.hasPrefix("\(botName):") || $0.hasPrefix("사피엔스:") }) { paragraphs = lines }
        }

        var chunks: [String] = []
        for paragraph in paragraphs { chunks.append(contentsOf: splitTextAndComplexMath(paragraph: paragraph)) }
        var bubbles: [GeneratedMessageBubble] = []
        for item in chunks {
            var text = item.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["\(botName):", "\(botName) :", "사피엔스:"] where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            let (cleanedText, allSpecs) = MathGraphRenderer.extractGraphSpecs(from: text)
            if !cleanedText.isEmpty { bubbles.append(GeneratedMessageBubble(text: cleanedText)) }
            // 해석하지 못하는 식은 그래프를 만들지 않습니다. 틀린 그림을 내보내는 것보다 낫습니다.
            let specs = allSpecs.filter { MathGraphRenderer.canRender($0) }
            for spec in specs {
                let image = MathGraphRenderer.shared.renderGraph(spec: spec)
                if let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                    bubbles.append(GeneratedMessageBubble(
                        text: "",
                        attachment: ChatAttachment(
                            type: .image,
                            fileName: "\(spec.title).jpg",
                            fileSize: Int64(jpeg.count),
                            fileExtension: "jpg",
                            dataBase64: jpeg.base64EncodedString(),
                            mimeType: "image/jpeg"
                        )
                    ))
                }
            }
        }
        if bubbles.isEmpty && !cleanText.isEmpty { bubbles.append(GeneratedMessageBubble(text: cleanText)) }
        return bubbles
    }

    private func splitTextAndComplexMath(paragraph: String) -> [String] {
        let lines = paragraph.components(separatedBy: "\n")
        guard lines.count > 1 else { return [paragraph] }
        var result: [String] = []
        var buffer: [String] = []
        var mathMode: Bool?
        var displayMathClosingDelimiter: String?

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            result.append(buffer.joined(separator: "\n"))
            buffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let closing = displayMathClosingDelimiter {
                buffer.append(trimmed)
                if trimmed == closing {
                    flushBuffer()
                    displayMathClosingDelimiter = nil
                    mathMode = nil
                }
                continue
            }

            if trimmed == "$$" || trimmed == "\\[" {
                flushBuffer()
                mathMode = true
                displayMathClosingDelimiter = trimmed == "$$" ? "$$" : "\\]"
                buffer.append(trimmed)
                continue
            }

            let isMath = isStandaloneMathLine(trimmed)
            if let mode = mathMode, mode != isMath {
                flushBuffer()
            }
            mathMode = isMath
            buffer.append(trimmed)
        }
        flushBuffer()
        return result.isEmpty ? [paragraph] : result
    }

    private func isStandaloneMathLine(_ line: String) -> Bool {
        if line.hasPrefix("$$") || line.hasPrefix("\\[") { return true }
        if line.hasPrefix("$") && line.hasSuffix("$") && line.contains("=") { return true }
        if line.contains("=") && ["\\frac", "\\cos", "\\sin", "\\int", "\\lim"].contains(where: line.contains) {
            let korean = line.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
            return korean <= 3
        }
        return false
    }
}
