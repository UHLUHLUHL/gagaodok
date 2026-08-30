package com.sapiens.gagaodok.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncAccountTransitionModelTest {
    private class Service(var availability: SyncTransitionAvailability) : SyncAccountTransitionServicing {
        var unlinked = 0
        override fun availability() = availability
        override fun unlink() { unlinked += 1 }
    }

    @Test fun `ready linked account requires confirmation before join or unlink`() {
        val service = Service(SyncTransitionAvailability.READY)
        val model = SyncAccountTransitionModel(service)
        model.refresh()
        assertTrue(model.actions.canRequestJoin)
        assertTrue(model.actions.canRequestUnlink)
        assertFalse(model.actions.canStartScanner)

        model.requestJoin()
        assertEquals(SyncAccountTransitionUiState.CONFIRMING_JOIN, model.state.value)
        assertTrue(model.actions.canConfirmJoin)
        model.confirmJoin()
        assertEquals(SyncAccountTransitionUiState.JOINING, model.state.value)
        assertTrue(model.actions.canStartScanner)
        assertEquals(0, service.unlinked)
    }

    @Test fun `pending outbox and enabled sync expose no destructive action`() {
        listOf(SyncTransitionAvailability.OUTBOX_PENDING, SyncTransitionAvailability.SYNC_ENABLED).forEach { blocked ->
            val model = SyncAccountTransitionModel(Service(blocked))
            model.refresh()
            assertFalse(model.actions.canRequestJoin)
            assertFalse(model.actions.canRequestUnlink)
            assertEquals(SyncAccountTransitionUiState.BLOCKED, model.state.value)
        }
    }

    @Test fun `unlink calls service only after confirmation`() {
        val service = Service(SyncTransitionAvailability.READY)
        val model = SyncAccountTransitionModel(service)
        model.refresh()
        model.requestUnlink()
        assertEquals(0, service.unlinked)
        model.confirmUnlink()
        assertEquals(1, service.unlinked)
        assertEquals(SyncAccountTransitionUiState.UNLINKED, model.state.value)
    }
}
