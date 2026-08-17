import Foundation

/// 대화 한 턴을 보내고 받는 길입니다.
///
/// 요청 본문 조립, 스트리밍과 한 번에 받기, 시스템 지침이 여기 있습니다.
extension GeminiService {
    // Gemini 3.7 Flash는 사고 토큰도 출력 토큰 예산에서 함께 소모합니다.
    // thinkingLevel이 medium이므로 실제로 보이는 답변 길이보다 여유를 두고 잡습니다.
    static let geminiMaxOutputTokens = 8192
    func systemPrompt(botName: String, persona: PersonaStyle? = nil, mode: ChatMode = .mathMentor) -> String {
        // 이 고정 접두사는 두 공급자에서 동일하게 재사용됩니다. 방 이름 같은 동적 값은 끝에 둬 캐시 적중률을 높입니다.
        var prompt = mode.stableSystemPrompt
        // 말투는 방마다 고정이라 캐시 접두사 안쪽에 두어도 적중률이 떨어지지 않습니다.
        if let section = persona?.promptSection(botName: botName, mode: mode) {
            prompt += "\n\n" + section
        }
        prompt += "\n\n# 현재 대화 설정\n이 대화에서 당신의 이름은 '\(botName)'이다. 자신을 지칭해야 할 때 이 이름을 사용한다."
        return prompt
    }

    func sendGeminiRequest(
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
    func digestPreamble(_ text: String) -> [[String: Any]] {
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
    func streamGeminiRequest(
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
    func requestBody(contents: [[String: Any]], system: String, cache: PrefixCache?, mode: ChatMode) -> [String: Any] {
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

    func performGeminiRequest(
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

    func buildGeminiContents(_ conversation: [ConversationTurn]) -> [[String: Any]] {
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

}
