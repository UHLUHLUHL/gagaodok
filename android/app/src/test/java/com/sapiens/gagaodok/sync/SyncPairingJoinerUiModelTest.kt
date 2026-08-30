package com.sapiens.gagaodok.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncPairingJoinerUiModelTest {
    private class Service : SyncPairingJoinerServicing {
        var accepted = 0
        var redeemed = 0
        var failAccept: Throwable? = null
        var failRedeem: Throwable? = null

        override fun acceptAndSubmit(
            text: String,
            deviceId: String,
            spaceId: String,
            platform: String,
        ): String {
            failAccept?.let { throw it }
            accepted += 1
            return "842588"
        }

        override fun redeem(sasConfirmed: Boolean) {
            failRedeem?.let { throw it }
            check(sasConfirmed)
            redeemed += 1
        }
    }

    @Test fun `scan starts only after explicit action and permission`() {
        val service = Service()
        val model = SyncPairingJoinerUiModel(service) { true }

        assertEquals(SyncPairingJoinerUiState.Idle, model.state.value)
        assertTrue(model.actions.canRequestScan)
        assertEquals(0, service.accepted)

        model.requestScan()
        assertEquals(SyncPairingJoinerUiState.RequestingCamera, model.state.value)
        assertEquals(0, service.accepted)

        model.cameraPermissionGranted()
        assertEquals(SyncPairingJoinerUiState.Scanning, model.state.value)
    }

    @Test fun `camera denial is content free and retryable`() {
        val model = SyncPairingJoinerUiModel(Service()) { true }
        model.requestScan()
        model.cameraDenied()

        assertEquals(
            SyncPairingJoinerUiState.Error(SyncPairingJoinerUiError.CameraDenied),
            model.state.value,
        )
        assertTrue(model.actions.canRequestScan)
    }

    @Test fun `cancelling an active scanner returns to a retryable state`() {
        val model = SyncPairingJoinerUiModel(Service()) { true }
        model.requestScan()
        model.cameraPermissionGranted()
        model.cameraDenied()

        assertEquals(
            SyncPairingJoinerUiState.Error(SyncPairingJoinerUiError.CameraDenied),
            model.state.value,
        )
        assertTrue(model.actions.canRequestScan)
    }

    @Test fun `unavailable local state never opens the camera`() {
        val model = SyncPairingJoinerUiModel(Service()) { false }
        model.requestScan()
        assertEquals(
            SyncPairingJoinerUiState.Error(SyncPairingJoinerUiError.NotAvailable),
            model.state.value,
        )
        assertFalse(model.actions.canLaunchCamera)
    }

    @Test fun `valid payload submits then exposes only six SAS digits`() {
        val service = Service()
        val model = SyncPairingJoinerUiModel(service) { true }
        model.requestScan()
        model.cameraPermissionGranted()
        model.acceptScannedPayload("R0RQMQ", DEVICE, "PHONE_SPACE", "android_phone")

        assertEquals(1, service.accepted)
        assertEquals(SyncPairingJoinerUiState.VerifySas("842588"), model.state.value)
        assertTrue(model.actions.canConfirmSas)
        assertFalse(model.state.value.toString().contains("R0RQMQ"))
    }

    @Test fun `redeem cannot run before SAS confirmation state`() {
        val service = Service()
        val model = SyncPairingJoinerUiModel(service) { true }
        model.confirmSasAndRedeem()
        assertEquals(0, service.redeemed)
        assertEquals(SyncPairingJoinerUiState.Idle, model.state.value)
    }

    @Test fun `confirmed SAS links with sync still off`() {
        val service = Service()
        val model = SyncPairingJoinerUiModel(service) { true }
        model.requestScan()
        model.cameraPermissionGranted()
        model.acceptScannedPayload("R0RQMQ", DEVICE, "TABLET_SPACE", "android_tablet")
        model.confirmSasAndRedeem()

        assertEquals(1, service.redeemed)
        assertEquals(SyncPairingJoinerUiState.LinkedSyncOff, model.state.value)
        assertFalse(model.actions.canRequestScan)
    }

    @Test fun `waiting for host approval keeps the same SAS digits visible`() {
        val service = Service().apply {
            failRedeem = SyncPairingException(SyncPairingException.Reason.REJECTED)
        }
        val model = SyncPairingJoinerUiModel(service) { true }
        model.requestScan()
        model.cameraPermissionGranted()
        model.acceptScannedPayload("R0RQMQ", DEVICE, "PHONE_SPACE", "android_phone")
        model.confirmSasAndRedeem()

        assertEquals(SyncPairingJoinerUiState.WaitingApproval("842588"), model.state.value)
        assertTrue(model.actions.canConfirmSas)
    }

    @Test fun `duplicate actions while busy are ignored`() {
        val service = Service()
        val model = SyncPairingJoinerUiModel(service) { true }
        model.requestScan()
        model.requestScan()
        model.cameraPermissionGranted()
        model.cameraPermissionGranted()
        model.acceptScannedPayload("R0RQMQ", DEVICE, "PHONE_SPACE", "android_phone")
        model.acceptScannedPayload("SECOND", DEVICE, "PHONE_SPACE", "android_phone")

        assertEquals(1, service.accepted)
        assertEquals(SyncPairingJoinerUiState.VerifySas("842588"), model.state.value)
    }

    private companion object {
        const val DEVICE = "BBBBBBBB-0000-4000-8000-00000000000B"
    }
}
