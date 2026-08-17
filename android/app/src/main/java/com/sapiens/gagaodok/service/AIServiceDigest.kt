package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ConversationTurn
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

// 대화가 길어진 방의 앞부분을 구간 요약으로 갈아끼웁니다.
/// 한 구간을 요약해 방의 요약 목록 뒤에 붙입니다.
///
/// 실패하면 아무것도 바꾸지 않습니다. 그러면 다음 요청에서 같은 구간을 다시 시도하고,
/// 그때까지는 그 구간이 원문으로 나가므로 대화에는 영향이 없습니다.
internal fun AIService.appendDigestSegment(
    roomId: UUID,
    pending: ConversationCompactor.PendingSegment,
    mode: ChatMode,
    apiKey: String
) {
    val key = roomId.toString()
    synchronized(summarizingRooms) {
        if (key in summarizingRooms) return
        summarizingRooms += key
    }
    try {
        // 그 사이 다른 요청이 같은 구간을 이미 채웠을 수 있습니다.
        val current = store.loadDigest(roomId)
        if (current.coveredTurns >= pending.lastTurn) return

        val text = requestSegmentSummary(roomId, pending.turns, pending.firstTurn, mode, apiKey)
        if (text.isEmpty()) return

        store.saveDigest(
            roomId,
            current.copy(
                segments = current.segments + ConversationSegment(
                    firstTurn = pending.firstTurn,
                    lastTurn = pending.lastTurn,
                    text = text
                )
            )
        )
    } finally {
        synchronized(summarizingRooms) { summarizingRooms -= key }
    }
}

internal fun AIService.requestSegmentSummary(
    roomId: UUID,
    turns: List<ConversationTurn>,
    startingTurn: Int,
    mode: ChatMode,
    apiKey: String
): String {
    val transcript = ConversationCompactor.transcript(turns, startingTurn, mode)
    if (transcript.isEmpty()) return ""

    val body = JSONObject()
        .put(
            "systemInstruction",
            JSONObject().put(
                "parts",
                JSONArray().put(
                    JSONObject().put("text", ConversationCompactor.summaryInstruction(mode))
                )
            )
        )
        .put(
            "contents",
            JSONArray().put(
                JSONObject().put("role", "user").put(
                    "parts",
                    JSONArray().put(JSONObject().put("text", "다음은 정리할 대화 구간이다.\n\n$transcript"))
                )
            )
        )
        .put(
            "generationConfig",
            JSONObject()
                // 지시한 분량보다 넉넉히 잡습니다. 사고 토큰도 이 예산에서 함께 쓰고,
                // 모자라면 문장 한가운데서 잘린 글이 나옵니다.
                .put("maxOutputTokens", ConversationCompactor.SEGMENT_TOKEN_BUDGET + 1200)
                .put("thinkingConfig", JSONObject().put("thinkingLevel", "low"))
        )

    val json = runCatching { postGemini(body, apiKey, roomId) }.getOrNull() ?: return ""
    val candidate = json.optJSONArray("candidates")?.optJSONObject(0) ?: return ""

    // 잘린 요약은 저장하지 않습니다. 한 번 넣으면 고치지 않는 기록이라
    // 중간에서 끊긴 글이 그 구간의 기억으로 영영 남습니다.
    // 빈 값을 돌려주면 다음 요청에서 같은 구간을 다시 시도합니다.
    val reason = candidate.optString("finishReason")
    if (reason.isNotEmpty() && reason != "STOP") return ""

    return joinParts(candidate).trim()
}

// MARK: - 말투 조사 / 미리보기
