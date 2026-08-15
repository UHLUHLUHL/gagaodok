import Foundation

/// 상황극 답변에서 인물의 '대사'와 '묘사'를 갈라냅니다.
///
/// 판별 근거는 따옴표입니다. 태그를 새로 만들지 않은 이유가 있습니다.
/// `[상황]` 같은 표식은 모델이 한 번만 깜빡해도 그 글자가 화면에 그대로 뜹니다.
/// 따옴표는 새 나가도 그냥 따옴표라 흉하지 않고, 원문을 복사하거나 검색할 때도,
/// 나중에 대화를 요약할 때도 사람이 읽는 글로 남습니다.
///
/// 다만 따옴표만으로는 부족한 지점이 하나 있습니다. 평범한 잡담에서는 대사에
/// 따옴표를 치지 않으므로, 따옴표 없는 문단을 무조건 묘사로 보면 잡담이 전부
/// 묘사가 됩니다. 그래서 **한 턴 안에 따옴표 대사가 하나라도 있을 때만** 나머지
/// 따옴표 없는 문단을 묘사로 봅니다. 상황극이 아닌 방은 아무 영향을 받지 않습니다.
public enum RoleplayParser {
    /// 여는 따옴표와 짝이 되는 닫는 따옴표입니다.
    /// 한국어 상황극에서는 `"`와 `“ ”`가 대부분이고, 소설투에서 `「 」`가 섞입니다.
    private static let quotePairs: [(open: Character, close: Character)] = [
        ("\"", "\""), ("\u{201C}", "\u{201D}"), ("\u{300C}", "\u{300D}"), ("\u{300E}", "\u{300F}")
    ]

    /// 묘사를 감싸는 데 흔히 쓰이는 강조 기호입니다.
    /// 지침에서는 쓰지 말라고 했지만 모델이 습관적으로 붙이는 일이 잦아 함께 받아 줍니다.
    private static let emphasisMarks: [Character] = ["*", "_"]

    /// 이 문단이 통째로 따옴표 안에 들어 있으면 그 안쪽 글을 돌려줍니다.
    ///
    /// `"안녕" 하고 웃었다`처럼 대사와 묘사가 한 문단에 섞인 것은 nil입니다.
    /// 통째로 대사인 것만 대사로 봐야, 섞인 문단이 대사 말풍선에 들어가 묘사까지
    /// 인물이 소리 내어 말한 것처럼 보이는 일을 막습니다.
    public static func unwrappedDialogue(_ paragraph: String) -> String? {
        let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, let first = text.first, let last = text.last else { return nil }
        guard quotePairs.contains(where: { $0.open == first && $0.close == last }) else { return nil }

        let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return nil }
        // 따옴표가 중간에서 닫혔다 다시 열리면 한 덩어리 대사가 아닙니다.
        // `"어" 하고 답했다. "왜?"` 같은 문단이 여기서 걸러집니다.
        guard !inner.contains(first), !inner.contains(last) else { return nil }
        return inner
    }

    /// 별표나 밑줄로 감싼 묘사이면 그 안쪽 글을 돌려줍니다.
    public static func unwrappedEmphasis(_ paragraph: String) -> String? {
        let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3, let mark = text.first, emphasisMarks.contains(mark), text.last == mark else { return nil }
        let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty, !inner.contains(mark) else { return nil }
        return inner
    }

    /// 한 문단을 어떻게 보여줄지 정한 결과입니다.
    public struct Classified {
        public let text: String
        public let kind: MessageKind
    }

    /// 문단 하나를 분류합니다.
    ///
    /// - Parameter roleplayEstablished: 이 턴이 상황극이라고 이미 확인됐는지.
    ///   확인되기 전에는 따옴표 없는 문단을 묘사로 넘기지 않습니다.
    public static func classify(_ paragraph: String, roleplayEstablished: Bool) -> Classified {
        if let dialogue = unwrappedDialogue(paragraph) {
            // 따옴표는 표시용 기호일 뿐이라 말풍선에는 알맹이만 넣습니다.
            // 카카오톡 말풍선 안에 따옴표가 남아 있으면 사람이 쓴 메시지처럼 보이지 않습니다.
            return Classified(text: dialogue, kind: .speech)
        }
        if let described = unwrappedEmphasis(paragraph) {
            return Classified(text: described, kind: .narration)
        }
        let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        return Classified(text: text, kind: roleplayEstablished ? .narration : .speech)
    }

    /// 이 문단을 보고 나서 "이 턴은 상황극이다"라고 말할 수 있는지 봅니다.
    public static func establishesRoleplay(_ paragraph: String) -> Bool {
        unwrappedDialogue(paragraph) != nil || unwrappedEmphasis(paragraph) != nil
    }

    /// 지난 대화를 훑어 이 방이 상황극 중인지 판단합니다.
    ///
    /// 스트리밍은 문단이 완성되는 대로 화면에 붙이므로, 첫 문단을 붙이는 시점에는
    /// 그 턴에 따옴표 대사가 나올지 아직 모릅니다. 앞 턴에서 이미 상황극이었다면
    /// 그 사실을 미리 알려 주어 첫 문단부터 제대로 나오게 합니다.
    ///
    /// 마지막 AI 턴만 봅니다. 오래전에 한 번 상황극을 했다고 해서 지금 잡담까지
    /// 묘사로 처리되면 안 됩니다.
    public static func roleplayInProgress(messages: [ChatMessage]) -> Bool {
        guard let lastBotIndex = messages.lastIndex(where: { $0.sender == .sapiens }) else { return false }
        let lastTurnId = messages[lastBotIndex].turnId
        return messages[...lastBotIndex]
            .reversed()
            .prefix { $0.sender == .sapiens && $0.turnId == lastTurnId }
            .contains { $0.kind == .narration }
    }
}
