import Foundation

/// 맥에서 답을 다시 받는 흐름을 이어 붙여, 재생성 보호가 실제로 켜지는지 확인합니다.
///
/// 폰에서 "재요청은 길이를 1 이상 줄인다"고 가정했다가, 실제 흐름에서는 **길이가
/// 그대로**라 보호가 한 번도 켜지지 않은 적이 있습니다(`a1a9c6e`). 숫자를 손으로
/// 넣지 않고 실제 턴 묶기 함수(`ConversationTurn.from`)로 길이를 잽니다.
///
/// 한계: 수정 재전송의 자르기는 `SingleChatRoomView.handleSendOrEdit` 안의 비공개
/// 코드라 부를 수 없어 같은 식(`messages.prefix(through:)` 후 그 칸 교체)으로 옮겼습니다.
/// 요청 엔트리 수는 `buildGeminiContents` 대신 턴 수로 셉니다 — 글만 있는 턴에서는 같습니다.
///
/// 실행:
///   swiftc -parse-as-library Tests/KakaoSapiensTests/RerollShrinkFlowTests.swift \
///     Sources/KakaoSapiens/Models/Message.swift Sources/KakaoSapiens/Services/ImageBudget.swift \
///     Sources/KakaoSapiens/Services/TokenEstimator.swift Sources/KakaoSapiens/Services/GeminiCachePolicy.swift \
///     Sources/KakaoSapiens/Models/AIModel.swift -o /tmp/reroll-tests && /tmp/reroll-tests
@main
struct RerollShrinkFlowTests {
    static func main() {
        sameTextResendKeepsLength()
        editedResendKeepsLength()
        multiBubbleAnswerIsOneTurn()
        olderEditActuallyShrinks()
        lagKeepsCacheAliveAcrossReroll()
        print("RerollShrinkFlowTests: 모두 통과")
    }

    static func user(_ text: String) -> ChatMessage { ChatMessage(sender: .user, text: text) }

    static func answer(_ bubbles: [String]) -> [ChatMessage] {
        let turn = UUID()
        return bubbles.enumerated().map { i, text in
            ChatMessage(sender: .sapiens, text: text, turnId: turn,
                        canonicalText: i == 0 ? bubbles.joined(separator: "\n\n") : nil)
        }
    }

    /// 사용자 31마디 + 답 31번 + 마지막 사용자 한 마디 = 63턴. 이 요청이 그대로 캐시가 됩니다.
    static func room() -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for i in 0..<31 {
            messages.append(user("사용자 \(i)"))
            messages += answer(["답변 \(i)"])
        }
        messages.append(user("마지막 질문"))
        return messages
    }

    static func size(_ messages: [ChatMessage]) -> Int { ConversationTurn.from(messages: messages).count }

    /// `SingleChatRoomView.handleSendOrEdit`와 같은 자르기입니다.
    static func resend(_ messages: [ChatMessage], editing id: UUID, with text: String) -> [ChatMessage] {
        let idx = messages.firstIndex { $0.id == id }!
        var truncated = Array(messages.prefix(through: idx))
        let target = truncated[idx]
        truncated[idx] = ChatMessage(id: target.id, sender: .user, text: text,
                                     attachment: target.attachment, turnId: target.turnId ?? UUID(),
                                     canonicalText: text)
        return truncated
    }

    static func judged(_ covered: Int, _ newSize: Int) -> Bool {
        GeminiCachePolicy.isRerollShrink(cacheDigestCoveredTurns: 0, requestDigestCoveredTurns: 0,
                                         coveredTurns: covered, newSize: newSize)
    }

    static func sameTextResendKeepsLength() {
        let r = room()
        let covered = size(r)
        let after = r + answer(["방금 받은 답"])
        let resent = resend(after, editing: r.last!.id, with: "마지막 질문")
        precondition(covered == 63 && size(resent) == 63, "재요청은 길이를 되돌린다: \(covered)→\(size(resent))")
        precondition(size(resent) <= covered, "캐시는 SHRUNK으로 걸린다")
        precondition(judged(covered, size(resent)), "그리고 재요청으로 판정되어 보호가 켜진다")
    }

    static func editedResendKeepsLength() {
        let r = room()
        let after = r + answer(["방금 받은 답"])
        let resent = resend(after, editing: r.last!.id, with: "완전히 다른 이야기")
        precondition(size(resent) == size(r), "문구를 바꿔도 길이는 같다")
        precondition(judged(size(r), size(resent)))
    }

    // 말풍선이 셋이어도 한 턴이다. 셋을 지운다고 세면 판정이 틀어진다.
    static func multiBubbleAnswerIsOneTurn() {
        let r = room()
        let after = r + answer(["첫째", "둘째", "셋째"])
        precondition(size(after) == size(r) + 1, "말풍선 셋은 한 턴")
        let resent = resend(after, editing: r.last!.id, with: "다시")
        precondition(size(resent) == size(r))
        precondition(judged(size(r), size(resent)))
    }

    static func olderEditActuallyShrinks() {
        let r = room()
        let after = r + answer(["방금 받은 답"])
        let users = after.filter { $0.sender == .user }
        let resent = resend(after, editing: users[users.count - 3].id, with: "고친 옛 메시지")
        precondition(size(resent) == size(r) - 4, "두 교환이 사라진다")
        precondition(judged(size(r), size(resent)), "크게 줄어도 요약이 그대로면 재요청이다")
    }

    // 두 칸을 물려 만든 캐시는 재요청 뒤에도 쓸 수 있다 — 길이가 캐시보다 길다.
    static func lagKeepsCacheAliveAcrossReroll() {
        let r = room()
        let lag = GeminiCachePolicy.lagEntries(entryCount: size(r), laggedPrefixTokens: 20_000, shrinkProne: true)
        precondition(lag == 2)
        let covered = size(r) - lag
        let after = r + answer(["방금 받은 답"])
        let resent = resend(after, editing: r.last!.id, with: "다시")
        precondition(size(resent) > covered, "캐시가 덮는 길이보다 길어 버리지 않는다")
        precondition(covered + lag >= size(resent), "새로 만들 것도 없다(CACHE_CURRENT)")
    }
}
