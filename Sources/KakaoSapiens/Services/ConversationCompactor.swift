import Foundation

/// 대화 앞부분을 대신하는 구간 요약 한 조각입니다.
///
/// 한 번 쓰면 다시 건드리지 않습니다. 이전 요약을 다시 넣어 새 요약을 만드는 방식은
/// 갱신할 때마다 사본의 사본이 되어 초반 내용이 형체를 잃습니다.
public struct ConversationSegment: Codable, Equatable, Identifiable {
    public let id: UUID
    public let firstTurn: Int   // 1부터 셉니다
    public let lastTurn: Int
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), firstTurn: Int, lastTurn: Int, text: String, createdAt: Date = Date()) {
        self.id = id
        self.firstTurn = firstTurn
        self.lastTurn = lastTurn
        self.text = text
        self.createdAt = createdAt
    }

    public var turnCount: Int { lastTurn - firstTurn + 1 }
}

/// 한 방의 요약 전체입니다.
public struct ConversationDigest: Codable, Equatable {
    public var segments: [ConversationSegment]

    public init(segments: [ConversationSegment] = []) {
        self.segments = segments
    }

    /// 요약이 덮고 있는 마지막 턴 번호입니다. 그 다음 턴부터가 원문으로 나갑니다.
    public var coveredTurns: Int { segments.last?.lastTurn ?? 0 }

    public var isEmpty: Bool { segments.isEmpty }
}

/// 요청에 실을 이력을 정합니다. API도 화면도 모르는 순수 계산이라 그대로 시험해 볼 수 있습니다.
public enum ConversationCompactor {
    private struct CompactionPolicy {
        let thresholdTurns: Int
        let verbatimWindowTurns: Int
        let refreshPeriodTurns: Int

        var refreshTriggerTurns: Int { verbatimWindowTurns + refreshPeriodTurns }
    }

    /// 멘토는 최근 풀이 20턴을 원문으로 보존하고, 앞의 40턴씩 구간 요약으로 바꿉니다.
    /// 문턱을 창+주기와 같은 60턴으로 두어 첫 압축 시점을 설정값 그대로 드러냅니다.
    private static let mentorPolicy = CompactionPolicy(
        thresholdTurns: 60,
        verbatimWindowTurns: 20,
        refreshPeriodTurns: 40
    )

    /// 챗봇 정책은 멘토 정책과 독립적입니다. 캐릭터 대화의 최근 기억 폭과 요약 주기를
    /// 바꾸지 않도록 기존 80/30/50 값을 그대로 둡니다.
    private static let companionPolicy = CompactionPolicy(
        thresholdTurns: 80,
        verbatimWindowTurns: 30,
        refreshPeriodTurns: 50
    )

    private static func compactionPolicy(for mode: ChatMode) -> CompactionPolicy {
        switch mode {
        case .mathMentor: return mentorPolicy
        case .companion: return companionPolicy
        }
    }

    /// 구간 하나를 적는 데 쓰는 토큰입니다. 멘토 40턴 또는 챗봇 50턴을
    /// 한글 1,800자쯤으로 줄이는 분량입니다.
    ///
    /// 처음에 1,000으로 잡았는데 실제로 돌려보니 모델이 1,470토큰을 썼고, 넘긴 만큼이
    /// 버릴 내용이 아니라 살릴 값어치가 있는 내용이었습니다. 지시로 억누르기보다
    /// 실제 산출에 맞춰 올렸습니다. 이래도 압축 안 할 때보다 4배 넘게 쌉니다.
    public static let segmentTokenBudget = 1500

    /// 구간 요약을 만들 때 주는 지침입니다. **모드마다 다릅니다.**
    ///
    /// 한동안 과외용 하나뿐이었습니다. 챗봇 방에도 그게 그대로 나갔는데, 캐릭터 대화를
    /// "학습자의 상황 / 틀린 지점 / 이해가 뚫린 순간 / 지도 참고" 틀에 넣으면 살려야 할
    /// 것 — 관계, 서로 부르는 법, 주고받은 약속, 감정의 결, 아직 안 풀린 긴장 — 이
    /// 하나도 안 남습니다. 압축이 기억을 **줄이는** 것이 아니라 **버리는** 것이 됩니다.
    ///
    /// 요약은 한 번 쓰면 다시 안 만들기 때문에 그 손실은 되돌릴 수 없습니다.
    ///
    /// 전송 코드가 아니라 여기 둡니다. 무엇을 남기고 무엇을 버릴지는 압축 정책이고,
    /// 품질을 확인하는 별도 도구도 같은 글을 그대로 써야 시험이 성립합니다.
    public static func summaryInstruction(for mode: ChatMode) -> String {
        switch mode {
        case .mathMentor: return mentorSummaryInstruction
        case .companion: return companionSummaryInstruction
        }
    }

    /// 실제 대화 50턴을 손으로 요약해 보고 무엇이 남을 값어치가 있었는지 추린 것입니다.
    /// 대화의 89%는 답변자가 쓴 글이고 그중 상당수가 연결어와 격려 문구라 덜어낼 여지가 큽니다.
    /// 반면 학습자가 직접 쓴 말은 11%뿐인데, 되살릴 수 없는 것은 그쪽입니다.
    static let mentorSummaryInstruction = """
    당신은 과외 대화 기록을 정리하는 사람이다. 아래 대화 구간을 나중에 읽고 그때를 기억할 수 있도록 정리한다.

    # 반드시 남길 것
    - 학습자의 상황: 목표, 진도, 아직 안 배운 영역, 말투나 호칭 같은 관계 설정, 주고받은 약속
    - 흐름: 어떤 문제를 어떤 순서로 다뤘는지. 턴 번호를 함께 적는다.
    - 틀린 지점: 무엇을 어떻게 틀렸고 정답은 무엇이며 왜 틀렸는지. 원인까지 반드시 적는다.
    - 이해가 뚫린 순간: 어떤 설명이 통했고 어떤 설명이 안 통했는지
    - 미해결: 답을 못 낸 문제, 나중에 하기로 한 것
    - 사진을 주고받았다면 무엇을 찍은 사진이었는지

    # 버릴 것
    - 인사, 맞장구, 감탄사, 잡담
    - 풀이의 중간 계산 과정. 결론과 핵심 아이디어만 남긴다.
    - 답변자의 격려나 마무리 문구
    - 전송 오류 메시지

    # 턴 번호
    각 줄 앞에 [n턴]이 붙어 있다. 요약에 턴 번호를 적을 때는 반드시 그 번호를 그대로 쓴다.
    번호를 새로 세거나 짐작해서 적지 않는다. 범위를 적을 때도 실제로 등장한 번호만 쓴다.

    # 형식
    아래 여섯 소제목을 이 순서로 그대로 쓴다. 각 줄은 '- '로 시작하는 평서문으로 적는다.
    해당 내용이 없는 절은 소제목만 두고 비운다.

    ■ 상황
    한 줄로 뭉치지 말고 아래를 각각 한 줄씩 적는다. 대화에서 드러난 것만 적는다.
    - 목표: 무엇을 준비하고 있는지
    - 진도: 지금 어느 단원이고 아직 안 배운 것은 무엇인지
    - 관계: 학습자가 반말을 쓰는지 존댓말을 쓰는지, 서로를 어떻게 부르는지, 대화 분위기는 어떤지.
      답변자 자신의 말투나 이름, 정체성은 적지 않는다. 그것은 매번 새로 정해지므로 옛 기록이 남으면 방해가 된다.
    - 약속: 나중에 하기로 한 것, 주고받은 다짐이나 농담 섞인 약속

    ■ 흐름
    - 다룬 주제를 순서대로. 각 줄 앞에 턴 번호를 붙인다.

    ■ 틀린 지점
    - 무엇을 어떻게 틀렸는지, 정답은 무엇인지, 왜 틀렸는지까지 한 줄에 담는다.

    ■ 이해가 뚫린 순간
    - 어떤 설명이 통했는지. 통하지 않았던 설명이 있었다면 그것도 함께 적는다.

    ■ 미해결
    - 답을 못 낸 문제와 나중에 하기로 한 것.

    ■ 지도 참고
    다음 대화를 이끄는 사람에게 넘기는 말이다. 아래를 각각 한 줄씩 적는다.
    - 강점: 무엇을 잘하는지
    - 약점: 어디서 자주 막히거나 실수하는지
    - 설명 방식: 어떻게 설명하면 잘 받아들이고 어떻게 하면 헤매는지

    # 분량
    한국어 1,800자를 넘기지 않는다.
    답변에는 정리한 내용만 담고 인사나 설명을 덧붙이지 않는다.
    """

    /// 챗봇 방의 요약 지침입니다.
    ///
    /// 과외 지침과 뼈대는 같지만 남길 것이 완전히 다릅니다. 여기서 기억이란
    /// 무엇을 배웠는지가 아니라 **둘 사이에 무슨 일이 있었는지**입니다.
    ///
    /// **답변자 자신의 정체성은 적지 않습니다.** 이름도 말투도 성격도 방의 말투
    /// 설정에서 매번 새로 정해집니다. 옛 요약에 그게 남아 있으면 지금 설정과 싸웁니다.
    /// 과외 지침에도 같은 규칙이 있고, 여기서는 더 중요합니다.
    static let companionSummaryInstruction = """
    당신은 두 사람이 나눈 대화 기록을 정리하는 사람이다. 아래 대화 구간을 나중에 읽고
    그때 무슨 일이 있었는지 떠올려 이어서 대화할 수 있도록 정리한다.

    # 반드시 남길 것
    - 관계: 서로를 뭐라 부르는지, 말을 놓는지 높이는지, 어떤 사이이고 분위기가 어떤지
    - 있었던 일: 어떤 장면과 사건이 어떤 순서로 있었는지. 턴 번호를 함께 적는다.
    - 주고받은 것: 약속, 다짐, 고백, 부탁, 그은 선, 삐친 일과 풀린 일
    - 감정의 결: 어디서 가까워졌고 어디서 멀어졌는지, 구간이 끝날 때 서로의 감정이 어떤지
    - 상대에 대해 알게 된 것: 사용자의 취향·사정·일상·습관 중 대화에서 드러난 것
    - 반복되는 것: 자주 나오는 농담, 서로만 아는 말, 되풀이되는 화제
    - 장면 상태: 구간이 끝나는 시점에 어디에서 무엇을 하는 중이었는지
    - 사진을 주고받았다면 무엇을 찍은 사진이었는지

    # 버릴 것
    - 인사, 맞장구, 같은 감정 표현의 반복
    - 대사를 그대로 옮기는 것. 무슨 일이 있었는지로 적는다.
      다만 나중에 다시 꺼낼 만한 한마디는 따옴표로 짧게 남겨도 된다.
    - 전송 오류 메시지
    - **답변자 자신의 말투·이름·성격·정체성.** 그것은 방의 말투 설정에서 매번 새로
      정해지므로 옛 기록이 남으면 지금 설정과 충돌한다. 절대 적지 않는다.

    # 턴 번호
    각 줄 앞에 [n턴]이 붙어 있다. 요약에 턴 번호를 적을 때는 반드시 그 번호를 그대로 쓴다.
    번호를 새로 세거나 짐작해서 적지 않는다. 범위를 적을 때도 실제로 등장한 번호만 쓴다.

    # 형식
    아래 여섯 소제목을 이 순서로 그대로 쓴다. 각 줄은 '- '로 시작하는 평서문으로 적는다.
    해당 내용이 없는 절은 소제목만 두고 비운다.

    ■ 관계
    한 줄로 뭉치지 말고 아래를 각각 한 줄씩 적는다. 대화에서 드러난 것만 적는다.
    - 호칭: 서로를 뭐라 부르는지
    - 말투: 사용자가 반말을 쓰는지 존댓말을 쓰는지
    - 사이: 어떤 관계이고 지금 어느 정도로 가까운지

    ■ 있었던 일
    - 장면과 사건을 순서대로. 각 줄 앞에 턴 번호를 붙인다.

    ■ 주고받은 것
    - 약속·다짐·고백·부탁·그은 선을 한 줄에 하나씩. 언제 있었는지 턴 번호를 붙인다.

    ■ 감정의 결
    - 가까워지거나 멀어진 지점과 그 계기. 구간이 끝날 때의 감정 상태로 마무리한다.

    ■ 사용자에 대해
    - 취향, 사정, 일상, 습관 중 대화에서 드러난 것.

    ■ 이어서
    다음 대화를 이어받는 사람에게 넘기는 말이다. 아래를 각각 한 줄씩 적는다.
    - 장면: 구간이 끝나는 시점에 어디에서 무엇을 하는 중이었는지
    - 미해결: 답 안 한 질문, 미룬 이야기, 풀리지 않은 긴장
    - 조심할 것: 건드리면 안 되는 화제나 상대가 그은 선

    # 분량
    한국어 1,800자를 넘기지 않는다.
    답변에는 정리한 내용만 담고 인사나 설명을 덧붙이지 않는다.
    """

    /// 요약에 넘길 대화를 글로 폅니다. 앱과 검증 도구가 같은 입력을 만들도록 여기 둡니다.
    ///
    /// 사진은 넣지 않습니다. 무엇을 찍은 사진이었는지는 앞뒤 대화에 이미 적혀 있고,
    /// 이미지를 함께 올리면 요약 한 번에 수천 토큰이 더 듭니다.
    /// 턴 번호를 반드시 함께 넘깁니다.
    ///
    /// 번호 없이 넘겼더니 모델이 줄 수를 세어 번호를 지어냈습니다. 50턴을 넣었는데
    /// 76턴까지 적어 놓는 식이라, 나중에 그 번호로 원문을 찾을 수 없게 됩니다.
    public static func transcript(for turns: [ConversationTurn], startingTurn: Int, mode: ChatMode) -> String {
        // 부르는 이름도 모드를 따릅니다. 캐릭터 대화를 "학습자/답변자"로 옮겨 놓으면
        // 요약하는 쪽이 그걸 수업 기록으로 읽습니다.
        let userLabel = mode == .companion ? "사용자" : "학습자"
        let botLabel = mode == .companion ? "상대" : "답변자"

        var lines: [String] = []
        var turnNumber = startingTurn - 1
        for turn in turns {
            if turn.sender == .user { turnNumber += 1 }
            guard !turn.text.hasPrefix("요청을 처리하는 중 오류가 발생했습니다:") else { continue }
            let who = turn.sender == .user ? userLabel : botLabel
            var line = turn.text
            if turn.attachment != nil { line = "[사진 첨부] " + line }
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            lines.append("[\(turnNumber)턴] \(who): \(line)")
        }
        return lines.joined(separator: "\n")
    }

    /// 아직 요약되지 않은, 이번에 요약해야 할 구간입니다.
    public struct PendingSegment {
        public let firstTurn: Int
        public let lastTurn: Int
        public let turns: [ConversationTurn]
    }

    public struct Plan {
        /// 맨 앞에 붙일 요약입니다. 압축 전이면 nil입니다.
        public let digestText: String?
        /// 원문 그대로 보낼 대화입니다.
        public let verbatimTurns: [ConversationTurn]
        /// 응답을 받은 뒤 백그라운드에서 만들 요약입니다.
        public let pending: PendingSegment?
        /// 진단용입니다.
        public let totalTurns: Int
        public let coveredTurns: Int
    }

    /// 사용자 발화를 기준으로 턴을 셉니다. 한 턴은 사용자 발화 하나와 그에 딸린 답변들입니다.
    static func userTurnStarts(_ conversation: [ConversationTurn]) -> [Int] {
        conversation.indices.filter { conversation[$0].sender == .user }
    }

    /// 사용자 발화 기준 총 턴 수입니다.
    public static func turnCount(_ conversation: [ConversationTurn]) -> Int {
        userTurnStarts(conversation).count
    }

    /// 1부터 세는 턴 번호 범위를 배열 구간으로 바꿉니다.
    public static func slice(_ conversation: [ConversationTurn], turns range: ClosedRange<Int>) -> [ConversationTurn] {
        let starts = userTurnStarts(conversation)
        guard range.lowerBound >= 1, range.lowerBound <= starts.count else { return [] }
        let from = starts[range.lowerBound - 1]
        let to = range.upperBound < starts.count ? starts[range.upperBound] : conversation.count
        guard from < to else { return [] }
        return Array(conversation[from..<to])
    }

    public static func plan(conversation: [ConversationTurn], digest: ConversationDigest?, mode: ChatMode) -> Plan {
        let starts = userTurnStarts(conversation)
        let total = starts.count
        let digest = digest ?? ConversationDigest()
        let covered = min(digest.coveredTurns, total)
        let policy = compactionPolicy(for: mode)

        // 아직 켤 때가 아니면 지금까지처럼 전부 보냅니다.
        guard total >= policy.thresholdTurns else {
            return Plan(digestText: nil, verbatimTurns: conversation, pending: nil,
                        totalTurns: total, coveredTurns: 0)
        }

        let verbatimCount = total - covered
        var pending: PendingSegment?
        if verbatimCount >= policy.refreshTriggerTurns {
            let first = covered + 1
            let last = covered + policy.refreshPeriodTurns
            pending = PendingSegment(firstTurn: first, lastTurn: last,
                                     turns: slice(conversation, turns: first...last))
        }

        // 이번 요청은 이미 만들어져 있는 요약까지만 씁니다.
        // 방금 정한 구간은 아직 글이 없으므로 다음 요청부터 반영됩니다.
        let verbatim = covered >= total ? [] : slice(conversation, turns: (covered + 1)...total)
        return Plan(
            digestText: digest.isEmpty ? nil : render(digest, mode: mode),
            verbatimTurns: verbatim,
            pending: pending,
            totalTurns: total,
            coveredTurns: covered
        )
    }

    /// 요약을 요청 맨 앞에 넣을 글로 만듭니다.
    public static func render(_ digest: ConversationDigest, mode: ChatMode) -> String {
        var lines = [
            "# 이전 대화 요약",
            "",
            "아래는 이 대화방의 앞부분을 구간별로 정리한 기록이다.",
            "원문은 이 요청에 실려 있지 않으므로, 이 내용을 그때의 기억으로 삼아 이어서 대화한다.",
            mode == .companion
                ? "요약에 적힌 관계와 약속, 아직 안 끝난 이야기는 지금도 그대로인 것으로 간주한다."
                : "요약에 적힌 미해결 항목과 지도 참고 사항은 지금도 유효한 것으로 간주한다.",
            ""
        ]
        for segment in digest.segments {
            lines.append("[\(segment.firstTurn)~\(segment.lastTurn)턴]")
            lines.append(segment.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
