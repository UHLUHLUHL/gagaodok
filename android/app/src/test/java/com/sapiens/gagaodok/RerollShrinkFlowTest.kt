package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.AttachmentType
import com.sapiens.gagaodok.model.ChatAttachment
import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.service.isRerollShrink
import com.sapiens.gagaodok.ui.screens.MessageResendLogic
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/// 답을 다시 받는 **실제 흐름**을 끝에서 끝까지 이어 붙인 검사입니다.
///
/// **기존 `PrefixCacheLagTest`는 `coveredTurns=63, newSize=62`를 손으로 넣었습니다.**
/// 그 숫자가 어디서 오는지는 검사하지 않았습니다. 실제 경로
/// (`MessageResendLogic.truncateFrom` → `ConversationTurn.from` → 캐시 판정)를
/// 이어 보면 **63 → 63**이 나옵니다. 차이가 1이 아니라 0입니다.
///
/// 이유는 캐시를 만드는 시점입니다. `AIServiceConversation.kt:225`는 답변이 아니라
/// **방금 보낸 요청의 `contents`**를 올립니다. 그래서 `coveredTurns`는 "사용자
/// 메시지까지"의 길이입니다. 답변이 저장되면 대화는 +1, 답을 다시 받으면 그 +1이
/// 지워져 **정확히 원래 길이로 돌아옵니다.**
///
/// 고치기 전 `isRerollShrink`는 `coveredTurns - newSize < 1`에서 걸러, 차이가 0인
/// 이 경우를 재요청으로 보지 않았습니다. 그 상태에서 아래 여섯 검사는 `assertFalse`로
/// 통과했고, 조건을 `< 0`으로 고치자 정확히 그 여섯이 뒤집혔습니다. 길이 단언(63→63)은
/// 양쪽에서 같으므로 바뀐 것은 판정뿐입니다.
class RerollShrinkFlowTest {

    // ── 실제 경로를 흉내내는 최소 도구 ──────────────────────────────

    /// `buildGeminiContents`는 `AIService` 확장이라 단위 검사에서 못 부릅니다.
    /// 다만 그것은 턴 하나를 엔트리 하나로 옮기므로(오류 턴과 빈 파트만 제외),
    /// 아래 본문들에 대해서는 `ConversationTurn.from(...).size`와 같습니다.
    private fun contentsSize(messages: List<ChatMessage>): Int =
        ConversationTurn.from(messages).size

    private fun user(text: String, attachment: ChatAttachment? = null) = ChatMessage(
        sender = MessageSender.USER, text = text, attachment = attachment
    )

    /// AI 응답 한 번. 말풍선이 여러 개여도 `turnId`를 공유하면 한 턴입니다.
    private fun ai(vararg bubbles: String): List<ChatMessage> {
        val turn = UUID.randomUUID()
        return bubbles.mapIndexed { i, b ->
            ChatMessage(
                sender = MessageSender.SAPIENS, text = b, turnId = turn,
                canonicalText = if (i == 0) bubbles.joinToString("\n\n") else null
            )
        }
    }

    /// 사용자 31마디 + AI 31번 = 62턴, 마지막에 사용자 한 마디 → 63턴.
    /// 그 63턴 그대로가 요청으로 나가고 캐시가 됩니다.
    private fun roomEndingWithUserMessage(lastText: String = "마지막 질문"): List<ChatMessage> {
        val messages = mutableListOf<ChatMessage>()
        repeat(31) { i ->
            messages += user("사용자 $i")
            messages += ai("답변 $i")
        }
        messages += user(lastText)
        return messages
    }

    /// 캐시 생성 → 답변 저장 → 재전송까지를 실제 함수로 돌립니다.
    /// 돌려주는 값은 (캐시의 coveredTurns, 재요청의 contents.size)입니다.
    private fun runResend(
        room: List<ChatMessage>,
        replacementText: String?
    ): Pair<Int, Int> {
        // 1) 이 시점의 대화가 요청으로 나가고, 그대로 캐시가 됩니다(lag 0).
        val coveredTurns = contentsSize(room)

        // 2) 답변이 저장되어 대화가 늘어납니다.
        val afterAnswer = room + ai("방금 받은 답변")

        // 3) 사용자가 마지막 자기 메시지에서 다시 받습니다.
        val lastUserId = room.last { it.sender == MessageSender.USER }.id
        val resent = MessageResendLogic.truncateFrom(afterAnswer, lastUserId, replacementText)

        return coveredTurns to contentsSize(resent)
    }

    private fun judge(coveredTurns: Int, newSize: Int): Boolean = isRerollShrink(
        // 재요청 사이에 요약은 돌지 않았으므로 양쪽이 같습니다.
        cacheDigestCoveredTurns = 600,
        requestDigestCoveredTurns = 600,
        coveredTurns = coveredTurns,
        newSize = newSize
    )

    // ── 직전 사용자 메시지: 네 가지 재요청 ─────────────────────────

    @Test
    fun `일반 재생성은 길이가 그대로여도 표시된다`() {
        val (covered, newSize) = runResend(roomEndingWithUserMessage(), replacementText = null)
        assertEquals("캐시가 덮은 길이", 63, covered)
        assertEquals("재요청 길이 — 줄지 않는다", 63, newSize)
        assertTrue("SHRUNK으로 걸린다", newSize <= covered)
        assertTrue("그리고 재요청으로 판정된다", judge(covered, newSize))
    }

    @Test
    fun `같은 문구로 수정 후 재전송도 마찬가지다`() {
        val (covered, newSize) = runResend(roomEndingWithUserMessage("마지막 질문"), "마지막 질문")
        assertEquals(63, covered)
        assertEquals(63, newSize)
        assertTrue(judge(covered, newSize))
    }

    @Test
    fun `일부 수정 후 재전송도 마찬가지다`() {
        val (covered, newSize) = runResend(roomEndingWithUserMessage("마지막 질문"), "마지막 질문이야")
        assertEquals(63, covered)
        assertEquals(63, newSize)
        assertTrue(judge(covered, newSize))
    }

    @Test
    fun `전면 수정 후 재전송도 마찬가지다`() {
        val (covered, newSize) = runResend(roomEndingWithUserMessage("마지막 질문"), "완전히 다른 이야기를 해보자")
        assertEquals(63, covered)
        assertEquals(63, newSize)
        assertTrue(judge(covered, newSize))
    }

    // ── 경계 경우 ───────────────────────────────────────────────

    @Test
    fun `첨부만 있는 메시지를 다시 보내도 길이는 그대로다`() {
        val attachment = ChatAttachment(
            type = AttachmentType.IMAGE, fileName = "a.jpg", fileSize = 10,
            dataBase64 = "AAAA", mimeType = "image/jpeg"
        )
        val room = roomEndingWithUserMessage().dropLast(1) + user("", attachment)
        // 첨부 전용 메시지는 EDIT이 아니라 RESEND이므로 교체 문구가 없습니다.
        val (covered, newSize) = runResend(room, replacementText = null)
        assertEquals(63, covered)
        assertEquals(63, newSize)
        assertTrue(judge(covered, newSize))
    }

    @Test
    fun `말풍선 여러 개로 나뉜 답을 다시 받아도 한 턴만 지워진다`() {
        val room = roomEndingWithUserMessage()
        val covered = contentsSize(room)
        // 답이 말풍선 셋으로 나뉘어 저장됩니다.
        val afterAnswer = room + ai("첫째 줄", "둘째 줄", "셋째 줄")
        assertEquals("말풍선 셋이어도 턴은 하나", covered + 1, contentsSize(afterAnswer))

        val lastUserId = room.last { it.sender == MessageSender.USER }.id
        val resent = MessageResendLogic.truncateFrom(afterAnswer, lastUserId, null)
        assertEquals("셋이 아니라 하나만 줄어든다", covered, contentsSize(resent))
        assertTrue(judge(covered, contentsSize(resent)))
    }

    @Test
    fun `과거 메시지를 고치면 길이가 실제로 줄어 표시된다`() {
        val room = roomEndingWithUserMessage()
        val covered = contentsSize(room)
        val afterAnswer = room + ai("방금 받은 답변")

        // 다섯 턴 전의 사용자 메시지를 고칩니다.
        val userMessages = afterAnswer.filter { it.sender == MessageSender.USER }
        val olderId = userMessages[userMessages.size - 3].id
        val resent = MessageResendLogic.truncateFrom(afterAnswer, olderId, "고친 옛 메시지")
        val newSize = contentsSize(resent)

        assertTrue("실제로 줄어든다", newSize < covered)
        assertEquals("사용자 두 마디와 AI 두 번이 사라진다", covered - 4, newSize)
        assertTrue("이 경우는 재요청으로 판정된다", judge(covered, newSize))
    }
}
