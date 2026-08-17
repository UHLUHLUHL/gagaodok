import Foundation

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


/// 요청 한 건을 보내고, 오류를 읽고, 사용량을 장부에 적습니다.
///
/// **사용량을 적는 곳은 여기 하나입니다.** 여러 곳에 흩어져 있던 시절에는
/// 새로 만든 요청이 장부에서 조용히 빠졌습니다.
extension GeminiService {
    /// generateContent에 한 번 보내고 JSON을 돌려줍니다.
    ///
    /// **여기서 사용량을 함께 적습니다.** 예전에는 대화 답변만 장부에 적히고
    /// 이 길로 나가는 요청 — 구간 요약, 말투 조사, 말투 분석, 다듬기, 미리보기 — 은
    /// 하나도 안 적혔습니다. 말투 조사는 검색 그라운딩까지 켜는 무거운 요청인데
    /// 앱 화면에서는 공짜처럼 보였습니다. 요금이 과소평가되던 가장 큰 이유입니다.
    func postGemini(body: [String: Any], apiKey: String, roomId: UUID) async throws -> [String: Any] {
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
    func recordGeminiUsage(_ usage: [String: Any]?, roomId: UUID, model: AIModel) async {
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

    func recordUnreported(roomId: UUID, model: AIModel) async {
        await MainActor.run {
            TokenUsageManager.shared.recordUnreportedRequest(roomId: roomId, model: model)
        }
    }

    func validatedJSON(data: Data, response: URLResponse, provider: String) throws -> [String: Any] {
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

    func intValue(_ value: Any?) -> Int {
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
    func serviceError(_ message: String, retryable: Bool = false) -> NSError {
        NSError(
            domain: AIServiceError.domain,
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: message,
                AIServiceError.retryableKey: retryable
            ]
        )
    }

    func geminiEmptyResponseMessage(finishReason: String?) -> String {
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

}
