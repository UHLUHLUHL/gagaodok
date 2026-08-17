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

    func requestSegmentSummary(
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

}
