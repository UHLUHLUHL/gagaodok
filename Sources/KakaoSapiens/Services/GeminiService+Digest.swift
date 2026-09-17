import Foundation

/// 대화가 길어진 방의 앞부분을 구간 요약으로 갈아끼웁니다.
extension GeminiService {
    /// 구간 요약 요청 한 번의 결과입니다. 실패를 뭉치지 않고 갈래마다 이름을 붙입니다 —
    /// 그래야 측정 장부에서 "예산 부족"과 "지시 위반"을 가를 수 있습니다.
    enum SegmentSummaryResult {
        case text(String)
        case noCandidate
        /// 종료 사유가 `STOP`이 아닙니다. 값은 그 사유입니다(대개 `MAX_TOKENS`).
        case notStop(String)
        case empty
    }

    /// 한 구간을 요약해 방의 요약 목록 뒤에 붙입니다.
    ///
    /// 실패하면 아무것도 바꾸지 않습니다. 그러면 다음 요청에서 같은 구간을 다시 시도하고,
    /// 그때까지는 그 구간이 원문으로 나가므로 대화에는 영향이 없습니다.
    ///
    /// **모든 끝에 이름을 붙여 적습니다**(챗봇 방만). 예전에는 실패가 전부 말없이
    /// `return`이라, 돈을 쓰고 실패해도 어디에도 남지 않았습니다.
    func appendDigestSegment(
        roomId: UUID,
        pending: ConversationCompactor.PendingSegment,
        mode: ChatMode,
        model: AIModel? = nil,
        apiKey: String
    ) async {
        let measure = mode == .companion
        // 요청과 장부가 같은 모델을 가리키도록 처음에 한 번 정합니다(`postGemini`와 같은 규칙).
        let requestModel: AIModel
        if let model { requestModel = model } else { requestModel = await auxiliaryModel(for: roomId) }
        func record(_ outcome: DigestOutcome, before: Int, after: Int, detail: String? = nil) {
            guard measure else { return }
            let modelId = requestModel.rawValue
            Task { @MainActor in
                OptimizationMeasurementStore.shared.observeDigest(
                    outcome, coverageBefore: before, coverageAfter: after, failureDetail: detail, model: modelId)
            }
        }

        guard !summarizingRooms.contains(roomId) else {
            record(.ALREADY_RUNNING, before: 0, after: 0)
            return
        }
        // **실패가 이어지면 잠시 쉽니다.** 예전에는 실패하면 다음 요청에서 바로 다시
        // 시도했으므로, 요약이 계속 실패하는 방은 메시지를 보낼 때마다 유료 요약을
        // 하나씩 만들고 버렸습니다. 기다리는 동안 그 구간은 원문으로 나가므로 대화에는
        // 영향이 없습니다.
        if let retry = digestRetry[roomId], Date() < retry.notBefore {
            record(.BACKOFF_SKIPPED, before: 0, after: 0)
            return
        }
        summarizingRooms.insert(roomId)
        defer { summarizingRooms.remove(roomId) }

        // 그 사이 다른 요청이 같은 구간을 이미 채웠을 수 있습니다.
        let current = await MainActor.run { ChatRoomManager.shared.loadDigestForRoom(roomId: roomId) }
        let before = current.coveredTurns
        guard before < pending.lastTurn else {
            record(.NO_PENDING, before: before, after: before)
            return
        }

        let outcome: DigestOutcome
        var detail: String?
        var text = ""
        do {
            switch try await requestSegmentSummary(
                roomId: roomId, turns: pending.turns, startingTurn: pending.firstTurn,
                mode: mode, model: requestModel, apiKey: apiKey) {
            case .text(let value): text = value; outcome = .COMMITTED
            case .noCandidate: outcome = .NO_CANDIDATE
            case .notStop(let reason): outcome = .NOT_STOP; detail = reason
            case .empty: outcome = .SEGMENT_TOO_LONG; detail = "EMPTY"
            }
        } catch {
            outcome = .EXCEPTION
            detail = String(describing: type(of: error))
        }

        guard outcome == .COMMITTED else {
            let failures = (digestRetry[roomId]?.failures ?? 0) + 1
            digestRetry[roomId] = (
                failures,
                Date().addingTimeInterval(GeminiCachePolicy.digestRetryDelay(consecutiveFailures: failures))
            )
            record(outcome, before: before, after: before, detail: detail)
            return
        }
        digestRetry[roomId] = nil

        let updated = ConversationDigest(segments: current.segments + [
            ConversationSegment(firstTurn: pending.firstTurn, lastTurn: pending.lastTurn, text: text)
        ])
        await MainActor.run {
            ChatRoomManager.shared.saveDigestForRoom(roomId: roomId, digest: updated)
        }
        record(.COMMITTED, before: before, after: pending.lastTurn)
    }

    func requestSegmentSummary(
        roomId: UUID,
        turns: [ConversationTurn],
        startingTurn: Int,
        mode: ChatMode,
        model: AIModel? = nil,
        apiKey: String
    ) async throws -> SegmentSummaryResult {
        let transcript = ConversationCompactor.transcript(for: turns, startingTurn: startingTurn, mode: mode)
        guard !transcript.isEmpty else { return .empty }

        let userText = "다음은 정리할 대화 구간이다.\n\n" + transcript
        // **사고 수준을 낮추는 것은 챗봇 요약에만 적용합니다.** 멘토 요약은 수식 풀이를
        // 다루고, 같은 결함이 있는지 아직 따로 확인하지 않았습니다. 멘토는 예전 값 그대로입니다.
        let generation: [String: Any] = mode == .companion
            ? [
                // 사고 토큰도 이 예산에서 함께 씁니다. 본문 분량에 사고 몫을 따로 얹습니다 —
                // 본문만큼만 주면 사고가 먼저 채우고 요약이 문장 한가운데서 잘립니다.
                "maxOutputTokens": GeminiCachePolicy.outputBudget(
                    bodyTokens: ConversationCompactor.segmentTokenBudget(for: mode) + 1200),
                // 구간 요약은 한 번 만들면 그 방에 계속 남으므로 생각할 값어치가 있습니다 —
                // **다만 생각하다 잘려서 아무것도 안 나오면 값어치가 0입니다.**
                // 근거는 `GeminiCachePolicy.digestThinkingLevel`에 적었습니다.
                "thinkingConfig": ["thinkingLevel": GeminiCachePolicy.digestThinkingLevel]
            ]
            : [
                "maxOutputTokens": ConversationCompactor.segmentTokenBudget(for: mode) + 1200,
                "thinkingConfig": ["thinkingLevel": "high"]
            ]
        let systemText = ConversationCompactor.summaryInstruction(for: mode)
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemText]]],
            "contents": [["role": "user", "parts": [["text": userText]]]],
            "generationConfig": generation
        ]

        let startedAt = Date()
        // 측정 장부에 모델을 적어야 하므로 보내기 전에 정합니다(`postGemini`와 같은 규칙).
        let requestModel: AIModel
        if let model { requestModel = model } else { requestModel = await auxiliaryModel(for: roomId) }
        let json = try await postGemini(body: body, apiKey: apiKey, roomId: roomId, model: requestModel)

        // 요약 요청도 측정합니다. **사고 토큰을 따로 봅니다** — 사고가 예산을 다 먹어
        // 본문이 잘리는지가 이 호출의 가장 큰 위험이라, 그걸 바로 볼 수 있어야 합니다.
        if mode == .companion {
            let usage = json["usageMetadata"] as? [String: Any] ?? [:]
            let thoughts = intValue(usage["thoughtsTokenCount"])
            let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
            let observation = RequestObservation(
                roomKey: roomId.uuidString,
                inputTokens: intValue(usage["promptTokenCount"]) + intValue(usage["toolUsePromptTokenCount"]),
                cachedInputTokens: intValue(usage["cachedContentTokenCount"]),
                outputTokens: intValue(usage["candidatesTokenCount"]) + thoughts,
                estimatedPromptTokens: TokenEstimator.textTokens(systemText) + TokenEstimator.textTokens(userText),
                unreported: usage.isEmpty,
                prompt: PromptTokenBreakdown(stableSystemTokens: TokenEstimator.textTokens(systemText)),
                ttftMillis: elapsed,
                totalMillis: elapsed,
                thoughtsTokens: thoughts,
                workload: .MEMORY,
                sentAt: startedAt,
                explicitCache: false,
                model: requestModel.rawValue
            )
            Task { @MainActor in OptimizationMeasurementStore.shared.observeRequest(observation) }
        }

        guard let candidates = json["candidates"] as? [[String: Any]],
              let candidate = candidates.first else {
            return .noCandidate
        }

        // 잘린 요약은 저장하지 않습니다. 한 번 넣으면 고치지 않는 기록이라
        // 중간에서 끊긴 글이 그 구간의 기억으로 영영 남습니다.
        if let reason = candidate["finishReason"] as? String, reason != "STOP" {
            return .notStop(reason)
        }

        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .empty : .text(text)
    }

}
