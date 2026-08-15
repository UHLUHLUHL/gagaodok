package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.model.SwiftDateSerializer
import com.sapiens.gagaodok.model.UuidSerializer
import kotlinx.serialization.Serializable
import java.util.UUID
import kotlin.math.min

/// 대화 앞부분을 대신하는 구간 요약 한 조각입니다.
///
/// 한 번 쓰면 다시 건드리지 않습니다. 이전 요약을 다시 넣어 새 요약을 만드는 방식은
/// 갱신할 때마다 사본의 사본이 되어 초반 내용이 형체를 잃습니다.
@Serializable
data class ConversationSegment(
    @Serializable(with = UuidSerializer::class)
    val id: UUID = UUID.randomUUID(),
    val firstTurn: Int,   // 1부터 셉니다
    val lastTurn: Int,
    val text: String,
    @Serializable(with = SwiftDateSerializer::class)
    val createdAt: Long = System.currentTimeMillis()
) {
    val turnCount: Int get() = lastTurn - firstTurn + 1
}

/// 한 방의 요약 전체입니다.
@Serializable
data class ConversationDigest(
    val segments: List<ConversationSegment> = emptyList()
) {
    /// 요약이 덮고 있는 마지막 턴 번호입니다. 그 다음 턴부터가 원문으로 나갑니다.
    val coveredTurns: Int get() = segments.lastOrNull()?.lastTurn ?: 0

    val isEmpty: Boolean get() = segments.isEmpty()
}

/// 요청에 실을 이력을 정합니다. API도 화면도 모르는 순수 계산이라 그대로 시험해 볼 수 있습니다.
object ConversationCompactor {
    /// 이 턴 수를 넘기기 전에는 아무것도 하지 않습니다.
    /// 손익분기가 60~70턴 언저리인데, 그 근처에서 켜 봐야 아끼는 돈은 없고 기억만 먼저 잃습니다.
    const val THRESHOLD_TURNS = 150

    /// 어떤 경우에도 이만큼은 원문 그대로 보냅니다.
    const val VERBATIM_WINDOW_TURNS = 20

    /// 요약을 다시 만드는 간격입니다. 한 번 만들 때 이만큼씩 흡수합니다.
    /// 매 턴 만들면 캐시가 매번 깨져 압축을 안 하느니만 못합니다.
    const val REFRESH_PERIOD_TURNS = 50

    /// 구간 하나를 적는 데 쓰는 토큰입니다. 50턴을 한글 1,800자쯤으로 줄이는 분량입니다.
    ///
    /// 처음에 1,000으로 잡았는데 실제로 돌려보니 모델이 1,470토큰을 썼고, 넘긴 만큼이
    /// 버릴 내용이 아니라 살릴 값어치가 있는 내용이었습니다.
    const val SEGMENT_TOKEN_BUDGET = 1500

    /// 원문 구간은 창과 창+주기 사이를 오갑니다. 이 값을 넘으면 요약을 새로 만듭니다.
    private const val REFRESH_TRIGGER_TURNS = VERBATIM_WINDOW_TURNS + REFRESH_PERIOD_TURNS

    /// 구간 요약을 만들 때 주는 지침입니다.
    ///
    /// 실제 대화 50턴을 손으로 요약해 보고 무엇이 남을 값어치가 있었는지 추린 것입니다.
    val SUMMARY_INSTRUCTION = """
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
    """.trimIndent()

    /// 요약에 넘길 대화를 글로 폅니다. 앱과 검증 도구가 같은 입력을 만들도록 여기 둡니다.
    ///
    /// 사진은 넣지 않습니다. 무엇을 찍은 사진이었는지는 앞뒤 대화에 이미 적혀 있고,
    /// 이미지를 함께 올리면 요약 한 번에 수천 토큰이 더 듭니다.
    /// 턴 번호를 반드시 함께 넘깁니다. 번호 없이 넘겼더니 모델이 줄 수를 세어 번호를 지어냈습니다.
    fun transcript(turns: List<ConversationTurn>, startingTurn: Int): String {
        val lines = mutableListOf<String>()
        var turnNumber = startingTurn - 1
        for (turn in turns) {
            if (turn.sender == MessageSender.USER) turnNumber += 1
            if (turn.text.startsWith("요청을 처리하는 중 오류가 발생했습니다:")) continue
            val who = if (turn.sender == MessageSender.USER) "학습자" else "답변자"
            var line = turn.text
            if (turn.attachment != null) line = "[사진 첨부] $line"
            if (line.isBlank()) continue
            lines += "[${turnNumber}턴] $who: $line"
        }
        return lines.joinToString("\n")
    }

    /// 아직 요약되지 않은, 이번에 요약해야 할 구간입니다.
    data class PendingSegment(
        val firstTurn: Int,
        val lastTurn: Int,
        val turns: List<ConversationTurn>
    )

    data class Plan(
        /// 맨 앞에 붙일 요약입니다. 압축 전이면 null입니다.
        val digestText: String?,
        /// 원문 그대로 보낼 대화입니다.
        val verbatimTurns: List<ConversationTurn>,
        /// 응답을 받은 뒤 백그라운드에서 만들 요약입니다.
        val pending: PendingSegment?,
        /// 진단용입니다.
        val totalTurns: Int,
        val coveredTurns: Int
    )

    /// 사용자 발화를 기준으로 턴을 셉니다. 한 턴은 사용자 발화 하나와 그에 딸린 답변들입니다.
    private fun userTurnStarts(conversation: List<ConversationTurn>): List<Int> =
        conversation.indices.filter { conversation[it].sender == MessageSender.USER }

    /// 사용자 발화 기준 총 턴 수입니다.
    fun turnCount(conversation: List<ConversationTurn>): Int = userTurnStarts(conversation).size

    /// 1부터 세는 턴 번호 범위를 배열 구간으로 바꿉니다.
    fun slice(conversation: List<ConversationTurn>, from: Int, to: Int): List<ConversationTurn> {
        val starts = userTurnStarts(conversation)
        if (from < 1 || from > starts.size) return emptyList()
        val begin = starts[from - 1]
        val end = if (to < starts.size) starts[to] else conversation.size
        if (begin >= end) return emptyList()
        return conversation.subList(begin, end).toList()
    }

    fun plan(conversation: List<ConversationTurn>, digest: ConversationDigest?): Plan {
        val starts = userTurnStarts(conversation)
        val total = starts.size
        val actual = digest ?: ConversationDigest()
        val covered = min(actual.coveredTurns, total)

        // 아직 켤 때가 아니면 지금까지처럼 전부 보냅니다.
        if (total < THRESHOLD_TURNS) {
            return Plan(null, conversation, null, total, 0)
        }

        val verbatimCount = total - covered
        var pending: PendingSegment? = null
        if (verbatimCount >= REFRESH_TRIGGER_TURNS) {
            val first = covered + 1
            val last = covered + REFRESH_PERIOD_TURNS
            pending = PendingSegment(first, last, slice(conversation, first, last))
        }

        // 이번 요청은 이미 만들어져 있는 요약까지만 씁니다.
        // 방금 정한 구간은 아직 글이 없으므로 다음 요청부터 반영됩니다.
        val verbatim = if (covered >= total) emptyList() else slice(conversation, covered + 1, total)
        return Plan(
            digestText = if (actual.isEmpty) null else render(actual),
            verbatimTurns = verbatim,
            pending = pending,
            totalTurns = total,
            coveredTurns = covered
        )
    }

    /// 요약을 요청 맨 앞에 넣을 글로 만듭니다.
    fun render(digest: ConversationDigest): String {
        val lines = mutableListOf(
            "# 이전 대화 요약",
            "",
            "아래는 이 대화방의 앞부분을 구간별로 정리한 기록이다.",
            "원문은 이 요청에 실려 있지 않으므로, 이 내용을 그때의 기억으로 삼아 이어서 대화한다.",
            "요약에 적힌 미해결 항목과 지도 참고 사항은 지금도 유효한 것으로 간주한다.",
            ""
        )
        for (segment in digest.segments) {
            lines += "[${segment.firstTurn}~${segment.lastTurn}턴]"
            lines += segment.text
            lines += ""
        }
        return lines.joinToString("\n")
    }
}
