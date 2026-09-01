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
}
