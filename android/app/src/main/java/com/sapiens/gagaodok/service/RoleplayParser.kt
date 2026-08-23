package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.MessageKind
import com.sapiens.gagaodok.model.MessageSender

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
object RoleplayParser {

    /// 여는 따옴표와 짝이 되는 닫는 따옴표입니다.
    /// 한국어 상황극에서는 `"`와 `“ ”`가 대부분이고, 소설투에서 `「 」`가 섞입니다.
    private val quotePairs = listOf(
        '"' to '"',
        '“' to '”',
        '「' to '」',
        '『' to '』'
    )

    /// 묘사를 감싸는 데 흔히 쓰이는 강조 기호입니다.
    /// 지침에서는 쓰지 말라고 했지만 모델이 습관적으로 붙이는 일이 잦아 함께 받아 줍니다.
    private val emphasisMarks = listOf('*', '_')

    /// 이 문단이 통째로 따옴표 안에 들어 있으면 그 안쪽 글을 돌려줍니다.
    ///
    /// `"안녕" 하고 웃었다`처럼 대사와 묘사가 한 문단에 섞인 것은 null입니다.
    /// 통째로 대사인 것만 대사로 봐야, 섞인 문단이 대사 말풍선에 들어가 묘사까지
    /// 인물이 소리 내어 말한 것처럼 보이는 일을 막습니다.
    fun unwrappedDialogue(paragraph: String): String? {
        val text = paragraph.trim()
        if (text.length < 2) return null
        val first = text.first()
        val last = text.last()
        if (quotePairs.none { it.first == first && it.second == last }) return null

        val inner = text.substring(1, text.length - 1).trim()
        if (inner.isEmpty()) return null
        // 따옴표가 중간에서 닫혔다 다시 열리면 한 덩어리 대사가 아닙니다.
        // `"어" 하고 답했다. "왜?"` 같은 문단이 여기서 걸러집니다.
        if (inner.contains(first) || inner.contains(last)) return null
        return inner
    }

    /// 별표나 밑줄로 감싼 묘사이면 그 안쪽 글을 돌려줍니다.
    fun unwrappedEmphasis(paragraph: String): String? {
        val text = paragraph.trim()
        if (text.length < 3) return null
        val mark = text.first()
        if (mark !in emphasisMarks || text.last() != mark) return null
        val inner = text.substring(1, text.length - 1).trim()
        if (inner.isEmpty() || inner.contains(mark)) return null
        return inner
    }

    /// 한 문단을 어떻게 보여줄지 정한 결과입니다.
    data class Classified(val text: String, val kind: MessageKind)

    /// 문단 하나를 분류합니다.
    ///
    /// @param roleplayEstablished 이 턴이 상황극이라고 이미 확인됐는지.
    ///   확인되기 전에는 따옴표 없는 문단을 묘사로 넘기지 않습니다.
    fun classify(paragraph: String, roleplayEstablished: Boolean): Classified {
        unwrappedDialogue(paragraph)?.let {
            // 따옴표는 표시용 기호일 뿐이라 말풍선에는 알맹이만 넣습니다.
            // 카카오톡 말풍선 안에 따옴표가 남아 있으면 사람이 쓴 메시지처럼 보이지 않습니다.
            return Classified(it, MessageKind.SPEECH)
        }
        unwrappedEmphasis(paragraph)?.let {
            return Classified(it, MessageKind.NARRATION)
        }
        return Classified(
            paragraph.trim(),
            if (roleplayEstablished) MessageKind.NARRATION else MessageKind.SPEECH
        )
    }

    /// 이 문단을 보고 나서 "이 턴은 상황극이다"라고 말할 수 있는지 봅니다.
    fun establishesRoleplay(paragraph: String): Boolean =
        unwrappedDialogue(paragraph) != null || unwrappedEmphasis(paragraph) != null

    /// 다음 문단의 시작만 도착한 상태에서, 완성됐을 때 상황극 표식이 될 가능성이 있는지 봅니다.
    /// 첫 실제 문자가 평문이면 앞의 모호한 문단을 더 기다리지 않고 일반 대사로 내보낼 수 있습니다.
    internal fun canStillEstablishRoleplay(paragraphPrefix: String): Boolean {
        val first = paragraphPrefix.firstOrNull { !it.isWhitespace() } ?: return true
        return quotePairs.any { it.first == first } || first in emphasisMarks
    }

    /// 지난 대화를 훑어 이 방이 상황극 중인지 판단합니다.
    ///
    /// 스트리밍은 문단이 완성되는 대로 화면에 붙이므로, 첫 문단을 붙이는 시점에는
    /// 그 턴에 따옴표 대사가 나올지 아직 모릅니다. 앞 턴에서 이미 상황극이었다면
    /// 그 사실을 미리 알려 주어 첫 문단부터 제대로 나오게 합니다.
    ///
    /// 마지막 AI 턴만 봅니다. 오래전에 한 번 상황극을 했다고 해서 지금 잡담까지
    /// 묘사로 처리되면 안 됩니다.
    fun roleplayInProgress(messages: List<ChatMessage>): Boolean {
        val lastBotIndex = messages.indexOfLast { it.sender == MessageSender.SAPIENS }
        if (lastBotIndex < 0) return false
        val lastTurnId = messages[lastBotIndex].turnId
        return messages.take(lastBotIndex + 1)
            .asReversed()
            .takeWhile { it.sender == MessageSender.SAPIENS && it.turnId == lastTurnId }
            .any { it.kind == MessageKind.NARRATION }
    }
}
