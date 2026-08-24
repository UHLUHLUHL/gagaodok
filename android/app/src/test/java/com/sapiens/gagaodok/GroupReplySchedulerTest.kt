package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.MessageKind
import com.sapiens.gagaodok.service.GroupReplyBubble
import com.sapiens.gagaodok.service.GroupReplyEvent
import com.sapiens.gagaodok.service.GroupReplyScheduler
import com.sapiens.gagaodok.service.GroupReplyTimeline
import com.sapiens.gagaodok.service.PlannedReaction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class GroupReplySchedulerTest {
    private val first = UUID.fromString("11111111-1111-1111-1111-111111111111")
    private val second = UUID.fromString("22222222-2222-2222-2222-222222222222")
    private val turn = UUID.fromString("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")

    private val bubbles = listOf(
        GroupReplyBubble(0, "먼저 이야기할게.", MessageKind.SPEECH, first),
        GroupReplyBubble(1, "그 말에는 나도 동의해.", MessageKind.SPEECH, second, listOf(PlannedReaction(first, "❤️")))
    )

    @Test
    fun `same turn produces identical bounded schedule`() {
        val firstPlan = GroupReplyScheduler.plan(turn, bubbles)
        val secondPlan = GroupReplyScheduler.plan(turn, bubbles)

        assertEquals(firstPlan, secondPlan)
        assertTrue(firstPlan.zipWithNext().all { (a, b) -> a.atMillis <= b.atMillis })
        val reveals = firstPlan.filterIsInstance<GroupReplyEvent.RevealBubble>()
        assertEquals(listOf(0, 1), reveals.map { it.bubbleIndex })
        assertTrue(reveals.all { it.atMillis in 500L..6_000L })
    }

    @Test
    fun `typing can overlap but each speaker stops when their bubble appears`() {
        val plan = GroupReplyScheduler.plan(turn, bubbles)
        val starts = plan.filterIsInstance<GroupReplyEvent.TypingStarted>().associateBy { it.participantRoomId }
        val stops = plan.filterIsInstance<GroupReplyEvent.TypingStopped>().associateBy { it.participantRoomId }
        val reveals = plan.filterIsInstance<GroupReplyEvent.RevealBubble>().associateBy { bubbles[it.bubbleIndex].speakerRoomId }

        assertTrue(starts.getValue(second).atMillis < stops.getValue(first).atMillis)
        assertEquals(reveals.getValue(first).atMillis, stops.getValue(first).atMillis)
        assertEquals(reveals.getValue(second).atMillis, stops.getValue(second).atMillis)
    }

    @Test
    fun `reaction is scheduled after its target bubble reveal`() {
        val plan = GroupReplyScheduler.plan(turn, bubbles)
        val targetReveal = plan.filterIsInstance<GroupReplyEvent.RevealBubble>().first { it.bubbleIndex == 1 }
        val reaction = plan.filterIsInstance<GroupReplyEvent.ApplyReaction>().single()

        assertEquals(1, reaction.bubbleIndex)
        assertEquals(first, reaction.reaction.participantRoomId)
        assertTrue(reaction.atMillis > targetReveal.atMillis)
    }

    /// 턴이 끝나기 전에는 입력 표시가 끊기지 않아야 합니다.
    ///
    /// 말풍선 하나가 뜨는 순간 다음 화자가 이미 입력 중이어야, 사용자가 "이게 끝인가"를
    /// 표시의 유무만으로 판단할 수 있습니다. 예전 계획은 짝수 번째 대사에서 앞 말풍선보다
    /// 늦게 입력을 시작해서 그 사이가 비었습니다.
    @Test
    fun `every reveal except the last has someone already typing`() {
        val third = UUID.fromString("33333333-3333-3333-3333-333333333333")
        val many = listOf(
            GroupReplyBubble(0, "첫 마디야.", MessageKind.SPEECH, first),
            GroupReplyBubble(1, "두 번째 마디.", MessageKind.SPEECH, second),
            GroupReplyBubble(2, "세 번째 마디도 이어서.", MessageKind.SPEECH, third),
            GroupReplyBubble(3, "마지막 마디.", MessageKind.SPEECH, first)
        )
        val plan = GroupReplyScheduler.plan(turn, many)
        val reveals = plan.filterIsInstance<GroupReplyEvent.RevealBubble>().sortedBy { it.atMillis }
        val starts = plan.filterIsInstance<GroupReplyEvent.TypingStarted>()

        reveals.dropLast(1).forEach { reveal ->
            val nextIndex = reveal.bubbleIndex + 1
            val nextSpeaker = many[nextIndex].speakerRoomId
            val nextStart = starts.first { it.participantRoomId == nextSpeaker && it.atMillis <= reveal.atMillis }
            assertTrue(
                "말풍선 ${reveal.bubbleIndex}이 뜰 때 다음 화자가 이미 입력 중이어야 합니다",
                nextStart.atMillis <= reveal.atMillis
            )
        }
    }

    /// 같은 사람이 연달아 말하면 두 번째 입력이 첫 말풍선보다 먼저 시작합니다.
    ///
    /// 뷰모델이 입력 중인 사람을 집합으로 들고 있으면, 첫 번째의 "입력 끝"이 아직 진행 중인
    /// 두 번째까지 지워 버립니다. 계획이 실제로 그렇게 겹치는지를 여기서 못 박아 둡니다.
    @Test
    fun `consecutive bubbles from one speaker overlap their typing`() {
        val sameSpeaker = listOf(
            GroupReplyBubble(0, "둘 다 마음에 든다 이거지?", MessageKind.SPEECH, first),
            GroupReplyBubble(1, "그럼 아예 날 잡고 둘 다 입어줄 수도 있는데!", MessageKind.SPEECH, first)
        )
        val plan = GroupReplyScheduler.plan(turn, sameSpeaker)
        val starts = plan.filterIsInstance<GroupReplyEvent.TypingStarted>().map { it.atMillis }.sorted()
        val stops = plan.filterIsInstance<GroupReplyEvent.TypingStopped>().map { it.atMillis }.sorted()

        assertEquals(2, starts.size)
        assertEquals(2, stops.size)
        assertTrue("두 번째 입력이 첫 입력이 끝나기 전에 시작해야 합니다", starts[1] < stops[0])
    }

    /// 실기기 녹화에서 40자 대사 하나에 4.0초가 걸렸습니다. 그 값이 API 응답 시간에 그대로
    /// 더해져서 첫 글자까지 7.6초가 나왔습니다. 계획 자체가 짧아졌는지를 못 박아 둡니다.
    @Test
    fun `a forty character line no longer takes four seconds to appear`() {
        val long = "둘 다 마음에 든다 이거지? 그럼 아예 날 잡고 둘 다 입어줄 수도 있는데!"
        val plan = GroupReplyScheduler.plan(turn, listOf(GroupReplyBubble(0, long, MessageKind.SPEECH, first)))
        val reveal = plan.filterIsInstance<GroupReplyEvent.RevealBubble>().single()

        assertTrue("첫 말풍선이 2.5초 안에 떠야 합니다 (실제 ${reveal.atMillis}ms)", reveal.atMillis < 2_500L)
    }

    /// 재생은 말풍선이 도착하는 대로 하나씩 정합니다. 한꺼번에 계획한 결과와 같아야
    /// `plan()`으로 검사한 규칙들이 실제 재생에도 그대로 적용됩니다.
    @Test
    fun `incremental timeline matches the whole-turn plan`() {
        val timeline = GroupReplyTimeline(turn)
        val steps = bubbles.map { timeline.next(it) }
        val plan = GroupReplyScheduler.plan(turn, bubbles)
        val reveals = plan.filterIsInstance<GroupReplyEvent.RevealBubble>().sortedBy { it.bubbleIndex }

        assertEquals(reveals.map { it.atMillis }, steps.map { it.revealAt })
    }

    /// 모델이 계획보다 늦게 쓰면 말풍선은 예정보다 뒤에 뜹니다. 그 다음 말풍선까지
    /// 옛 기준으로 계산하면 이미 지난 시각이 나와 한꺼번에 쏟아집니다.
    @Test
    fun `a late reveal pushes the following bubbles back`() {
        val timeline = GroupReplyTimeline(turn)
        val first = timeline.next(bubbles[0])
        timeline.commitReveal(first.revealAt + 5_000L)
        val second = timeline.next(bubbles[1])

        assertTrue(
            "늦게 뜬 말풍선 뒤에는 최소 간격이 남아야 합니다 (실제 ${second.revealAt - first.revealAt - 5_000L}ms)",
            second.revealAt >= first.revealAt + 5_000L + GroupReplyScheduler.MIN_REVEAL_GAP
        )
    }

    /// 나레이션은 사람이 친 말이 아니므로 입력 표시를 만들지 않습니다.
    @Test
    fun `narration reveals without a typing indicator`() {
        val withNarration = listOf(
            GroupReplyBubble(0, "잠깐의 정적이 흘렀다.", MessageKind.NARRATION, null),
            GroupReplyBubble(1, "먼저 말 걸어도 돼?", MessageKind.SPEECH, first)
        )
        val plan = GroupReplyScheduler.plan(turn, withNarration)
        val typingSpeakers = plan.filterIsInstance<GroupReplyEvent.TypingStarted>().map { it.participantRoomId }

        assertEquals(listOf(first), typingSpeakers)
    }
}
