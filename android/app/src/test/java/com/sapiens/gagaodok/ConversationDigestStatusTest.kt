package com.sapiens.gagaodok

import com.sapiens.gagaodok.service.ConversationCompactor
import com.sapiens.gagaodok.service.ConversationDigest
import com.sapiens.gagaodok.service.ConversationDigestStatus
import com.sapiens.gagaodok.service.ConversationSegment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationDigestStatusTest {
    private fun segments(vararg ranges: Pair<Int, Int>) =
        ranges.map { (first, last) ->
            ConversationSegment(firstTurn = first, lastTurn = last, text = "x".repeat(10))
        }

    @Test fun `a short room has not started summarising yet`() {
        val status = ConversationDigestStatus.of(totalTurns = 32, digest = null)
        assertFalse(status.isActive)
        assertEquals(0, status.coveredTurns)
        assertEquals(32, status.verbatimTurns)
        // 아직 시작 전이면 남은 수는 "시작까지"다.
        assertEquals(ConversationCompactor.THRESHOLD_TURNS - 32, status.turnsUntilNext)
    }

    @Test fun `the threshold turn itself counts as active`() {
        assertTrue(ConversationDigestStatus.of(ConversationCompactor.THRESHOLD_TURNS, null).isActive)
        assertFalse(ConversationDigestStatus.of(ConversationCompactor.THRESHOLD_TURNS - 1, null).isActive)
    }

    @Test fun `covered and verbatim split the whole room`() {
        // 실제 방에서 잰 수치다: 394턴, 1~350턴이 7구간으로 덮여 있다.
        val digest = ConversationDigest(
            segments(1 to 50, 51 to 100, 101 to 150, 151 to 200, 201 to 250, 251 to 300, 301 to 350),
        )
        val status = ConversationDigestStatus.of(totalTurns = 394, digest = digest)
        assertTrue(status.isActive)
        assertEquals(350, status.coveredTurns)
        assertEquals(44, status.verbatimTurns)
        assertEquals(7, status.segments.size)
        assertEquals(status.totalTurns, status.coveredTurns + status.verbatimTurns)
    }

    @Test fun `the next summary waits for the window plus the period, not the period alone`() {
        // 주기(50)마다 만들어진다고 착각하기 쉽다. 실제로는 원문이 창(30)+주기(50)를
        // 넘어야 만들어지므로, 원문 44턴이면 6턴이 아니라 36턴이 남았다.
        val status = ConversationDigestStatus.of(394, ConversationDigest(segments(1 to 350)))
        assertEquals(44, status.verbatimTurns)
        assertEquals(36, status.turnsUntilNext)
        assertEquals(80, ConversationDigestStatus.REFRESH_TRIGGER)
    }

    @Test fun `an overdue room reports zero rather than a negative count`() {
        val status = ConversationDigestStatus.of(200, ConversationDigest(segments(1 to 50)))
        assertEquals(150, status.verbatimTurns)
        assertEquals(0, status.turnsUntilNext)
    }

    @Test fun `an active room with no segments yet is still active`() {
        val status = ConversationDigestStatus.of(100, ConversationDigest())
        assertTrue(status.isActive)
        assertEquals(0, status.coveredTurns)
        assertEquals(100, status.verbatimTurns)
        assertTrue(status.segments.isEmpty())
    }
}
