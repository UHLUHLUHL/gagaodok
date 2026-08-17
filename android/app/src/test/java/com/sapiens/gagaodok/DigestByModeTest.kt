package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.service.ConversationCompactor
import com.sapiens.gagaodok.service.ConversationDigest
import com.sapiens.gagaodok.service.ConversationSegment
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/// 요약이 방의 성격을 따라가는지 봅니다.
///
/// 한동안 과외용 지침 하나로 모든 방을 요약했습니다. 챗봇 방의 150턴이
/// "학습자의 상황 / 틀린 지점 / 지도 참고"로 정리되면 관계도 약속도 감정도
/// 한 줄 안 남습니다. **요약은 한 번 쓰면 다시 안 만들어서 되돌릴 수 없습니다.**
class DigestByModeTest {

    @Test
    fun `모드마다 다른 지침을 쓴다`() {
        assertNotEquals(
            ConversationCompactor.summaryInstruction(ChatMode.MATH_MENTOR),
            ConversationCompactor.summaryInstruction(ChatMode.COMPANION)
        )
    }

    @Test
    fun `챗봇 지침에는 과외용 소제목이 없다`() {
        val companion = ConversationCompactor.summaryInstruction(ChatMode.COMPANION)
        for (heading in listOf("틀린 지점", "이해가 뚫린 순간", "지도 참고", "진도")) {
            assertFalse("챗봇 요약에 '$heading'이 남아 있습니다", companion.contains(heading))
        }
    }

    @Test
    fun `챗봇 지침은 남길 것을 관계와 사건으로 잡는다`() {
        val companion = ConversationCompactor.summaryInstruction(ChatMode.COMPANION)
        for (heading in listOf("■ 관계", "■ 있었던 일", "■ 주고받은 것", "■ 감정의 결", "■ 이어서")) {
            assertTrue("챗봇 요약에 '$heading'이 없습니다", companion.contains(heading))
        }
    }

    @Test
    fun `양쪽 다 답변자의 정체성은 적지 말라고 한다`() {
        // 이름도 말투도 방의 말투 설정에서 매번 새로 정해집니다.
        // 옛 요약에 그게 남아 있으면 지금 설정과 싸웁니다.
        for (mode in ChatMode.entries) {
            val text = ConversationCompactor.summaryInstruction(mode)
            assertTrue(
                "$mode 지침에 정체성 금지 규칙이 없습니다",
                text.contains("정체성")
            )
        }
    }

    @Test
    fun `대화를 펼 때 부르는 이름이 모드를 따른다`() {
        val turns = listOf(
            ConversationTurn(UUID.randomUUID(), MessageSender.USER, "뭐해"),
            ConversationTurn(UUID.randomUUID(), MessageSender.SAPIENS, "그냥 있었어")
        )

        val mentor = ConversationCompactor.transcript(turns, 1, ChatMode.MATH_MENTOR)
        assertTrue(mentor.contains("학습자:"))
        assertTrue(mentor.contains("답변자:"))

        // 캐릭터 대화를 "학습자/답변자"로 옮겨 놓으면 요약하는 쪽이 수업 기록으로 읽습니다.
        val companion = ConversationCompactor.transcript(turns, 1, ChatMode.COMPANION)
        assertTrue(companion.contains("사용자:"))
        assertTrue(companion.contains("상대:"))
        assertFalse(companion.contains("학습자"))
    }

    @Test
    fun `요약을 앞에 붙일 때의 안내문도 모드를 따른다`() {
        val digest = ConversationDigest(
            segments = listOf(ConversationSegment(firstTurn = 1, lastTurn = 50, text = "■ 관계\n- 호칭: 서로 이름"))
        )
        val companion = ConversationCompactor.render(digest, ChatMode.COMPANION)
        assertTrue(companion.contains("관계와 약속"))
        assertFalse(companion.contains("지도 참고"))

        val mentor = ConversationCompactor.render(digest, ChatMode.MATH_MENTOR)
        assertTrue(mentor.contains("지도 참고"))
    }
}
