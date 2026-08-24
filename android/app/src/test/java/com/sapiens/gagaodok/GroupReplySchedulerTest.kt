package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.MessageKind
import com.sapiens.gagaodok.service.GroupReplyBubble
import com.sapiens.gagaodok.service.GroupReplyEvent
import com.sapiens.gagaodok.service.GroupReplyScheduler
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
        assertTrue(reveals.all { it.atMillis in 900L..10_000L })
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
}
