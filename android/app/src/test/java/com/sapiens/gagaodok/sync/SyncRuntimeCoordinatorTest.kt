package com.sapiens.gagaodok.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Swift `SyncRuntimeCoordinatorTests`와 같은 것을 확인한다. */
class SyncRuntimeCoordinatorTest {
    private val all = SyncRuntimeTrigger.entries

    @Test fun `a disabled runtime makes no request from any trigger`() {
        // 설정 화면이나 원격 방 화면을 열었다는 이유만으로도 나가지 않는다.
        for (trigger in all) {
            var pulls = 0
            val off = SyncRuntimeCoordinator(
                SyncRuntimeSwitches(syncEnabled = false, remoteReadEnabled = true, remoteReplyEnabled = true),
            ) { pulls += 1 }
            off.run(trigger)
            assertEquals("trigger $trigger ran while sync was disabled", 0, pulls)
            assertEquals(SyncRuntimeStatus.DISABLED, off.status)
        }
    }

    @Test fun `every trigger runs when sync is enabled`() {
        for (trigger in all) {
            var pulls = 0
            val on = SyncRuntimeCoordinator(
                SyncRuntimeSwitches(syncEnabled = true, remoteReadEnabled = true, remoteReplyEnabled = true),
            ) { pulls += 1 }
            on.run(trigger)
            assertEquals("trigger $trigger did not run", 1, pulls)
            assertEquals(SyncRuntimeStatus.IDLE, on.status)
        }
    }

    @Test fun `a reentrant call does not run twice`() {
        var pulls = 0
        lateinit var coordinator: SyncRuntimeCoordinator
        coordinator = SyncRuntimeCoordinator(
            SyncRuntimeSwitches(syncEnabled = true, remoteReadEnabled = true, remoteReplyEnabled = true),
        ) {
            pulls += 1
            // 단일 실행 잠금이 없으면 여기서 무한히 겹친다.
            if (pulls < 3) coordinator.run(SyncRuntimeTrigger.MANUAL)
        }
        coordinator.run(SyncRuntimeTrigger.FOREGROUND)
        assertEquals(1, pulls)
    }

    @Test fun `the three switches stay independent`() {
        val readOff = SyncRuntimeCoordinator(
            SyncRuntimeSwitches(syncEnabled = true, remoteReadEnabled = false, remoteReplyEnabled = true),
        ) {}
        assertFalse(readOff.canReadRemote)
        assertTrue(readOff.canReplyRemote)
    }

    @Test fun `a revoked token pauses the runtime without touching the switches`() {
        var pulls = 0
        val revoked = SyncRuntimeCoordinator(
            SyncRuntimeSwitches(syncEnabled = true, remoteReadEnabled = true, remoteReplyEnabled = true),
        ) { pulls += 1 }
        revoked.pauseForRevokedToken()
        for (trigger in all) revoked.run(trigger)
        assertEquals(0, pulls)
        assertEquals(SyncRuntimeStatus.PAUSED_REVOKED, revoked.status)
        assertFalse(revoked.canReadRemote)
        assertFalse(revoked.canReplyRemote)
    }

    @Test fun `the status label never claims work while nothing is running`() {
        // 꺼져 있는데 "동기화 중"이라고 말하는 것이 가장 나쁜 거짓말이다.
        val busy = listOf("확인하는 중", "동기화 중")
        for (quiet in listOf(
            SyncRuntimeStatus.DISABLED, SyncRuntimeStatus.PAUSED_REVOKED, SyncRuntimeStatus.OFFLINE,
        )) {
            for (word in busy) {
                assertFalse("$quiet claims work: ${quiet.label}", quiet.label.contains(word))
            }
        }
        assertEquals("동기화가 꺼져 있습니다.", SyncRuntimeStatus.DISABLED.label)
        assertEquals("확인하는 중", SyncRuntimeStatus.RUNNING.label)
        // 다섯 상태가 서로 다른 문구를 갖는다. 두 상태가 같은 말을 하면 구분이 안 된다.
        assertEquals(5, SyncRuntimeStatus.entries.map { it.label }.toSet().size)
    }

    @Test fun `the indicator is green only while sync is on`() {
        // RUNNING만 초록으로 두면 실제로 도는 순간이 아주 짧아 대부분의 시간에
        // 꺼진 것과 구별되지 않는다.
        assertTrue(SyncRuntimeStatus.IDLE.isActive)
        assertTrue(SyncRuntimeStatus.RUNNING.isActive)
        assertFalse(SyncRuntimeStatus.DISABLED.isActive)
        assertFalse(SyncRuntimeStatus.PAUSED_REVOKED.isActive)
        assertFalse(SyncRuntimeStatus.OFFLINE.isActive)
        assertTrue(SyncRuntimeStatus.DISABLED.label.contains("꺼져"))
    }
}
