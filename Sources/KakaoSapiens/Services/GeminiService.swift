import Foundation
import AppKit

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
    지원 식은 sin(x), cos(x), tan(x), x^2, exp(x), ln(x), t*cos(t), t*sin(t)다. 지원되지 않는 식을 그래프 태그로 만들지 않는다.
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
        model requestedModel: AIModel? = nil
    ) async throws -> GeneratedAIResponse {
        let model = await MainActor.run { requestedModel ?? ModelSelectionManager.shared.selectedModel }
        let rawText: String
        switch model {
        case .gemini37Flash:
            rawText = try await sendGeminiRequest(conversation: conversation, botName: botName, roomId: roomId)
        case .gpt56Luna:
            rawText = try await sendOpenAIRequest(conversation: conversation, botName: botName, roomId: roomId)
        }
        return GeneratedAIResponse(
            rawText: rawText,
            bubbles: parseResponseIntoBubbles(rawText: rawText, botName: botName)
        )
    }

    private func systemPrompt(botName: String) -> String {
        stableSystemPrompt + "\n\n# 현재 대화 설정\n이 대화에서 당신의 이름은 '\(botName)'이다. 자신을 지칭해야 할 때 이 이름을 사용한다."
    }

    // Gemini 3.7 Flash는 사고 토큰도 출력 토큰 예산에서 함께 소모합니다.
    // thinkingLevel이 medium이므로 실제로 보이는 답변 길이보다 여유를 두고 잡습니다.
    private static let geminiMaxOutputTokens = 8192

    private func sendGeminiRequest(conversation: [ConversationTurn], botName: String, roomId: UUID?) async throws -> String {
        let model = AIModel.gemini37Flash
        guard let apiKey = KeychainStore.geminiAPIKey else {
            throw serviceError("설정에서 Gemini API 키를 먼저 등록해주세요.")
        }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):generateContent") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 키를 쿼리 문자열에 붙이면 URL이 남는 곳마다 그대로 노출되므로 헤더로 보냅니다.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 60

        let contents = buildGeminiContents(conversation)
        // Gemini 3.x는 temperature·topP·topK·candidateCount를 받지 않고,
        // 사고량은 thinking_budget 숫자가 아니라 thinkingLevel 문자열(low/medium/high)로 지정합니다.
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt(botName: botName)]]],
            "contents": contents,
            "generationConfig": [
                "maxOutputTokens": Self.geminiMaxOutputTokens,
                "thinkingConfig": ["thinkingLevel": "medium"]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try validatedJSON(data: data, response: response, provider: "Gemini")

        if let usage = json["usageMetadata"] as? [String: Any], let roomId {
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

        guard let candidates = json["candidates"] as? [[String: Any]],
              let candidate = candidates.first else {
            throw serviceError("Gemini 응답 형식을 읽을 수 없습니다.")
        }

        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else {
            // 답변이 비었을 때 "왜" 비었는지가 3.7에서는 대부분 finishReason에 담겨 옵니다.
            throw serviceError(geminiEmptyResponseMessage(finishReason: candidate["finishReason"] as? String))
        }
        return text
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

    private func sendOpenAIRequest(conversation: [ConversationTurn], botName: String, roomId: UUID?) async throws -> String {
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
            "instructions": systemPrompt(botName: botName),
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
            let (cleanedText, specs) = MathGraphRenderer.extractGraphSpecs(from: text)
            if !cleanedText.isEmpty { bubbles.append(GeneratedMessageBubble(text: cleanedText)) }
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
