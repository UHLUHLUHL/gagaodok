package com.sapiens.gagaodok.sync

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

interface SyncPairingJoinerServicing {
    fun acceptAndSubmit(text: String, deviceId: String, spaceId: String, platform: String): String
    fun redeem(sasConfirmed: Boolean)
}

class SyncPairingJoinerService(
    private val coordinator: SyncPairingJoinerCoordinator,
    private val client: SyncPairingClient,
) : SyncPairingJoinerServicing {
    override fun acceptAndSubmit(
        text: String,
        deviceId: String,
        spaceId: String,
        platform: String,
    ): String {
        val accepted = coordinator.accept(text, deviceId, spaceId, platform)
        coordinator.submit(client)
        return accepted.shortAuthenticationString
    }

    override fun redeem(sasConfirmed: Boolean) {
        coordinator.redeem(client, sasConfirmed)
    }
}

enum class SyncPairingJoinerUiError {
    CameraDenied,
    NotAvailable,
    InvalidQr,
    PairingFailed,
}

sealed interface SyncPairingJoinerUiState {
    data object Idle : SyncPairingJoinerUiState
    data object RequestingCamera : SyncPairingJoinerUiState
    data object Scanning : SyncPairingJoinerUiState
    data class VerifySas(val digits: String) : SyncPairingJoinerUiState
    data object WaitingApproval : SyncPairingJoinerUiState
    data object Redeeming : SyncPairingJoinerUiState
    data object LinkedSyncOff : SyncPairingJoinerUiState
    data class Error(val reason: SyncPairingJoinerUiError) : SyncPairingJoinerUiState
}

data class SyncPairingJoinerUiActions(
    val canRequestScan: Boolean = false,
    val canLaunchCamera: Boolean = false,
    val canConfirmSas: Boolean = false,
)

/** State owner for the Android half of Mac-host pairing. */
class SyncPairingJoinerUiModel(
    private val service: SyncPairingJoinerServicing,
    private val available: () -> Boolean,
) {
    private val mutableState = MutableStateFlow<SyncPairingJoinerUiState>(SyncPairingJoinerUiState.Idle)
    val state: StateFlow<SyncPairingJoinerUiState> = mutableState.asStateFlow()

    val actions: SyncPairingJoinerUiActions
        get() = when (mutableState.value) {
            SyncPairingJoinerUiState.Idle,
            is SyncPairingJoinerUiState.Error,
            -> SyncPairingJoinerUiActions(canRequestScan = true)
            SyncPairingJoinerUiState.RequestingCamera ->
                SyncPairingJoinerUiActions(canLaunchCamera = true)
            is SyncPairingJoinerUiState.VerifySas,
            SyncPairingJoinerUiState.WaitingApproval,
            -> SyncPairingJoinerUiActions(canConfirmSas = true)
            SyncPairingJoinerUiState.Scanning,
            SyncPairingJoinerUiState.Redeeming,
            SyncPairingJoinerUiState.LinkedSyncOff,
            -> SyncPairingJoinerUiActions()
        }

    fun requestScan() {
        if (!actions.canRequestScan) return
        mutableState.value = if (available()) {
            SyncPairingJoinerUiState.RequestingCamera
        } else {
            SyncPairingJoinerUiState.Error(SyncPairingJoinerUiError.NotAvailable)
        }
    }

    fun cameraPermissionGranted() {
        if (mutableState.value == SyncPairingJoinerUiState.RequestingCamera) {
            mutableState.value = SyncPairingJoinerUiState.Scanning
        }
    }

    fun cameraDenied() {
        if (mutableState.value == SyncPairingJoinerUiState.RequestingCamera ||
            mutableState.value == SyncPairingJoinerUiState.Scanning
        ) {
            mutableState.value = SyncPairingJoinerUiState.Error(SyncPairingJoinerUiError.CameraDenied)
        }
    }

    fun acceptScannedPayload(text: String, deviceId: String, spaceId: String, platform: String) {
        if (mutableState.value != SyncPairingJoinerUiState.Scanning) return
        mutableState.value = try {
            val digits = service.acceptAndSubmit(text, deviceId, spaceId, platform)
            require(digits.length == 6 && digits.all(Char::isDigit))
            SyncPairingJoinerUiState.VerifySas(digits)
        } catch (_: SyncPairingPayload.PayloadException) {
            SyncPairingJoinerUiState.Error(SyncPairingJoinerUiError.InvalidQr)
        } catch (_: Throwable) {
            SyncPairingJoinerUiState.Error(SyncPairingJoinerUiError.PairingFailed)
        }
    }

    fun confirmSasAndRedeem() {
        if (!actions.canConfirmSas) return
        mutableState.value = SyncPairingJoinerUiState.Redeeming
        mutableState.value = try {
            service.redeem(sasConfirmed = true)
            SyncPairingJoinerUiState.LinkedSyncOff
        } catch (error: SyncPairingException) {
            if (error.reason == SyncPairingException.Reason.REJECTED) {
                SyncPairingJoinerUiState.WaitingApproval
            } else {
                SyncPairingJoinerUiState.Error(SyncPairingJoinerUiError.PairingFailed)
            }
        } catch (_: Throwable) {
            SyncPairingJoinerUiState.Error(SyncPairingJoinerUiError.PairingFailed)
        }
    }
}
