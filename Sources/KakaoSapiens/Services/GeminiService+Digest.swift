import Foundation

/// 대화가 길어진 방의 앞부분을 구간 요약으로 갈아끼웁니다.
extension GeminiService {
    /// 한 구간을 요약해 방의 요약 목록 뒤에 붙입니다.
    ///
    /// 실패하면 아무것도 바꾸지 않습니다. 그러면 다음 요청에서 같은 구간을 다시 시도하고,
    /// 그때까지는 그 구간이 원문으로 나가므로 대화에는 영향이 없습니다.
    func appendDigestSegment(
        roomId: UUID,
        pending: ConversationCompactor.PendingSegment,
        mode: ChatMode,
        model: AIModel? = nil,
        apiKey: String
    ) async {
        guard !summarizingRooms.contains(roomId) else { return }
        // **실패가 이어지면 잠시 쉽니다.** 예전에는 실패하면 다음 요청에서 바로 다시
        // 시도했으므로, 요약이 계속 실패하는 방은 메시지를 보낼 때마다 유료 요약을
        // 하나씩 만들고 버렸습니다. 기다리는 동안 그 구간은 원문으로 나가므로 대화에는
        // 영향이 없습니다.
        if let retry = digestRetry[roomId], Date() < retry.notBefore { return }
        summarizingRooms.insert(roomId)
        defer { summarizingRooms.remove(roomId) }

        // 그 사이 다른 요청이 같은 구간을 이미 채웠을 수 있습니다.
        let current = await MainActor.run { ChatRoomManager.shared.loadDigestForRoom(roomId: roomId) }
        guard current.coveredTurns < pending.lastTurn else { return }

        guard let text = try? await requestSegmentSummary(
            roomId: roomId, turns: pending.turns, startingTurn: pending.firstTurn,
            mode: mode, model: model, apiKey: apiKey),
              !text.isEmpty else {
            let failures = (digestRetry[roomId]?.failures ?? 0) + 1
            digestRetry[roomId] = (
                failures,
                Date().addingTimeInterval(GeminiCachePolicy.digestRetryDelay(consecutiveFailures: failures))
            )
            return
        }
        digestRetry[roomId] = nil

        let updated = ConversationDigest(segments: current.segments + [
            ConversationSegment(firstTurn: pending.firstTurn, lastTurn: pending.lastTurn, text: text)
        ])
        await MainActor.run {
            ChatRoomManager.shared.saveDigestForRoom(roomId: roomId, digest: updated)
        }
    }

    func requestSegmentSummary(
        roomId: UUID,
        turns: [ConversationTurn],
        startingTurn: Int,
        mode: ChatMode,
        model: AIModel? = nil,
        apiKey: String
    ) async throws -> String {
        let transcript = ConversationCompactor.transcript(for: turns, startingTurn: startingTurn, mode: mode)
        guard !transcript.isEmpty else { return "" }

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
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": ConversationCompactor.summaryInstruction(for: mode)]]],
            "contents": [["role": "user", "parts": [["text": userText]]]],
            "generationConfig": generation
        ]

        let json = try await postGemini(body: body, apiKey: apiKey, roomId: roomId, model: model)
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

}
