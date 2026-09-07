package com.sapiens.gagaodok

import com.sapiens.gagaodok.service.PHONE_MEMORY_RETRY_MILLIS
import com.sapiens.gagaodok.service.PhoneMemoryOutcome
import com.sapiens.gagaodok.service.phoneMemoryBackoffMillis
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
}
