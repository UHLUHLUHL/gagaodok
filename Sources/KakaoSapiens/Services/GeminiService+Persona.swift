import Foundation

/// 말투를 찾고, 뽑고, 다듬고, 미리 들어 보는 길입니다.
///
/// 대화와 달리 캐시를 쓰지 않습니다. 방마다 한 번씩만 일어나는 일이라서입니다.
extension GeminiService {
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

    struct TextStreamResult {
        let text: String
        let finishReason: String?
        let sources: [String]
    }

    /// 글 하나를 흘려 받습니다. 대화용 스트림과 달리 말풍선으로 가르지 않습니다.
    ///
    /// 지금은 말투 조사만 씁니다. 오래 걸리는 요청이라, 다 받을 때까지 기다리는 대신
    /// 도착하는 대로 넘겨 화면이 무엇을 하고 있는지 보여줄 수 있게 합니다.
    func streamGeminiText(
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

}
