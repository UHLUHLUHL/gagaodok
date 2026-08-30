package com.sapiens.gagaodok.sync

/**
 * The states a pairing screen can be in, on each side.
 *
 * The states live here rather than in a composable for the same reason the
 * onboarding states do: a view that decides for itself when to show a button
 * can offer an action the state machine considers unsafe. Approving without a
 * confirmed SAS is exactly such an action.
 */
sealed interface SyncPairingHostState {
    data object Idle : SyncPairingHostState

    /** A session exists and the payload is on screen. */
    data object SessionReady : SyncPairingHostState
    data object WaitingClaim : SyncPairingHostState

    /** A device is waiting and the six digits are shown for comparison. */
    data class VerifySAS(val digits: String) : SyncPairingHostState
    data object Approving : SyncPairingHostState
    data object Completed : SyncPairingHostState
    data object Expired : SyncPairingHostState
    data class Error(val reason: SyncPairingException.Reason) : SyncPairingHostState
}

sealed interface SyncPairingJoinerState {
    data object Idle : SyncPairingJoinerState

    /** A payload has been read. Nothing has been sent. */
    data object QrAccepted : SyncPairingJoinerState
    data object Submitting : SyncPairingJoinerState
    data class VerifySAS(val digits: String) : SyncPairingJoinerState
    data object WaitingApproval : SyncPairingJoinerState
    data object Redeeming : SyncPairingJoinerState

    /** Joined, and deliberately not synchronising. */
    data object LinkedSyncOff : SyncPairingJoinerState
    data class Error(val reason: SyncPairingException.Reason) : SyncPairingJoinerState
}

/**
 * What each side may offer right now. Derived from the state, never decided in
 * a composable.
 */
data class SyncPairingActions(
    val canOpenSession: Boolean = false,
    val canPoll: Boolean = false,
    val canApprove: Boolean = false,
    val canAcceptPayload: Boolean = false,
    val canSubmit: Boolean = false,
    val canRedeem: Boolean = false,
) {
    companion object {
        fun forHost(state: SyncPairingHostState): SyncPairingActions = when (state) {
            is SyncPairingHostState.Idle,
            is SyncPairingHostState.Expired,
            is SyncPairingHostState.Error,
            -> SyncPairingActions(canOpenSession = true)
            is SyncPairingHostState.SessionReady,
            is SyncPairingHostState.WaitingClaim,
            -> SyncPairingActions(canPoll = true)
            // Approving is offered only once digits are on screen to compare,
            // and the coordinator still refuses without an explicit
            // confirmation.
            is SyncPairingHostState.VerifySAS -> SyncPairingActions(canApprove = true)
            is SyncPairingHostState.Approving, is SyncPairingHostState.Completed ->
                SyncPairingActions()
        }

        fun forJoiner(state: SyncPairingJoinerState): SyncPairingActions = when (state) {
            is SyncPairingJoinerState.Idle, is SyncPairingJoinerState.Error ->
                SyncPairingActions(canAcceptPayload = true)
            is SyncPairingJoinerState.QrAccepted -> SyncPairingActions(canSubmit = true)
            // Redeeming before the host approves would be a guess; the joiner
            // waits for the human comparison on both screens first.
            is SyncPairingJoinerState.VerifySAS,
            is SyncPairingJoinerState.WaitingApproval,
            -> SyncPairingActions(canRedeem = true)
            is SyncPairingJoinerState.Submitting,
            is SyncPairingJoinerState.Redeeming,
            is SyncPairingJoinerState.LinkedSyncOff,
            -> SyncPairingActions()
        }
    }
}
