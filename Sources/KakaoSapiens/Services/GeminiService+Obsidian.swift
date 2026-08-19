import Foundation

extension GeminiService {
    public func scanObsidianProblemEpisodes(
        candidate: ProblemEpisodeCandidate,
        criterion: String,
        model: AIModel,
        roomId: UUID
    ) async throws -> [ObsidianBatchCandidate] {
        var collected: [ObsidianBatchCandidate] = []
        for window in ObsidianBatchCorpus.windows(turns: candidate.turns) {
            guard let first = window.first?.number, let last = window.last?.number else { continue }
            let prompt = """
            다음 수학 멘토 대화에서 사용자가 실제로 헷갈렸거나, 틀렸거나, 반복 질문하며 어려워한 독립 문제만 찾는다.
            단순 잡담, 일반 기능 질문, 충분히 이해한 문제는 제외한다. 하나의 문제를 여러 턴에서 다시 다뤘으면 한 후보로 묶는다.
            사용자의 요청 기준: \(criterion)
            각 후보의 startTurn/endTurn/relatedTurns/unrelatedTurns는 반드시 \(first)...\(last) 안에 있어야 한다.
            score는 복습 필요도, confidence는 경계 판정 확신도다. 후보가 없으면 빈 배열을 반환한다.

            대화:
            \(ObsidianBatchCorpus.classificationTranscript(window))
            """
            let response: ObsidianBatchCandidateResponse = try await requestObsidianDecoded(
                model: model, roomId: roomId,
                system: "수학 학습 대화에서 복습할 문제 에피소드만 엄격히 선별한다. JSON만 반환한다.",
                prompt: prompt, attachments: [], maxOutputTokens: 2_400,
                structuredOutput: .batchCandidates
            )
            collected.append(contentsOf: response.candidates.filter {
                first...last ~= $0.startTurn && first...last ~= $0.endTurn && $0.startTurn <= $0.endTurn
            })
        }
        return ObsidianBatchCandidateMerger.merge(collected)
    }

    public func detectProblemEpisode(
        candidate: ProblemEpisodeCandidate,
        model: AIModel,
        roomId: UUID
    ) async throws -> EpisodeScopeResult {
        guard !candidate.turns.isEmpty else {
            throw serviceError("문제 범위를 판정할 대화가 없습니다.")
        }

        let maximum = candidate.automaticTurns.count
        var windowSize = min(12, maximum)
        while true {
            let window = Array(candidate.automaticTurns.suffix(windowSize))
            guard let first = window.first?.number else {
                throw serviceError("문제 범위를 판정할 대화가 없습니다.")
            }
            let range = first...candidate.endpointTurn
            let prompt = """
            다음은 \(candidate.endpointTurn)턴의 멘토 답변을 끝점으로 삼아 역으로 모은 대화다.
            이 답변으로 해결된 하나의 수학 문제 또는 학습 주제가 어느 턴에서 시작했는지 판정하라.
            풀이에 영향을 준 추가 질문, 오답, 혼동, 관점 전환은 관련 턴이다.
            완전히 무관한 잡담이나 별개 문제만 unrelatedTurns에 넣는다.
            시작이 제공된 첫 턴보다 앞이라면 needsEarlierContext를 true로 둔다.
            endTurn은 반드시 \(candidate.endpointTurn)이다.

            JSON 형식:
            {"startTurn":정수,"endTurn":정수,"confidence":0부터1,"relatedTurns":[정수],"unrelatedTurns":[정수],"needsEarlierContext":불리언,"reason":"짧은 근거"}

            대화:
            \(candidate.transcript(in: range))
            """
            var result: EpisodeScopeResult = try await requestObsidianDecoded(
                model: model,
                roomId: roomId,
                system: Self.episodeScopeInstruction,
                prompt: prompt,
                attachments: [],
                maxOutputTokens: 1200,
                structuredOutput: .episodeScope
            )
            result = try validatedScope(
                result,
                candidate: candidate,
                inspectedRange: range
            )

            if result.needsEarlierContext, windowSize < maximum {
                windowSize = min(windowSize + 12, maximum)
                continue
            }
            if result.needsEarlierContext, windowSize == maximum,
               candidate.turns.count <= 60,
               candidate.turns.first?.number == 1 {
                // 로컬 기록의 첫 턴까지 봤다면 더 이전 원문은 존재하지 않습니다.
                result.needsEarlierContext = false
            }
            return result
        }
    }

    public func prepareObsidianNote(
        candidate: ProblemEpisodeCandidate,
        range: ClosedRange<Int>,
        unrelatedTurns: Set<Int>,
        model: AIModel,
        roomId: UUID
    ) async throws -> PreparedObsidianNote {
        let selectedTurns = candidate.turns(in: range)
        guard !selectedTurns.isEmpty, selectedTurns.last?.number == range.upperBound else {
            throw serviceError("선택한 문제 범위를 대화에서 찾을 수 없습니다.")
        }

        let note: PreparedObsidianNote
        if selectedTurns.count <= 12 {
            note = try await requestPreparedNote(
                candidate: candidate,
                range: range,
                unrelatedTurns: unrelatedTurns,
                model: model,
                roomId: roomId
            )
        } else {
            var chunks: [EpisodeChunkSummary] = []
            var offset = 0
            while offset < selectedTurns.count {
                let group = Array(selectedTurns[offset..<min(offset + 8, selectedTurns.count)])
                guard let first = group.first?.number, let last = group.last?.number else { break }
                let chunkRange = first...last
                chunks.append(try await requestEpisodeChunk(
                    candidate: candidate,
                    range: chunkRange,
                    unrelatedTurns: unrelatedTurns,
                    model: model,
                    roomId: roomId
                ))
                offset += 8
            }
            note = try await composePreparedNote(
                chunks: chunks,
                fullRange: range,
                unrelatedTurns: unrelatedTurns,
                model: model,
                roomId: roomId
            )
        }
        return validatedPreparedNote(note, range: range, unrelatedTurns: unrelatedTurns)
    }

    private static let episodeScopeInstruction = """
    당신은 수학 학습 대화의 문제 해결 에피소드 경계를 판정한다.
    보이는 대화에만 근거하고, JSON 객체 하나만 출력한다. Markdown 코드 펜스를 쓰지 않는다.
    """

    private static let preparedNoteInstruction = """
    당신은 여러 턴에 걸친 수학 학습 대화를 정확한 복습 노트로 편집한다.
    원문에 없는 조건, 계산, 결론을 만들지 않는다. 틀린 아이디어는 최종 풀이에 섞지 말고 confusions에서 왜 틀렸는지 교정한다.
    각 아이디어와 교정에는 근거 턴을 자연어로 남긴다. 결론이 없으면 unresolved에 적는다.
    수식은 Obsidian MathJax와 호환되는 인라인 $...$ 또는 블록 $$...$$ LaTeX로 쓴다.
    문제를 이해하는 데 함수 그래프, 음함수 곡선, 수치적분 함수족, 1계 미분방정식의 수치해, 3차원 표면, 좌표 도식이 실제로 도움이 될 때만 visuals에 시각자료를 넣는다.
    시각자료의 함수식·좌표·범위·적분 구간·초기값·등고선 값은 원문과 검증된 풀이에서 나온 내용만 사용하고, 필요하지 않으면 반드시 visuals를 빈 배열로 둔다.
    함수식의 곱셈은 생략하지 말고 반드시 * 기호를 쓴다.
    function2D는 y=f(x), parametric2D는 xExpression=x(t)와 yExpression=y(t), implicit2D는 expression=F(x,y)와 contourValue, integral2D는 y(x)=initialY+∫[parameterMin,parameterMax]expression(x,t)dt, ode2D는 y'=expression(x,y)와 initialX·initialY, surface3D는 z=f(x,y), coordinateDiagram은 points와 segments를 사용한다.
    사용하지 않는 문자열 필드는 빈 문자열, 점·선분 필드는 빈 배열, 사용하지 않는 수치 필드는 유한한 기본값으로 채운다. 축 라벨과 범례는 그래프가 나타내는 수학적 의미를 짧고 정확하게 적는다.
    JSON 객체 하나만 출력하고 Markdown 코드 펜스를 쓰지 않는다.
    """

    private func requestPreparedNote(
        candidate: ProblemEpisodeCandidate,
        range: ClosedRange<Int>,
        unrelatedTurns: Set<Int>,
        model: AIModel,
        roomId: UUID
    ) async throws -> PreparedObsidianNote {
        let prompt = preparedNotePrompt(
            source: candidate.transcript(in: range),
            range: range,
            unrelatedTurns: unrelatedTurns
        )
        let attachments = candidate.attachments(in: range, excluding: unrelatedTurns).map(\.attachment)
        return try await requestObsidianDecoded(
            model: model,
            roomId: roomId,
            system: Self.preparedNoteInstruction,
            prompt: prompt,
            attachments: attachments,
            maxOutputTokens: 5000,
            structuredOutput: .preparedNote
        )
    }

    private struct EpisodeChunkSummary: Codable {
        let startTurn: Int
        let endTurn: Int
        let problemStatements: [String]
        let facts: [String]
        let ideas: [String]
        let confusions: [String]
        let solutionSteps: [String]
        let answers: [String]
        let concepts: [String]
        let unresolved: [String]
        let coverage: [TurnCoverage]
    }

    private func requestEpisodeChunk(
        candidate: ProblemEpisodeCandidate,
        range: ClosedRange<Int>,
        unrelatedTurns: Set<Int>,
        model: AIModel,
        roomId: UUID
    ) async throws -> EpisodeChunkSummary {
        let prompt = """
        전체 문제 해결 에피소드 중 \(range.lowerBound)~\(range.upperBound)턴 구간이다.
        다음 최종 합성 단계가 원문 없이도 사실, 수식, 아이디어의 발전, 오답과 교정, 풀이 단계와 답을 복원할 수 있게 근거 턴과 함께 추출하라.
        무관하여 제외할 턴: \(unrelatedTurns.sorted())
        JSON 키는 startTurn, endTurn, problemStatements, facts, ideas, confusions, solutionSteps, answers, concepts, unresolved, coverage다.
        coverage 각 항목은 {"turn":정수,"status":"included|unrelated|merged","reason":"근거"} 형식이다.

        \(candidate.transcript(in: range))
        """
        let attachments = candidate.attachments(in: range, excluding: unrelatedTurns).map(\.attachment)
        return try await requestObsidianDecoded(
            model: model,
            roomId: roomId,
            system: Self.preparedNoteInstruction,
            prompt: prompt,
            attachments: attachments,
            maxOutputTokens: 3500,
            structuredOutput: .episodeChunk
        )
    }

    private func composePreparedNote(
        chunks: [EpisodeChunkSummary],
        fullRange: ClosedRange<Int>,
        unrelatedTurns: Set<Int>,
        model: AIModel,
        roomId: UUID
    ) async throws -> PreparedObsidianNote {
        let data = try JSONEncoder().encode(chunks)
        guard let source = String(data: data, encoding: .utf8) else {
            throw serviceError("장기 풀이 구간을 합칠 수 없습니다.")
        }
        let prompt = preparedNotePrompt(source: source, range: fullRange, unrelatedTurns: unrelatedTurns)
            + "\n위 source는 8턴 단위로 검증된 중간 추출 결과다. 중복을 합치되 근거 턴과 수식을 보존하라."
        return try await requestObsidianDecoded(
            model: model,
            roomId: roomId,
            system: Self.preparedNoteInstruction,
            prompt: prompt,
            attachments: [],
            maxOutputTokens: 5500,
            structuredOutput: .preparedNote
        )
    }

    private func preparedNotePrompt(
        source: String,
        range: ClosedRange<Int>,
        unrelatedTurns: Set<Int>
    ) -> String {
        """
        \(range.lowerBound)~\(range.upperBound)턴의 해결 과정을 문제당 하나의 자립적인 학습 노트로 정리하라.
        무관하여 제외할 턴: \(unrelatedTurns.sorted())
        관련 턴의 추가 질문, 유효한 아이디어, 오답, 혼동과 교정을 빠뜨리지 않는다.

        정확히 다음 JSON 키를 사용한다.
        {"title":"짧은 제목","problem":"자립적인 문제","givens":["조건"],"ideas":["아이디어 — N턴"],"confusions":["오해와 교정 — N턴"],"solution":"완결된 최종 해설","answer":"최종 답","concepts":["개념과 다음 기준"],"unresolved":["미해결"],"evidenceTurns":[정수],"coverage":[{"turn":정수,"status":"included|unrelated|merged","reason":"근거"}],"visuals":[{"id":"graph-1","kind":"function2D","title":"제목","caption":"설명","expression":"sin(x)","xExpression":"","yExpression":"","legend":"y=sin(x)","xLabel":"x","yLabel":"y","zLabel":"z","xMin":-6.28,"xMax":6.28,"yMin":-2,"yMax":2,"zMin":-1,"zMax":1,"parameterMin":0,"parameterMax":1,"initialX":0,"initialY":0,"contourValue":0,"points":[],"segments":[]}]} (kind는 function2D, parametric2D, implicit2D, integral2D, ode2D, surface3D, coordinateDiagram 중 하나)
        coverage에는 범위의 모든 사용자 턴을 정확히 한 번씩 넣는다.

        source:
        \(source)
        """
    }

    private func validatedScope(
        _ scope: EpisodeScopeResult,
        candidate: ProblemEpisodeCandidate,
        inspectedRange: ClosedRange<Int>
    ) throws -> EpisodeScopeResult {
        guard scope.endTurn == candidate.endpointTurn,
              inspectedRange.contains(scope.startTurn),
              scope.startTurn <= scope.endTurn else {
            throw serviceError("AI가 반환한 문제 범위가 현재 대화와 맞지 않습니다. 다시 시도해주세요.")
        }
        let allowed = Set(inspectedRange)
        let unrelated = Array(Set(scope.unrelatedTurns).intersection(allowed)).sorted()
        var related = Array(Set(scope.relatedTurns).intersection(allowed).subtracting(unrelated)).sorted()
        if !related.contains(scope.endTurn) { related.append(scope.endTurn); related.sort() }
        return EpisodeScopeResult(
            startTurn: scope.startTurn,
            endTurn: scope.endTurn,
            confidence: min(max(scope.confidence, 0), 1),
            relatedTurns: related,
            unrelatedTurns: unrelated,
            needsEarlierContext: scope.needsEarlierContext,
            reason: scope.reason
        )
    }

    private func validatedPreparedNote(
        _ raw: PreparedObsidianNote,
        range: ClosedRange<Int>,
        unrelatedTurns: Set<Int>
    ) -> PreparedObsidianNote {
        var note = raw
        note.title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if note.title.isEmpty { note.title = "수학 문제 정리" }

        var byTurn: [Int: TurnCoverage] = [:]
        for item in note.coverage where range.contains(item.turn) { byTurn[item.turn] = item }
        for turn in range {
            if unrelatedTurns.contains(turn) {
                byTurn[turn] = TurnCoverage(turn: turn, status: .unrelated, reason: byTurn[turn]?.reason ?? "범위 판정에서 무관한 턴으로 분류")
            } else if byTurn[turn] == nil {
                byTurn[turn] = TurnCoverage(turn: turn, status: .merged, reason: "AI 결과에서 별도 근거를 확인하지 못해 원문 검토 필요")
                note.unresolved.append("\(turn)턴의 내용이 정리 결과에서 명시적으로 확인되지 않았습니다.")
            }
        }
        note.coverage = byTurn.values.sorted { $0.turn < $1.turn }
        note.evidenceTurns = Array(Set(note.evidenceTurns).intersection(Set(range))).sorted()
        note.visuals = ObsidianVisualMath.validatedVisuals(note.visuals)
        return note
    }

    private func requestObsidianJSON(
        model: AIModel,
        roomId: UUID,
        system: String,
        prompt: String,
        attachments: [ChatAttachment],
        maxOutputTokens: Int,
        structuredOutput: ObsidianStructuredOutput
    ) async throws -> String {
        switch model {
        case .gemini37Flash:
            guard let apiKey = KeychainStore.geminiAPIKey else {
                throw serviceError("설정에서 Gemini API 키를 먼저 등록해주세요.")
            }
            var parts: [[String: Any]] = [["text": prompt]]
            for attachment in attachments where attachment.mimeType.hasPrefix("image/") || attachment.mimeType == "application/pdf" {
                parts.append(["inlineData": ["mimeType": attachment.mimeType, "data": attachment.dataBase64]])
            }
            let body: [String: Any] = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": parts]],
                "generationConfig": structuredOutput.geminiGenerationConfig(maxOutputTokens: maxOutputTokens)
            ]
            let json = try await postGemini(body: body, apiKey: apiKey, roomId: roomId)
            return try textFromGeminiJSON(json)

        case .gpt56Luna:
            return try await requestOpenAIObsidianJSON(
                system: system,
                prompt: prompt,
                attachments: attachments,
                roomId: roomId,
                maxOutputTokens: maxOutputTokens,
                structuredOutput: structuredOutput
            )
        }
    }

    private func requestObsidianDecoded<T: Decodable>(
        model: AIModel,
        roomId: UUID,
        system: String,
        prompt: String,
        attachments: [ChatAttachment],
        maxOutputTokens: Int,
        structuredOutput: ObsidianStructuredOutput
    ) async throws -> T {
        var lastParsingError: Error?
        for attempt in 0..<ObsidianStructuredOutput.maximumAttempts {
            let retryNote = attempt == 0 ? "" : "\n이전 출력은 로컬 구조 검증을 통과하지 못했다. 지정된 JSON Schema만 정확히 반환하라."
            let raw = try await requestObsidianJSON(
                model: model,
                roomId: roomId,
                system: system,
                prompt: prompt + retryNote,
                attachments: attachments,
                maxOutputTokens: maxOutputTokens,
                structuredOutput: structuredOutput
            )
            do {
                return try ObsidianAIResponseParser.decode(raw)
            } catch {
                lastParsingError = error
            }
        }
        throw lastParsingError ?? serviceError("AI 정리 응답의 구조를 확인할 수 없습니다.")
    }

    private func textFromGeminiJSON(_ json: [String: Any]) throws -> String {
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first,
              let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
            throw serviceError("Gemini의 Obsidian 정리 응답을 읽을 수 없습니다.")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else { throw serviceError("Gemini가 빈 Obsidian 정리 결과를 반환했습니다.") }
        return text
    }

    private func requestOpenAIObsidianJSON(
        system: String,
        prompt: String,
        attachments: [ChatAttachment],
        roomId: UUID,
        maxOutputTokens: Int,
        structuredOutput: ObsidianStructuredOutput
    ) async throws -> String {
        guard let apiKey = KeychainStore.openAIAPIKey else {
            throw serviceError("설정에서 OpenAI API 키를 먼저 등록해주세요.")
        }
        guard let url = URL(string: "https://api.openai.com/v1/responses") else { throw URLError(.badURL) }
        var content: [[String: Any]] = [["type": "input_text", "text": prompt]]
        for attachment in attachments where attachment.mimeType.hasPrefix("image/") {
            content.append([
                "type": "input_image",
                "image_url": "data:\(attachment.mimeType);base64,\(attachment.dataBase64)",
                "detail": "auto"
            ])
        }
        let body: [String: Any] = [
            "model": AIModel.gpt56Luna.rawValue,
            "instructions": system,
            "input": [["role": "user", "content": content]],
            "reasoning": ["effort": "low", "context": "all_turns"],
            "text": structuredOutput.openAITextConfig,
            "max_output_tokens": maxOutputTokens,
            "background": true,
            "store": true,
            "safety_identifier": "kakao-sapiens-local-user"
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Client-Request-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let initial = try await openAIJSON(request: request, maxRetries: 2)
        let json = try await waitForOpenAIResponse(initial, apiKey: apiKey)
        if let usage = json["usage"] as? [String: Any] {
            let details = usage["input_tokens_details"] as? [String: Any]
            let inputTokens = intValue(usage["input_tokens"])
            let outputTokens = intValue(usage["output_tokens"])
            let cachedTokens = intValue(details?["cached_tokens"])
            let cacheWriteTokens = intValue(details?["cache_write_tokens"])
            await MainActor.run {
                TokenUsageManager.shared.recordUsage(
                    roomId: roomId,
                    model: .gpt56Luna,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cachedInputTokens: cachedTokens,
                    cacheWriteTokens: cacheWriteTokens
                )
            }
        }
        if let direct = json["output_text"] as? String, !direct.isEmpty { return direct }
        let text = (json["output"] as? [[String: Any]] ?? [])
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .compactMap { item -> String? in
                guard item["type"] as? String == "output_text" else { return nil }
                return item["text"] as? String
            }
            .joined(separator: "\n")
        guard !text.isEmpty else { throw serviceError("OpenAI의 Obsidian 정리 응답을 읽을 수 없습니다.") }
        return text
    }
}
