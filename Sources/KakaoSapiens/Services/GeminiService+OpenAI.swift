import Foundation

/// Luna(OpenAI) 쪽 길입니다. Gemini와 겹치는 것이 없어 통째로 갈라 뒀습니다.
extension GeminiService {
    func sendOpenAIRequest(conversation: [ConversationTurn], botName: String, roomId: UUID?, persona: PersonaStyle? = nil, mode: ChatMode = .mathMentor) async throws -> String {
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

    func waitForOpenAIResponse(_ initialJSON: [String: Any], apiKey: String) async throws -> [String: Any] {
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

    func openAIJSON(request: URLRequest, maxRetries: Int) async throws -> [String: Any] {
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

    func isRetryableOpenAIStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 409 || statusCode == 429 || statusCode >= 500
    }

    func retryDelay(attempt: Int, response: HTTPURLResponse?) -> Int {
        if let value = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(value), seconds > 0, seconds <= 60 {
            return Int(seconds * 1000)
        }
        // 0.6초 → 1.2초의 짧고 제한된 지수 백오프와 작은 지터입니다.
        let base = 600 * (1 << min(attempt, 4))
        return base + Int.random(in: 0...180)
    }

    func isTransientNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .notConnectedToInternet, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    func openAIStatusMessage(_ json: [String: Any], status: String) -> String {
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

    func buildOpenAIInput(_ conversation: [ConversationTurn]) -> [[String: Any]] {
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

}
