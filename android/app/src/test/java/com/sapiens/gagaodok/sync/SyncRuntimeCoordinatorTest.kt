package com.sapiens.gagaodok.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class SyncRuntimeCoordinatorTest {
    @Test fun `sync switch gates requests while read and reply remain independent`() {
        var pulls = 0
        val disabled = SyncRuntimeCoordinator(
            SyncRuntimeSwitches(syncEnabled = false, remoteReadEnabled = true, remoteReplyEnabled = true),
        ) { pulls += 1 }
        disabled.foreground()
        assertEquals(0, pulls)

        val enabled = SyncRuntimeCoordinator(
            SyncRuntimeSwitches(syncEnabled = true, remoteReadEnabled = false, remoteReplyEnabled = false),
        ) { pulls += 1 }
        enabled.foreground()
        assertEquals(1, pulls)
        assertFalse(enabled.canReadRemote)
        assertFalse(enabled.canReplyRemote)
    }
}
