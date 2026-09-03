import Foundation
import AppKit
import CryptoKit

/// 두 공급자에 답변을 요청하는 곳입니다.
///
/// 이 파일에는 액터 자신과 상태만 둡니다. 실제 일은 옆의 `GeminiService+*.swift`에
/// 나눠 두었습니다. 파일 이름이 곧 목차입니다.
///
/// - `+Conversation` 대화 한 턴 보내기
/// - `+PrefixCache`  명시적 캐시 규칙
/// - `+Digest`       구간 요약
/// - `+Persona`      말투 찾기·미리보기
/// - `+OpenAI`       Luna 쪽 길
/// - `+Transport`    요청 한 건과 장부 기록
/// - `+Bubbles`      답변을 말풍선으로 가르기
///
/// 멤버가 `private`이 아닌 것은 그 파일들에서 보여야 하기 때문입니다.
/// 앱은 모듈 하나라 `internal`이 곧 앱 전용입니다.
public actor GeminiService {
    public static let shared = GeminiService()

    let resilientSession: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        resilientSession = URLSession(configuration: configuration)
    }

    static let geminiBaseURL = "https://generativelanguage.googleapis.com/v1beta"

    var prefixCaches: [UUID: PrefixCache] = GeminiService.loadPrefixCaches() {
        didSet { persistPrefixCaches() }
    }

    var refreshingRooms: Set<UUID> = []
    /// 같은 방의 요약을 두 번 겹쳐 만들지 않도록 막습니다.
    var summarizingRooms: Set<UUID> = []

    /// 방마다 **직전** 요청 시각입니다. 대화가 이어지는 중인지 보는 데 씁니다.
    ///
    /// 메모리에만 둡니다. 앱을 껐다 켜면 비어 있어서 그 방의 캐시가 한 메시지 늦게
    /// 만들어집니다. 파일로 남길 값어치는 없다고 봤습니다.
    var lastRequestAt: [UUID: Date] = [:]

    public func generateResponse(
        conversation: [ConversationTurn],
        botName: String = "사피엔스",
        roomId: UUID? = nil,
        model requestedModel: AIModel? = nil,
        persona: PersonaStyle? = nil,
        mode: ChatMode = .mathMentor,
        roleplayInProgress: Bool = false
    ) async throws -> GeneratedAIResponse {
        let model = await MainActor.run { requestedModel ?? ModelSelectionManager.shared.selectedModel }
        let rawText: String
        switch model {
        case .gemini38Flash, .gemini37Flash:
            rawText = try await sendGeminiRequest(
                conversation: conversation, botName: botName, roomId: roomId, persona: persona, mode: mode
            )
        case .gpt56Luna:
            rawText = try await sendOpenAIRequest(
                conversation: conversation, botName: botName, roomId: roomId, persona: persona, mode: mode
            )
        }
        return GeneratedAIResponse(
            rawText: rawText,
            bubbles: await parseResponseIntoBubbles(
                rawText: rawText, botName: botName,
                roleplay: mode == .companion && roleplayInProgress,
                preserveMentorMath: mode == .mathMentor
            )
        )
    }

    /// 답변을 말풍선이 완성되는 대로 흘려보냅니다.
    ///
    /// 글자 단위로 올리지 않는 이유는 청크가 수식 한가운데서 끊기기 때문입니다.
    /// `StreamingBubbleBuffer`가 구분자가 모두 닫힌 문단만 통과시키므로
    /// 깨진 수식이 화면에 뜨는 일이 없습니다.
    ///
    /// Gemini만 스트리밍합니다. Luna는 지금처럼 한 번에 받습니다.
    public func streamResponse(
        conversation: [ConversationTurn],
        botName: String = "사피엔스",
        roomId: UUID? = nil,
        model requestedModel: AIModel? = nil,
        persona: PersonaStyle? = nil,
        mode: ChatMode = .mathMentor,
        roleplayInProgress: Bool = false,
        onBubble: @Sendable @escaping (GeneratedMessageBubble) async -> Void
    ) async throws -> String {
        let model = await MainActor.run { requestedModel ?? ModelSelectionManager.shared.selectedModel }
        guard model.isGemini else {
            let response = try await generateResponse(
                conversation: conversation, botName: botName, roomId: roomId,
                model: model, persona: persona, mode: mode, roleplayInProgress: roleplayInProgress
            )
            for bubble in response.bubbles { await onBubble(bubble) }
            return response.rawText
        }
        return try await sendGeminiRequest(
            conversation: conversation, botName: botName, roomId: roomId, persona: persona,
            mode: mode, roleplayInProgress: roleplayInProgress, onBubble: onBubble
        )
    }

}
