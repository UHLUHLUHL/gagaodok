package com.sapiens.gagaodok.sync

import org.junit.Assert.assertEquals
import org.junit.Test

/** Swift `SyncAttachmentDisplayStateTests`와 같은 11가지를 확인한다. */
class SyncAttachmentDisplayStateTest {
    private fun state(remote: String, reason: String? = null) =
        SyncAttachmentDisplayState.state(remote, reason)

    @Test fun `maps server state and last error onto the four display states`() {
        assertEquals(SyncAttachmentDisplayState.PENDING, state("allocated"))
        assertEquals(SyncAttachmentDisplayState.PENDING, state("uploaded"))
        assertEquals(SyncAttachmentDisplayState.READY, state("ready"))

        // 다시 시도해도 결과가 같은 실패는 재시도로 안내하지 않는다.
        assertEquals(SyncAttachmentDisplayState.UNAVAILABLE, state("ready", "hash_mismatch"))
        assertEquals(SyncAttachmentDisplayState.UNAVAILABLE, state("ready", "size_mismatch"))
        assertEquals(SyncAttachmentDisplayState.UNAVAILABLE, state("ready", "decryption_failed"))
        assertEquals(SyncAttachmentDisplayState.RETRYABLE, state("ready", "not_ready"))

        // 되돌릴 수 없는 서버 상태는 전부 unavailable이다.
        for (dead in listOf("abandoned", "tombstoned", "garbage_collected")) {
            assertEquals(SyncAttachmentDisplayState.UNAVAILABLE, state(dead))
        }

        // 모르는 상태를 ready로 낙관하지 않는다.
        assertEquals(SyncAttachmentDisplayState.UNAVAILABLE, state("something_new"))
    }
}
