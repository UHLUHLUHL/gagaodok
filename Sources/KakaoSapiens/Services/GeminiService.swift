import Foundation
import AppKit
import CryptoKit

public struct GeneratedMessageBubble {
    public let text: String
    public let attachment: ChatAttachment?
    public let kind: MessageKind

    public init(text: String, attachment: ChatAttachment? = nil, kind: MessageKind = .speech) {
        self.text = text
        self.attachment = attachment
        self.kind = kind
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
    private let makeBubbles: @Sendable (String, Bool) async -> [GeneratedMessageBubble]

    /// 이 턴이 상황극이라고 이미 아는지.
    ///
    /// 문단은 완성되는 대로 화면에 붙기 때문에, 첫 문단을 붙일 때는 뒤에 따옴표 대사가
    /// 나올지 알 수 없습니다. 그래서 지난 턴에서 얻은 값으로 시작합니다.
    /// 상황극을 처음 시작하는 턴에서만, 첫 대사가 나오기 전의 묘사가 대사 말풍선으로
    /// 나옵니다. 그 다음 턴부터는 앞 턴이 근거가 되어 첫 문단부터 제대로 갈립니다.
    private var roleplayEstablished: Bool

    public init(
        botName: String,
        roleplayEstablished: Bool = false,
        onBubble: @escaping @Sendable (GeneratedMessageBubble) async -> Void,
        makeBubbles: @escaping @Sendable (String, Bool) async -> [GeneratedMessageBubble]
    ) {
        self.botName = botName
        self.roleplayEstablished = roleplayEstablished
        self.onBubble = onBubble
        self.makeBubbles = makeBubbles
    }

    public func consume(_ piece: String) async {
        for paragraph in buffer.append(piece) { await handle(paragraph) }
    }

    public func finish() async {
        let rest = buffer.flush()
        guard !rest.isEmpty else { return }
        await handle(rest)
    }

    private func handle(_ paragraph: String) async {
        if RoleplayParser.establishesRoleplay(paragraph) { roleplayEstablished = true }
        for bubble in await makeBubbles(paragraph, roleplayEstablished) { await onBubble(bubble) }
    }
}

/// 전송 계층이 만든 오류에서 "다시 보낼 값어치가 있는지"를 읽습니다.
///
/// 화면 쪽은 실패해도 사용자에게 알리기 전에 조용히 두 번 더 보냅니다. 그런데
/// 키가 틀렸거나(401) 요청이 잘못됐거나(400) 안전 필터에 걸린 요청은 몇 번을 보내도
/// 똑같이 실패합니다. 그 두 번은 **화면에 아무것도 남기지 않으면서 요금만 세 배로 냅니다.**
public enum AIServiceError {
    static let domain = "KakaoSapiens.AIService"
    static let retryableKey = "retryable"

    /// 그대로 다시 보내면 될 만한 상태 코드인지입니다.
    ///
    /// 429는 잠깐 몰린 것이고 5xx는 저쪽 사정이라 다시 보낼 값어치가 있습니다.
    /// 400·401·403은 요청이나 키가 잘못된 것이라 몇 번을 보내도 같습니다.
    public static func retryable(_ statusCode: Int) -> Bool {
        statusCode == 429 || statusCode >= 500
    }

    /// 이 오류를 다시 보내도 되는지입니다.
    ///
    /// 우리가 만든 오류가 아니면 참입니다. 그쪽은 대부분 네트워크가 잠깐 끊긴 경우라
    /// 다시 보내는 것이 맞습니다.
    public static func isRetryable(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == domain else { return true }
        return nsError.userInfo[retryableKey] as? Bool ?? false
    }
}

public actor GeminiService {
    public static let shared = GeminiService()

    private let resilientSession: URLSession

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
        persona: PersonaStyle? = nil,
        mode: ChatMode = .mathMentor,
        roleplayInProgress: Bool = false
    ) async throws -> GeneratedAIResponse {
        let model = await MainActor.run { requestedModel ?? ModelSelectionManager.shared.selectedModel }
        let rawText: String
        switch model {
        case .gemini37Flash:
            rawText = try await sendGeminiRequest(
                conversation: conversation, botName: botName, roomId: roomId, persona: persona, mode: mode
            )
        case .gpt56Luna:
            rawText = try await sendOpenAIRequest(
                conversation: conversation, botName: botName, roomId: roomId, persona: persona, mode: mode
            )
        }
        return GeneratedAIResponse(
            rawText: rawText,
            bubbles: parseResponseIntoBubbles(
                rawText: rawText, botName: botName,
                roleplay: mode == .companion && roleplayInProgress
            )
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
        mode: ChatMode = .mathMentor,
        roleplayInProgress: Bool = false,
        onBubble: @Sendable @escaping (GeneratedMessageBubble) async -> Void
    ) async throws -> String {
        let model = await MainActor.run { requestedModel ?? ModelSelectionManager.shared.selectedModel }
        guard model == .gemini37Flash else {
            let response = try await generateResponse(
                conversation: conversation, botName: botName, roomId: roomId,
                model: model, persona: persona, mode: mode, roleplayInProgress: roleplayInProgress
            )
            for bubble in response.bubbles { await onBubble(bubble) }
            return response.rawText
        }
        return try await sendGeminiRequest(
            conversation: conversation, botName: botName, roomId: roomId, persona: persona,
            mode: mode, roleplayInProgress: roleplayInProgress, onBubble: onBubble
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
    /// - Parameter onProgress: 지금 무엇이 도착했는지를 알려 줍니다.
    ///   자세한 것은 `lookupProgressLabel(_:)`에 적었습니다.
    public func lookupPersona(
        query: String,
        roomId: UUID,
        imageBase64: String? = nil,
        imageMimeType: String? = nil,
        onProgress: @Sendable @escaping (String) async -> Void = { _ in }
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

        await onProgress("자료를 찾고 있습니다…")
        let result = try await streamGeminiText(body: body, apiKey: apiKey, roomId: roomId) { soFar in
            await onProgress(Self.lookupProgressLabel(soFar))
        }
        guard !result.text.isEmpty else {
            throw serviceError(geminiEmptyResponseMessage(finishReason: result.finishReason))
        }
        return Self.parsePersonaLookup(result.text, sources: result.sources)
    }

    private struct TextStreamResult {
        let text: String
        let finishReason: String?
        let sources: [String]
    }

    /// 글 하나를 흘려 받습니다. 대화용 스트림과 달리 말풍선으로 가르지 않습니다.
    ///
    /// 지금은 말투 조사만 씁니다. 오래 걸리는 요청이라, 다 받을 때까지 기다리는 대신
    /// 도착하는 대로 넘겨 화면이 무엇을 하고 있는지 보여줄 수 있게 합니다.
    private func streamGeminiText(
        body: [String: Any],
        apiKey: String,
        roomId: UUID,
        onPartial: @Sendable (String) async -> Void
    ) async throws -> TextStreamResult {
        let model = AIModel.gemini37Flash
        guard let url = URL(string:
            "\(Self.geminiBaseURL)/models/\(model.rawValue):streamGenerateContent?alt=sse") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var text = ""
        var finishReason: String?
        var sources: [String] = []
        var reported: [String: Any] = [:]
        var serverResponded = false

        // 여기서도 빠져나가는 모든 길에서 적습니다. 도중에 끊겨도 서버는 이미 읽었습니다.
        defer {
            let snapshot = reported
            let responded = serverResponded
            Task {
                if !snapshot.isEmpty {
                    await self.recordGeminiUsage(snapshot, roomId: roomId, model: model)
                } else if responded {
                    await self.recordUnreported(roomId: roomId, model: model)
                }
            }
        }

        let (bytes, response) = try await resilientSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw serviceError("Gemini 응답을 읽을 수 없습니다.")
        }
        guard (200...299).contains(http.statusCode) else {
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            _ = try validatedJSON(data: raw, response: response, provider: "Gemini")
            throw serviceError(
                "Gemini 요청이 \(http.statusCode) 상태로 끝났습니다.",
                retryable: AIServiceError.retryable(http.statusCode)
            )
        }

        serverResponded = true
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let usage = json["usageMetadata"] as? [String: Any] { reported = usage }
            guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { continue }
            if let reason = candidate["finishReason"] as? String { finishReason = reason }
            if let grounding = candidate["groundingMetadata"] as? [String: Any],
               let chunks = grounding["groundingChunks"] as? [[String: Any]] {
                for chunk in chunks {
                    guard let title = (chunk["web"] as? [String: Any])?["title"] as? String,
                          !title.isEmpty, !sources.contains(title) else { continue }
                    sources.append(title)
                }
            }

            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            let piece = parts.compactMap { $0["text"] as? String }.joined()
            guard !piece.isEmpty else { continue }
            text += piece
            await onPartial(text)
        }

        return TextStreamResult(text: text, finishReason: finishReason, sources: sources.sorted())
    }

    /// 지금까지 도착한 글을 보고 무슨 일을 하고 있는지 한 줄로 옮깁니다.
    ///
    /// **진행률을 흉내 내지 않습니다.** 이 요청은 오래 걸리는데(검색 → 읽기 → 정리)
    /// 예전에는 "찾는 중" 한 줄만 떠서, 멈춘 것인지 되고 있는 것인지 알 수 없었습니다.
    ///
    /// 답변은 [확신도] → [대사] → [말투] 순서로 나오도록 지침에 적혀 있습니다.
    /// 마지막으로 열린 절이 곧 지금 하고 있는 일입니다. 대사는 몇 줄까지 왔는지
    /// 함께 셉니다 — 숫자가 늘어나는 것이 보여야 멈춘 것이 아님을 알 수 있습니다.
    /// 시간을 재서 지어낸 단계가 아니라 방금 받은 글자가 근거입니다.
    static func lookupProgressLabel(_ soFar: String) -> String {
        if soFar.contains("[말투]") { return "말투 규칙을 적고 있습니다…" }
        if soFar.contains("[대사]") {
            let section = soFar.components(separatedBy: "[대사]").dropFirst().joined()
                .components(separatedBy: "[말투]").first ?? ""
            let lines = section.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            return lines == 0 ? "대사를 모으고 있습니다…" : "대사를 모으고 있습니다… \(lines)줄"
        }
        if soFar.contains("[확신도]") { return "찾은 자료를 살펴보고 있습니다…" }
        return "자료를 찾고 있습니다…"
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
    ///
    /// 모드마다 다르게 묻습니다. 챗봇 방에 "미분이 뭐야"를 던져 놓고 결을 판단할 수는 없습니다.
    /// 멘토는 설명·지적·칭찬에서, 챗봇은 인사·감정·거리감에서 말투가 가장 크게 갈립니다.
    public static func previewPrompts(for mode: ChatMode) -> [(situation: String, message: String)] {
        switch mode {
        case .mathMentor:
            return [
                ("설명할 때", "미분이 뭔지 한두 문장으로 짧게 설명해줘."),
                ("틀렸다고 말할 때", "x²의 미분은 2라고 배웠어. 맞지?"),
                ("칭찬할 때", "고마워! 덕분에 이해했어.")
            ]
        case .companion:
            return [
                ("말 걸었을 때", "야, 뭐해?"),
                ("속마음을 물을 때", "너는 나를 어떻게 생각해?"),
                ("기분이 안 좋을 때", "오늘 진짜 최악이었어. 아무것도 하기 싫다.")
            ]
        }
    }

    /// 저장하기 전에 이 말투가 실제 그 캐릭터 같은지 확인할 수 있도록 짧은 답변을 만듭니다.
    /// 실제 대화와 똑같은 시스템 지침을 쓰므로, 여기서 보이는 결이 채팅방에서도 그대로 나옵니다.
    public func previewPersona(
        roomId: UUID,
        persona: PersonaStyle,
        botName: String,
        message: String,
        mode: ChatMode = .mathMentor
    ) async throws -> String {
        guard let apiKey = KeychainStore.geminiAPIKey else {
            throw serviceError("설정에서 Gemini API 키를 먼저 등록해주세요.")
        }
        var enabled = persona
        enabled.isEnabled = true
        let system = systemPrompt(botName: botName, persona: enabled, mode: mode)

        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": message]]]],
            "generationConfig": [
                "maxOutputTokens": 2048,
                "thinkingConfig": ["thinkingLevel": "low"]
            ]
        ]
        // 미리보기도 실제 대화와 같은 조건이어야 결을 판단할 수 있습니다.
        // 챗봇 방은 대화에서 필터를 내리는데 미리보기만 안 내리면, 여기서만 답이
        // 통째로 잘려 나가고 사용자는 말투가 잘못된 줄 압니다.
        if let safety = mode.geminiSafetySettings { body["safetySettings"] = safety }

        let json = try await postGemini(body: body, apiKey: apiKey, roomId: roomId)
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
        roomId: UUID,
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
        let json = try await postGemini(body: body, apiKey: apiKey, roomId: roomId)
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
    public func analyzePersonaStyle(roomId: UUID, description: String, samples: [String]) async throws -> String {
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

        let json = try await postGemini(body: body, apiKey: apiKey, roomId: roomId)
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
    ///
    /// **여기서 사용량을 함께 적습니다.** 예전에는 대화 답변만 장부에 적히고
    /// 이 길로 나가는 요청 — 구간 요약, 말투 조사, 말투 분석, 다듬기, 미리보기 — 은
    /// 하나도 안 적혔습니다. 말투 조사는 검색 그라운딩까지 켜는 무거운 요청인데
    /// 앱 화면에서는 공짜처럼 보였습니다. 요금이 과소평가되던 가장 큰 이유입니다.
    private func postGemini(body: [String: Any], apiKey: String, roomId: UUID) async throws -> [String: Any] {
        let model = AIModel.gemini37Flash
        guard let url = URL(string: "\(Self.geminiBaseURL)/models/\(model.rawValue):generateContent") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 키를 쿼리 문자열에 붙이면 URL이 남는 곳마다 그대로 노출되므로 헤더로 보냅니다.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await resilientSession.data(for: request)
        } catch {
            // 연결이 끊긴 것이라 서버가 읽었는지 알 수 없습니다. 건수만 남깁니다.
            await recordUnreported(roomId: roomId, model: model)
            throw error
        }

        // 상태 코드가 나쁘면 여기서 던집니다. 재시도할 값어치가 있는지도 함께 담겨 나갑니다.
        //
        // **HTTP 오류는 미보고 건수로 세지 않습니다.** 400·429·5xx는 생성이
        // 시작되기 전에 거절당한 것이라 청구되지 않습니다. 이걸 세면 "요금이
        // 실제보다 적다"는 화면 경고가 부풀어 믿을 수 없게 됩니다.
        let json = try validatedJSON(data: data, response: response, provider: "Gemini")
        await recordGeminiUsage(json["usageMetadata"] as? [String: Any], roomId: roomId, model: model)
        return json
    }

    /// Gemini가 돌려준 `usageMetadata`를 장부에 적습니다. 없으면 건수만 남깁니다.
    private func recordGeminiUsage(_ usage: [String: Any]?, roomId: UUID, model: AIModel) async {
        guard let usage, !usage.isEmpty else {
            await recordUnreported(roomId: roomId, model: model)
            return
        }
        // 검색 그라운딩을 쓰면 도구가 쓴 입력이 따로 옵니다. 이것도 청구됩니다.
        let input = intValue(usage["promptTokenCount"]) + intValue(usage["toolUsePromptTokenCount"])
        // 사고 토큰은 화면에 한 글자도 안 보이지만 출력 단가로 청구됩니다.
        let output = intValue(usage["candidatesTokenCount"]) + intValue(usage["thoughtsTokenCount"])
        let cached = intValue(usage["cachedContentTokenCount"])
        await MainActor.run {
            TokenUsageManager.shared.recordUsage(
                roomId: roomId, model: model,
                inputTokens: input, outputTokens: output, cachedInputTokens: cached
            )
        }
    }

    private func recordUnreported(roomId: UUID, model: AIModel) async {
        await MainActor.run {
            TokenUsageManager.shared.recordUnreportedRequest(roomId: roomId, model: model)
        }
    }

    private func systemPrompt(botName: String, persona: PersonaStyle? = nil, mode: ChatMode = .mathMentor) -> String {
        // 이 고정 접두사는 두 공급자에서 동일하게 재사용됩니다. 방 이름 같은 동적 값은 끝에 둬 캐시 적중률을 높입니다.
        var prompt = mode.stableSystemPrompt
        // 말투는 방마다 고정이라 캐시 접두사 안쪽에 두어도 적중률이 떨어지지 않습니다.
        if let section = persona?.promptSection(botName: botName, mode: mode) {
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
    private struct PrefixCache: Codable {
        let name: String          // cachedContents/xxxx
        let coveredTurns: Int     // 이 캐시가 덮는 contents 앞부분의 개수
        let fingerprint: String   // 덮은 구간이 편집되지 않았는지 확인하는 지문
        let expiresAt: Date
        /// 이 캐시에 올라가 있는 토큰 수입니다. 다시 만들 값어치가 있는지 따질 때 씁니다.
        /// 예전 파일에는 없던 값이라 기본값을 둡니다.
        var tokenCount: Int = 0

        private enum CodingKeys: String, CodingKey {
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
    private static let prefixCacheStoreURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KakaoSapiens", isDirectory: true)
        return base.appendingPathComponent("prefix_caches.json")
    }()

    private var prefixCaches: [UUID: PrefixCache] = GeminiService.loadPrefixCaches() {
        didSet { persistPrefixCaches() }
    }

    private static func loadPrefixCaches() -> [UUID: PrefixCache] {
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

    private func persistPrefixCaches() {
        let snapshot = prefixCaches.reduce(into: [String: PrefixCache]()) { $0[$1.key.uuidString] = $1.value }
        let url = Self.prefixCacheStoreURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
    private var refreshingRooms: Set<UUID> = []
    /// 같은 방의 요약을 두 번 겹쳐 만들지 않도록 막습니다.
    private var summarizingRooms: Set<UUID> = []

    /// 방마다 **직전** 요청 시각입니다. 대화가 이어지는 중인지 보는 데 씁니다.
    ///
    /// 메모리에만 둡니다. 앱을 껐다 켜면 비어 있어서 그 방의 캐시가 한 메시지 늦게
    /// 만들어집니다. 파일로 남길 값어치는 없다고 봤습니다.
    private var lastRequestAt: [UUID: Date] = [:]

    /// 직전 요청 시각을 꺼내면서 지금 시각으로 갱신합니다.
    ///
    /// **읽기 전에** 꺼내야 직전 값이 나옵니다. 읽고 나서 갱신하면 항상 자기 자신을
    /// 보게 되어 "대화 중인지" 판단이 무의미해집니다.
    private func markRequest(_ roomId: UUID) -> Date? {
        let previous = lastRequestAt[roomId]
        lastRequestAt[roomId] = Date()
        return previous
    }

    private static let cacheTTLSeconds = 900
    // 명시적 캐시는 1,024토큰 미만이면 생성이 거부됩니다. 어림값이 실제보다 조금 클 수 있으므로
    // 여유를 둡니다. 그래도 거부되면 캐시 없이 그냥 진행하므로 대화에는 영향이 없습니다.
    private static let minimumCacheTokens = 1200

    // 캐시를 다시 만들 기준입니다. 자세한 셈은 `refreshPrefixCache`에 적었습니다.
    // 짧은 대화에서 몇 마디 붙었다고 다시 만들지 않게 하는 바닥값입니다. **정한 값입니다.**
    private static let cacheRefreshMinTailTokens = 2000

    // TTL이 이만큼도 안 남았으면 꼬리가 짧아도 새로 만듭니다. 그대로 두면
    // 곧 만료되어 다음 요청이 통째로 전액이 됩니다.
    private static let cacheRefreshTTLFloor: TimeInterval = 240

    // 직전 요청이 이 안에 있었으면 "대화 중"으로 봅니다. 그때만 첫 캐시를 만듭니다.
    // **정한 값입니다.** 실제 사용 기록을 보고 뽑은 값이 아닙니다.
    private static let cacheBurstWindow: TimeInterval = 300

    /// 한 구간을 요약해 방의 요약 목록 뒤에 붙입니다.
    ///
    /// 실패하면 아무것도 바꾸지 않습니다. 그러면 다음 요청에서 같은 구간을 다시 시도하고,
    /// 그때까지는 그 구간이 원문으로 나가므로 대화에는 영향이 없습니다.
    private func appendDigestSegment(
        roomId: UUID,
        pending: ConversationCompactor.PendingSegment,
        mode: ChatMode,
        apiKey: String
    ) async {
        guard !summarizingRooms.contains(roomId) else { return }
        summarizingRooms.insert(roomId)
        defer { summarizingRooms.remove(roomId) }

        // 그 사이 다른 요청이 같은 구간을 이미 채웠을 수 있습니다.
        let current = await MainActor.run { ChatRoomManager.shared.loadDigestForRoom(roomId: roomId) }
        guard current.coveredTurns < pending.lastTurn else { return }

        guard let text = try? await requestSegmentSummary(
            roomId: roomId, turns: pending.turns, startingTurn: pending.firstTurn,
            mode: mode, apiKey: apiKey),
              !text.isEmpty else { return }

        let updated = ConversationDigest(segments: current.segments + [
            ConversationSegment(firstTurn: pending.firstTurn, lastTurn: pending.lastTurn, text: text)
        ])
        await MainActor.run {
            ChatRoomManager.shared.saveDigestForRoom(roomId: roomId, digest: updated)
        }
    }

    private func requestSegmentSummary(
        roomId: UUID,
        turns: [ConversationTurn],
        startingTurn: Int,
        mode: ChatMode,
        apiKey: String
    ) async throws -> String {
        let transcript = ConversationCompactor.transcript(for: turns, startingTurn: startingTurn, mode: mode)
        guard !transcript.isEmpty else { return "" }

        let userText = "다음은 정리할 대화 구간이다.\n\n" + transcript
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": ConversationCompactor.summaryInstruction(for: mode)]]],
            "contents": [["role": "user", "parts": [["text": userText]]]],
            "generationConfig": [
                // 지시한 분량보다 넉넉히 잡습니다. 3.7은 사고 토큰도 이 예산에서 함께 쓰고,
                // 모자라면 문장 한가운데서 잘린 글이 나옵니다.
                "maxOutputTokens": ConversationCompactor.segmentTokenBudget + 1200,
                "thinkingConfig": ["thinkingLevel": "low"]
            ]
        ]

        let json = try await postGemini(body: body, apiKey: apiKey, roomId: roomId)
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
        mode: ChatMode = .mathMentor,
        roleplayInProgress: Bool = false,
        onBubble: (@Sendable (GeneratedMessageBubble) async -> Void)? = nil
    ) async throws -> String {
        let model = AIModel.gemini37Flash
        guard let apiKey = KeychainStore.geminiAPIKey else {
            throw serviceError("설정에서 Gemini API 키를 먼저 등록해주세요.")
        }

        // 대화가 아주 길어진 방에서는 앞부분을 구간 요약으로 갈아끼웁니다.
        // 기준에 못 미치면 plan이 원본을 그대로 돌려주므로 짧은 방은 지금까지와 똑같이 동작합니다.
        let digest = roomId.map { ChatRoomManager.shared.loadDigestForRoom(roomId: $0) }
        let plan = ConversationCompactor.plan(conversation: conversation, digest: digest, mode: mode)

        var contents = buildGeminiContents(plan.verbatimTurns)
        if let digestText = plan.digestText {
            contents = digestPreamble(digestText) + contents
        }
        let system = systemPrompt(botName: botName, persona: persona, mode: mode)

        // 지문에 system이 들어가므로, 모드를 바꾸면 이전 캐시가 저절로 버려지고 새 지침으로 다시 잡힙니다.
        var reusedCache = roomId.flatMap {
            usablePrefixCache(for: $0, contents: contents, system: system, apiKey: apiKey)
        }
        // 캐시를 만들지 말지 정할 때 씁니다. **읽기 전에** 꺼내야 직전 값이 나옵니다.
        let previousRequestAt = roomId.flatMap { markRequest($0) }

        // 흘려보낼 곳이 있으면 스트리밍으로, 없으면 지금까지처럼 한 번에 받습니다.
        // 스트림은 완성된 문단만 통과시키므로 화면에 깨진 수식이 뜨지 않습니다.
        func run(cache: PrefixCache?, into outcome: StreamOutcome) async throws {
            let roleplaySoFar = mode == .companion && roleplayInProgress
            guard let onBubble else {
                try await performGeminiRequest(
                    into: outcome,
                    contents: contents, system: system, cache: cache, apiKey: apiKey, model: model, mode: mode
                )
                return
            }
            let buffer = StreamBubbleSink(
                botName: botName,
                roleplayEstablished: roleplaySoFar,
                onBubble: onBubble
            ) { [weak self] paragraph, roleplay in
                guard let self else { return [] }
                return await self.parseResponseIntoBubbles(
                    rawText: paragraph, botName: botName, roleplay: roleplay
                )
            }
            try await streamGeminiRequest(
                into: outcome,
                contents: contents, system: system, cache: cache, apiKey: apiKey, model: model, mode: mode
            ) { piece in
                await buffer.consume(piece)
            }
            await buffer.finish()
        }

        // 사용량을 **빠져나가는 모든 길에서** 적습니다.
        //
        // 예전에는 스트림이 정상적으로 끝난 뒤에만 적었습니다. 그런데 답변을 도중에
        // 멈추면(사용자가 중지) 태스크가 취소되면서 그 자리를 건너뛰었습니다.
        // 서버는 이미 입력을 다 읽고 답을 만들고 있었으므로 요금은 그대로 나갑니다.
        // 사용량 조각은 매 청크에 실려 오기 때문에, 도중에 멈춰도 그때까지 받은 값은
        // 상자에 남아 있습니다. 그걸 버리지 않고 적습니다.
        let outcome = StreamOutcome()
        defer {
            if let roomId {
                let reported = outcome.usage
                let responded = outcome.serverResponded
                Task {
                    if !reported.isEmpty {
                        await self.recordGeminiUsage(reported, roomId: roomId, model: model)
                    } else if responded {
                        // 답을 만들기 시작했는데 사용량을 못 받았습니다. 숫자를 지어내지
                        // 않고 건수만 남깁니다.
                        await self.recordUnreported(roomId: roomId, model: model)
                    }
                }
            }
        }

        do {
            try await run(cache: reusedCache, into: outcome)
        } catch {
            // 캐시가 서버에서 이미 만료·삭제되었으면 캐시 없이 한 번만 다시 보냅니다.
            // 이미 말풍선을 내보낸 뒤라면 다시 보낼 수 없으므로 그대로 올립니다.
            guard reusedCache != nil, onBubble == nil else { throw error }

            // 첫 시도가 서버에 닿아 사용량을 받았으면 **먼저 적고 상자를 비웁니다.**
            // 안 그러면 두 번째 시도의 값이 덮어써서 첫 요청이 장부에서 사라집니다.
            // 사용량을 아예 못 받은 실패(대개 캐시가 없다는 404)는 청구되지 않으므로
            // 미보고 건수로도 세지 않습니다.
            if let roomId, !outcome.usage.isEmpty {
                await recordGeminiUsage(outcome.usage, roomId: roomId, model: model)
                outcome.usage = [:]
            }

            // 못 쓰게 된 캐시는 서버 쪽도 지웁니다. 남겨 두면 아무도 안 읽는 채로
            // TTL이 다할 때까지 보관료를 먹습니다.
            if let roomId { dropCache(for: roomId, deleteRemote: true, apiKey: apiKey) }
            reusedCache = nil
            try await run(cache: nil, into: outcome)
        }

        let text = outcome.text
        guard !text.isEmpty else {
            // 답변이 비었을 때 "왜" 비었는지가 3.7에서는 대부분 finishReason에 담겨 옵니다.
            throw serviceError(geminiEmptyResponseMessage(finishReason: outcome.finishReason))
        }

        // 캐시에는 "방금 실제로 보낸 contents"를 그대로 올립니다.
        // 답변까지 덧붙여 캐시하면 적중률이 몇 %p 높지만, 앱이 다음 턴에 재구성하는 문자열과
        // 한 글자라도 어긋나면 지문 검사에서 통째로 탈락합니다. 보낸 것을 그대로 캐시하면
        // 다음 요청의 앞부분과 반드시 일치하므로, 답변+새 질문 두 턴만 캐시 밖에 남습니다.
        // 답변을 이미 확보한 뒤이므로 화면 표시를 막지 않도록 백그라운드에서 진행합니다.
        if let roomId {
            Task {
                await self.refreshPrefixCache(
                    roomId: roomId, contents: contents, system: system,
                    apiKey: apiKey, previousRequestAt: previousRequestAt
                )
            }
        }

        // 요약도 답변을 다 받은 뒤에 만듭니다. 보내기 전에 만들면 그 몇 초가 고스란히 응답 지연이 됩니다.
        if let roomId, let pending = plan.pending {
            Task { await self.appendDigestSegment(roomId: roomId, pending: pending, mode: mode, apiKey: apiKey) }
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
    ///
    /// **구조체가 아니라 참조입니다.** 값으로 돌려주면 도중에 끊겼을 때 그때까지 받은
    /// 것이 함께 사라집니다. 밖에서 상자를 만들어 넘기면, 예외로 빠져나가더라도
    /// 상자에 담긴 것은 부르는 쪽 손에 남습니다.
    final class StreamOutcome {
        var text = ""
        var finishReason: String?
        var usage: [String: Any] = [:]
        /// 서버가 요청을 받아 답을 만들기 시작했는지.
        ///
        /// 사용량을 못 받았을 때 그것을 "청구는 됐는데 못 센 요청"으로 볼지 가르는
        /// 기준입니다. 400·429·5xx로 거절당한 요청은 생성이 시작되지 않았으므로
        /// 세지 않습니다. 세면 화면의 경고가 실제보다 부풀어 믿을 수 없게 됩니다.
        var serverResponded = false
    }

    /// `streamGenerateContent`로 받아 도착하는 대로 흘려보냅니다.
    ///
    /// 완성된 말풍선을 만드는 판단은 `StreamingBubbleBuffer`가 합니다. 여기서는
    /// 서버가 준 조각을 그대로 넘길 뿐이라, 청크가 어디서 끊기든 상관하지 않습니다.
    private func streamGeminiRequest(
        into outcome: StreamOutcome,
        contents: [[String: Any]],
        system: String,
        cache: PrefixCache?,
        apiKey: String,
        model: AIModel,
        mode: ChatMode,
        onText: @Sendable (String) async -> Void
    ) async throws {
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
            withJSONObject: requestBody(contents: contents, system: system, cache: cache, mode: mode))

        let (bytes, response) = try await resilientSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw serviceError("Gemini 응답을 읽을 수 없습니다.")
        }
        guard (200...299).contains(http.statusCode) else {
            // 오류 본문도 스트림으로 오므로 모아서 기존 해석기에 넘깁니다.
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            _ = try validatedJSON(data: raw, response: response, provider: "Gemini")
            throw serviceError(
                "Gemini 요청이 \(http.statusCode) 상태로 끝났습니다.",
                retryable: AIServiceError.retryable(http.statusCode)
            )
        }

        outcome.serverResponded = true
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
    }

    /// 대화 한 턴을 보낼 요청 본문입니다. 스트리밍이든 아니든 같은 것을 씁니다.
    ///
    /// 예전에는 두 벌이 따로 있었고 사고량 같은 값이 양쪽에 각각 박혀 있었습니다.
    /// 한쪽만 고치면 다른 쪽이 조용히 옛 설정으로 나갑니다.
    private func requestBody(contents: [[String: Any]], system: String, cache: PrefixCache?, mode: ChatMode) -> [String: Any] {
        // Gemini 3.x는 temperature·topP·topK·candidateCount를 받지 않고,
        // 사고량은 thinking_budget 숫자가 아니라 thinkingLevel 문자열(low/medium/high)로 지정합니다.
        var body: [String: Any] = [
            "generationConfig": [
                "maxOutputTokens": Self.geminiMaxOutputTokens,
                // 사고량은 모드가 정합니다(`ChatMode.geminiThinkingLevel`).
                // 챗봇 방에서는 낮음입니다. 안 보이는 사고 토큰이 출력 단가로
                // 붙는데, 잡담의 말씨는 오래 생각한다고 좋아지지 않습니다.
                "thinkingConfig": ["thinkingLevel": mode.geminiThinkingLevel]
            ]
        ]
        // 안전 설정은 캐시에 담기지 않으므로 캐시를 쓰든 안 쓰든 매 요청에 함께 보냅니다.
        if let safety = mode.geminiSafetySettings { body["safetySettings"] = safety }
        if let cache {
            // 캐시에 시스템 지침과 앞부분 대화가 들어 있으므로 남은 턴만 보냅니다.
            // 이때 systemInstruction을 함께 보내면 요청이 거부됩니다.
            body["cachedContent"] = cache.name
            body["contents"] = Array(contents.dropFirst(cache.coveredTurns))
        } else {
            body["systemInstruction"] = ["parts": [["text": system]]]
            body["contents"] = contents
        }
        return body
    }

    private func performGeminiRequest(
        into outcome: StreamOutcome,
        contents: [[String: Any]],
        system: String,
        cache: PrefixCache?,
        apiKey: String,
        model: AIModel,
        mode: ChatMode
    ) async throws {
        guard let url = URL(string: "\(Self.geminiBaseURL)/models/\(model.rawValue):generateContent") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 키를 쿼리 문자열에 붙이면 URL이 남는 곳마다 그대로 노출되므로 헤더로 보냅니다.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(contents: contents, system: system, cache: cache, mode: mode))

        let (data, response) = try await resilientSession.data(for: request)
        let json = try validatedJSON(data: data, response: response, provider: "Gemini")

        outcome.serverResponded = true
        outcome.usage = json["usageMetadata"] as? [String: Any] ?? [:]
        let candidate = (json["candidates"] as? [[String: Any]])?.first
        outcome.finishReason = candidate?["finishReason"] as? String
        let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        outcome.text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func usablePrefixCache(
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
    private func dropCache(for roomId: UUID, deleteRemote: Bool, apiKey: String) {
        guard let removed = prefixCaches[roomId] else { return }
        prefixCaches[roomId] = nil
        if deleteRemote {
            Task { await self.deleteCache(named: removed.name, apiKey: apiKey) }
        }
    }

    private func refreshPrefixCache(
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

    private func sendOpenAIRequest(conversation: [ConversationTurn], botName: String, roomId: UUID?, persona: PersonaStyle? = nil, mode: ChatMode = .mathMentor) async throws -> String {
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
            "instructions": systemPrompt(botName: botName, persona: persona, mode: mode),
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
            throw serviceError(
                "\(provider) 오류: \(message)",
                retryable: AIServiceError.retryable(http.statusCode)
            )
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

    /// - Parameter retryable: 같은 요청을 그대로 다시 보내면 될 만한 실패인지.
    ///
    ///   **거짓이면 다시 보내지 않습니다.** 예전에는 어떤 실패든 조용히 두 번 더 보냈는데,
    ///   키가 틀렸거나 안전 필터에 걸린 요청은 몇 번을 보내도 똑같이 실패합니다.
    ///   그 재시도는 화면에 아무것도 남기지 않으면서 요금만 세 배로 냈습니다.
    ///
    ///   기본값이 거짓인 이유는, 이 함수로 만드는 오류가 대부분 "키를 등록해주세요"처럼
    ///   다시 보내도 소용없는 것들이기 때문입니다. 서버 상태 코드에서 온 실패만
    ///   `AIServiceError.retryable(_:)`로 판단해 참이 됩니다.
    private func serviceError(_ message: String, retryable: Bool = false) -> NSError {
        NSError(
            domain: AIServiceError.domain,
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: message,
                AIServiceError.retryableKey: retryable
            ]
        )
    }

    /// - Parameter roleplay: 이 턴이 상황극임이 확인됐는지. 참일 때만 따옴표 없는
    ///   문단을 묘사로 봅니다. 잡담에서는 대사에 따옴표를 치지 않으므로, 이 조건이
    ///   없으면 평범한 대화가 통째로 묘사가 됩니다.
    private func parseResponseIntoBubbles(
        rawText: String,
        botName: String,
        roleplay: Bool = false
    ) -> [GeneratedMessageBubble] {
        let cleanText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        var paragraphs = cleanText.components(separatedBy: "\n\n")
        if paragraphs.count == 1 {
            let lines = cleanText.components(separatedBy: "\n")
            if lines.contains(where: { $0.hasPrefix("\(botName):") || $0.hasPrefix("사피엔스:") }) { paragraphs = lines }
        }

        // 한 번에 받는 경로에서는 답변 전체가 여기 들어오므로, 뒤쪽 문단의 따옴표를
        // 보고 앞쪽 문단까지 제대로 가를 수 있습니다. 스트리밍 경로는 문단이 하나씩
        // 들어오므로 호출하는 쪽이 지금까지 본 것을 `roleplay`로 알려 줍니다.
        let isRoleplay = roleplay || paragraphs.contains { RoleplayParser.establishesRoleplay($0) }

        var chunks: [String] = []
        for paragraph in paragraphs { chunks.append(contentsOf: splitTextAndComplexMath(paragraph: paragraph)) }
        var bubbles: [GeneratedMessageBubble] = []
        for item in chunks {
            var text = item.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["\(botName):", "\(botName) :", "사피엔스:"] where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            let classified = RoleplayParser.classify(text, roleplayEstablished: isRoleplay)
            text = classified.text
            let (cleanedText, allSpecs) = MathGraphRenderer.extractGraphSpecs(from: text)
            if !cleanedText.isEmpty {
                bubbles.append(GeneratedMessageBubble(text: cleanedText, kind: classified.kind))
            }
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
