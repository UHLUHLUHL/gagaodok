package com.sapiens.gagaodok.sync

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class SyncTransitionAvailability { READY, SYNC_ENABLED, OUTBOX_PENDING, NO_ACTIVE_ACCOUNT, RECOVERY_REQUIRED }

interface SyncAccountTransitionServicing {
    fun availability(): SyncTransitionAvailability
    fun unlink()
}

enum class SyncAccountTransitionUiState {
    IDLE, READY, BLOCKED, CONFIRMING_JOIN, JOINING, CONFIRMING_UNLINK,
    UNLINKING, UNLINKED, ERROR,
}

data class SyncAccountTransitionActions(
    val canRequestJoin: Boolean = false,
    val canConfirmJoin: Boolean = false,
    val canStartScanner: Boolean = false,
    val canRequestUnlink: Boolean = false,
    val canConfirmUnlink: Boolean = false,
    val canDismiss: Boolean = false,
)

class SyncAccountTransitionModel(private val service: SyncAccountTransitionServicing) {
    private val mutableState = MutableStateFlow(SyncAccountTransitionUiState.IDLE)
    val state: StateFlow<SyncAccountTransitionUiState> = mutableState.asStateFlow()

    val actions: SyncAccountTransitionActions
        get() = when (mutableState.value) {
            SyncAccountTransitionUiState.READY -> SyncAccountTransitionActions(
                canRequestJoin = true, canRequestUnlink = true,
            )
            SyncAccountTransitionUiState.CONFIRMING_JOIN -> SyncAccountTransitionActions(
                canConfirmJoin = true, canDismiss = true,
            )
            SyncAccountTransitionUiState.JOINING -> SyncAccountTransitionActions(
                canStartScanner = true, canDismiss = true,
            )
            SyncAccountTransitionUiState.CONFIRMING_UNLINK -> SyncAccountTransitionActions(
                canConfirmUnlink = true, canDismiss = true,
            )
            SyncAccountTransitionUiState.ERROR -> SyncAccountTransitionActions(canDismiss = true)
            else -> SyncAccountTransitionActions()
        }

    fun refresh() {
        mutableState.value = when (service.availability()) {
            SyncTransitionAvailability.READY -> SyncAccountTransitionUiState.READY
            else -> SyncAccountTransitionUiState.BLOCKED
        }
    }

    fun requestJoin() {
        if (actions.canRequestJoin) mutableState.value = SyncAccountTransitionUiState.CONFIRMING_JOIN
    }

    fun confirmJoin() {
        if (actions.canConfirmJoin) mutableState.value = SyncAccountTransitionUiState.JOINING
    }

    fun requestUnlink() {
        if (actions.canRequestUnlink) mutableState.value = SyncAccountTransitionUiState.CONFIRMING_UNLINK
    }

    fun confirmUnlink() {
        if (!actions.canConfirmUnlink) return
        mutableState.value = SyncAccountTransitionUiState.UNLINKING
        mutableState.value = try {
            service.unlink()
            SyncAccountTransitionUiState.UNLINKED
        } catch (_: Throwable) {
            SyncAccountTransitionUiState.ERROR
        }
    }

    fun dismiss() {
        if (actions.canDismiss) refresh()
    }
}
