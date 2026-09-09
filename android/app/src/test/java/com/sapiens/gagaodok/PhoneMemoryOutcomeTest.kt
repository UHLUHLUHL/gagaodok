package com.sapiens.gagaodok

import com.sapiens.gagaodok.service.PHONE_MEMORY_RETRY_MILLIS
import com.sapiens.gagaodok.service.PhoneMemoryObservation
import com.sapiens.gagaodok.service.PhoneMemoryOutcome
import com.sapiens.gagaodok.service.phoneMemoryBackoffMillis
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneMemoryOutcomeTest {
    @Test
    fun `유료 실패와 무료 건너뜀을 구분한다`() {
        // 반복 비용의 원인은 돈을 쓰고 실패한 것뿐입니다. 재시도 대기 때문에
        // 그냥 돌아온 것은 실패가 아니라 절약이고, 그것까지 섞어 세면 실제로
        // 요금이 나간 실패가 몇 번인지 묻힙니다.
        assertTrue(PhoneMemoryOutcome.NO_CANDIDATE.paid)
        assertTrue(PhoneMemoryOutcome.NOT_STOP.paid)
        assertTrue(PhoneMemoryOutcome.MIGRATION_NOT_SMALLER.paid)
        assertTrue(PhoneMemoryOutcome.COMMIT_REJECTED.paid)
        assertTrue(PhoneMemoryOutcome.EXCEPTION.paid)

        assertFalse(PhoneMemoryOutcome.BACKOFF_SKIPPED.paid)
        assertFalse(PhoneMemoryOutcome.ALREADY_RUNNING.paid)
        assertFalse(PhoneMemoryOutcome.NO_PENDING.paid)
        assertFalse(PhoneMemoryOutcome.SOURCE_TURN_MISMATCH.paid)
    }

    @Test
    fun `요약 범위를 진전시키는 것은 저장 성공뿐이다`() {
        assertEquals(
            listOf(PhoneMemoryOutcome.COMMITTED),
            PhoneMemoryOutcome.entries.filter { it.advancesCoverage }
        )
    }

    @Test
    fun `API를 부른 뒤의 종료는 모두 유료로 표시된다`() {
        // 응답을 받은 뒤의 갈래를 무료로 표시하면, 돈이 새는 경로가 장부에서 사라집니다.
        val afterRequest = listOf(
            PhoneMemoryOutcome.NO_CANDIDATE,
            PhoneMemoryOutcome.NOT_STOP,
            PhoneMemoryOutcome.MIGRATION_NOT_SMALLER,
            PhoneMemoryOutcome.COMMIT_REJECTED,
            PhoneMemoryOutcome.EXCEPTION,
            PhoneMemoryOutcome.COMMITTED
        )
        assertTrue(afterRequest.all { it.paid })
    }

    @Test
    fun `같은 실패가 반복되면 대기 시간이 늘고 6시간에서 멈춘다`() {
        // 15분 고정이면 하루에 최대 96번까지 같은 유료 실패를 되풀이합니다.
        assertEquals(15 * 60_000L, phoneMemoryBackoffMillis(1))
        assertEquals(30 * 60_000L, phoneMemoryBackoffMillis(2))
        assertEquals(60 * 60_000L, phoneMemoryBackoffMillis(3))
        assertEquals(2 * 60 * 60_000L, phoneMemoryBackoffMillis(4))
        assertEquals(4 * 60 * 60_000L, phoneMemoryBackoffMillis(5))

        // 상한을 둡니다. 영원히 멈추면 원인을 고친 뒤에도 돌아오지 않습니다.
        assertEquals(6 * 60 * 60_000L, phoneMemoryBackoffMillis(6))
        assertEquals(6 * 60 * 60_000L, phoneMemoryBackoffMillis(100))
    }

    @Test
    fun `첫 실패의 대기는 기존 15분과 같다`() {
        // 정상 동작하던 방의 일시적 실패까지 갑자기 오래 기다리게 만들지 않습니다.
        assertEquals(PHONE_MEMORY_RETRY_MILLIS, phoneMemoryBackoffMillis(1))
        assertEquals(PHONE_MEMORY_RETRY_MILLIS, phoneMemoryBackoffMillis(0))
    }

    @Test
    fun `응답을 해석하다 실패한 갈래들이 서로 구분된다`() {
        // 예전에는 JSON 해석·구간 검사·분량 검사·상태 검사·저장이 모두 하나의
        // `EXCEPTION`으로 뭉쳐 있었습니다. 그러면 8.33%라는 성공률을 봐도 어디를
        // 고쳐야 하는지 알 수 없습니다. 예산이 모자란 것과 지시문이 안 지켜진 것은
        // 처방이 정반대입니다.
        val decoded = listOf(
            PhoneMemoryOutcome.PARSE_FAILED,
            PhoneMemoryOutcome.RANGE_MISMATCH,
            PhoneMemoryOutcome.SEGMENT_TOO_LONG,
            PhoneMemoryOutcome.STATE_REJECTED
        )
        assertEquals(decoded.size, decoded.toSet().size)
        decoded.forEach {
            assertTrue("$it 는 응답을 받은 뒤이므로 유료다", it.paid)
            assertFalse("$it 는 저장에 이르지 못했다", it.advancesCoverage)
        }
    }

    @Test
    fun `종료 사유는 STOP이 아닐 때만 남긴다`() {
        // `finishReason`을 안 남기면 `NOT_STOP` 8건이 예산 부족이었는지 안전 필터였는지
        // 구분할 수 없습니다. 반대로 성공한 건에까지 남기면 집계가 STOP으로 뒤덮입니다.
        assertEquals("MAX_TOKENS", observation(PhoneMemoryOutcome.NOT_STOP, "MAX_TOKENS").finishReason)
        assertNull(observation(PhoneMemoryOutcome.COMMITTED, null).finishReason)
    }

    private fun observation(outcome: PhoneMemoryOutcome, reason: String?) = PhoneMemoryObservation(
        outcome = outcome,
        migration = false,
        coverageBefore = 250,
        coverageAfter = if (outcome.advancesCoverage) 300 else 250,
        targetThrough = 300,
        segmentCount = 1,
        retryAfterMillis = 0L,
        finishReason = reason
    )
}
