package com.sapiens.gagaodok.sync

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The state a synthetic-account sync screen can be in, and the only way to move
 * between those states.
 *
 * The screen itself does nothing. Opening it reads stored status and stops;
 * every transition that sends a request, stores a secret or writes the replica
 * is behind a method a button has to call. That is the whole point of putting
 * the state here rather than in the composable: an accidental recomposition
 * cannot enroll a device.
 *
 * Nothing in this file touches ChatStore or any conversation file. The only
 * thing a successful pull writes is the opaque shadow replica.
 */
sealed interface SyncOnboardingUiState {
    /** Nothing is linked. The screen offers to start, and offers nothing else. */
    data object Disconnected : SyncOnboardingUiState

    /** Building the enrollment locally. No request has been sent. */
    data object Preparing : SyncOnboardingUiState

    /** The recovery phrase is on screen and must be confirmed before sending. */
    data object AwaitingPhraseConfirmation : SyncOnboardingUiState

    /** The enrollment request is in flight. */
    data object Enrolling : SyncOnboardingUiState

    /** Linked, and deliberately not synchronising. */
    data object ConnectedSyncOff : SyncOnboardingUiState

    /** Walking the synthetic snapshot, one page per press. */
    data class Bootstrapping(val appliedItems: Int) : SyncOnboardingUiState

    /** The shadow replica holds the synthetic snapshot. */
    data class ReplicaReady(val entryCount: Int) : SyncOnboardingUiState

    /** Secrets and endpoint state disagree. No key is generated to repair it. */
    data object RelinkRequired : SyncOnboardingUiState

    /** Something failed and the same action can be tried again. */
    data class RetryableError(val error: SyncOnboardingUiError) : SyncOnboardingUiState
}

/**
 * A failure the screen can describe without describing anything sensitive.
 *
 * There is no associated endpoint, token, phrase, ciphertext or server message:
 * a case name is all the screen ever shows, and all a log would get.
 */
enum class SyncOnboardingUiError {
    PHRASE_NOT_CONFIRMED,
    ENROLLMENT_REFUSED,
    ENROLLMENT_REFUSED_RETRY_PENDING,
    STORAGE_FAILED,
    NETWORK_FAILED,
    BOOTSTRAP_FAILED,
}

/**
 * What the screen may offer right now.
 *
 * Derived from the state rather than decided in the composable, so a button
 * cannot exist in a state its action would be unsafe in.
 */
data class SyncOnboardingActions(
    val canBeginConnection: Boolean = false,
    val canConfirmPhrase: Boolean = false,
    val canRetryEnrollment: Boolean = false,
    val canAdvanceBootstrap: Boolean = false,
    val canRequestDisconnect: Boolean = false,
)

data class SyncOnboardingIdentity(
    val accountId: String,
    val deviceId: String,
    val enrollmentId: String,
)

class SyncOnboardingModel(
    private val onboarding: SyncOnboardingCoordinator,
    private val pull: SyncPullCoordinator,
    private val replica: SyncReplicaStore,
    private val spaceId: String,
    private val platform: String,
    private val identity: () -> SyncOnboardingIdentity,
) {
    private val _state = MutableStateFlow<SyncOnboardingUiState>(SyncOnboardingUiState.Disconnected)
    val state: StateFlow<SyncOnboardingUiState> = _state.asStateFlow()

    /**
     * Shown exactly once, held only in memory, and cleared the moment the user
     * confirms. It reaches no file, setting or log.
     */
    private val _recoveryPhrase = MutableStateFlow<String?>(null)
    val recoveryPhrase: StateFlow<String?> = _recoveryPhrase.asStateFlow()

    /** A confirmation sheet only. Nothing is deleted in this build. */
    private val _disconnectConfirmationVisible = MutableStateFlow(false)
    val disconnectConfirmationVisible: StateFlow<Boolean> = _disconnectConfirmationVisible.asStateFlow()

    private var draft: SyncOnboardingDraft? = null

    val actions: SyncOnboardingActions
        get() = when (val current = _state.value) {
            is SyncOnboardingUiState.Disconnected ->
                SyncOnboardingActions(canBeginConnection = true)
            is SyncOnboardingUiState.AwaitingPhraseConfirmation ->
                SyncOnboardingActions(canConfirmPhrase = true)
            is SyncOnboardingUiState.ConnectedSyncOff, is SyncOnboardingUiState.Bootstrapping ->
                SyncOnboardingActions(canAdvanceBootstrap = true, canRequestDisconnect = true)
            is SyncOnboardingUiState.ReplicaReady ->
                SyncOnboardingActions(canRequestDisconnect = true)
            is SyncOnboardingUiState.RetryableError -> when (current.error) {
                // The journal holds the exact bytes, so the only safe offer is
                // to send those again — never to build a fresh enrollment.
                SyncOnboardingUiError.ENROLLMENT_REFUSED_RETRY_PENDING,
                SyncOnboardingUiError.NETWORK_FAILED,
                -> SyncOnboardingActions(canRetryEnrollment = true)
                SyncOnboardingUiError.BOOTSTRAP_FAILED ->
                    SyncOnboardingActions(canAdvanceBootstrap = true, canRequestDisconnect = true)
                SyncOnboardingUiError.ENROLLMENT_REFUSED,
                SyncOnboardingUiError.PHRASE_NOT_CONFIRMED,
                SyncOnboardingUiError.STORAGE_FAILED,
                -> SyncOnboardingActions(canBeginConnection = true)
            }
            else -> SyncOnboardingActions()
        }

    /**
     * Read stored status. Sends nothing, stores nothing, writes nothing.
     *
     * This is what the screen calls when it appears, and it is deliberately the
     * only thing that runs without a press.
     */
    fun refresh() {
        _state.value = when (onboarding.status()) {
            is SyncOnboardingStatus.Disconnected -> SyncOnboardingUiState.Disconnected
            // A half-finished link is reported, never repaired. Generating a
            // replacement key here would silently orphan the account the
            // existing half belongs to.
            is SyncOnboardingStatus.RelinkRequired -> SyncOnboardingUiState.RelinkRequired
            is SyncOnboardingStatus.Connected -> {
                val progress = pull.progress()
                val entries = runCatching { replica.snapshot().size }.getOrDefault(0)
                when {
                    progress.bootstrapComplete && entries > 0 -> SyncOnboardingUiState.ReplicaReady(entries)
                    progress.snapshotWatermark != null -> SyncOnboardingUiState.Bootstrapping(entries)
                    else -> SyncOnboardingUiState.ConnectedSyncOff
                }
            }
        }
    }

    /** Build the enrollment and show the phrase. Still sends nothing. */
    fun beginConnection() {
        if (!actions.canBeginConnection) return
        _state.value = SyncOnboardingUiState.Preparing
        val ids = identity()
        try {
            val prepared = onboarding.prepare(ids.accountId, ids.deviceId, ids.enrollmentId, spaceId, platform)
            draft = prepared
            _recoveryPhrase.value = prepared.recoveryPhrase
            _state.value = SyncOnboardingUiState.AwaitingPhraseConfirmation
        } catch (error: SyncOnboardingException) {
            _state.value = when (error.reason) {
                SyncOnboardingException.Reason.RELINK_REQUIRED -> SyncOnboardingUiState.RelinkRequired
                else -> SyncOnboardingUiState.RetryableError(SyncOnboardingUiError.STORAGE_FAILED)
            }
        }
    }

    /** The user says the phrase is written down. Only now is anything sent. */
    fun confirmPhraseSaved() {
        val current = draft
        if (!actions.canConfirmPhrase || current == null) return
        _state.value = SyncOnboardingUiState.Enrolling
        try {
            onboarding.confirm(current, current.recoveryPhrase)
            // The phrase leaves memory the moment it is no longer needed.
            _recoveryPhrase.value = null
            draft = null
            _state.value = SyncOnboardingUiState.ConnectedSyncOff
        } catch (error: SyncOnboardingException) {
            _recoveryPhrase.value = null
            _state.value = SyncOnboardingUiState.RetryableError(
                when (error.reason) {
                    SyncOnboardingException.Reason.PHRASE_NOT_CONFIRMED ->
                        SyncOnboardingUiError.PHRASE_NOT_CONFIRMED
                    // The journal kept the bytes, so the retry is a replay
                    // rather than a second enrollment for the same account.
                    SyncOnboardingException.Reason.ENROLLMENT_REJECTED ->
                        SyncOnboardingUiError.ENROLLMENT_REFUSED_RETRY_PENDING
                    else -> SyncOnboardingUiError.STORAGE_FAILED
                },
            )
        } catch (error: Exception) {
            _recoveryPhrase.value = null
            _state.value = SyncOnboardingUiState.RetryableError(SyncOnboardingUiError.NETWORK_FAILED)
        }
    }

    /** Resend the staged bytes. Never rebuilds the request. */
    fun retryEnrollment() {
        val secrets = draft?.enrollmentPackage?.secrets
        if (!actions.canRetryEnrollment || secrets == null) {
            _state.value = SyncOnboardingUiState.RetryableError(SyncOnboardingUiError.STORAGE_FAILED)
            return
        }
        _state.value = SyncOnboardingUiState.Enrolling
        try {
            onboarding.retryPendingEnrollment(secrets)
            draft = null
            _state.value = SyncOnboardingUiState.ConnectedSyncOff
        } catch (error: SyncOnboardingException) {
            _state.value = SyncOnboardingUiState.RetryableError(
                if (error.reason == SyncOnboardingException.Reason.ENROLLMENT_REJECTED) {
                    SyncOnboardingUiError.ENROLLMENT_REFUSED_RETRY_PENDING
                } else {
                    SyncOnboardingUiError.STORAGE_FAILED
                },
            )
        } catch (error: Exception) {
            _state.value = SyncOnboardingUiState.RetryableError(SyncOnboardingUiError.NETWORK_FAILED)
        }
    }

    /** Walk one page of the synthetic snapshot into the shadow replica. */
    fun advanceBootstrap() {
        if (!actions.canAdvanceBootstrap) return
        try {
            val progress = pull.advanceBootstrap()
            val entries = runCatching { replica.snapshot().size }.getOrDefault(0)
            _state.value = if (progress.bootstrapComplete) {
                SyncOnboardingUiState.ReplicaReady(entries)
            } else {
                SyncOnboardingUiState.Bootstrapping(entries)
            }
        } catch (error: Exception) {
            // A refused page left the cursor where it was, so the same page is
            // fetched again rather than skipped.
            _state.value = SyncOnboardingUiState.RetryableError(SyncOnboardingUiError.BOOTSTRAP_FAILED)
        }
    }

    /** Show the confirmation only. Nothing is deleted in this build. */
    fun requestDisconnect() {
        if (!actions.canRequestDisconnect) return
        _disconnectConfirmationVisible.value = true
    }

    fun dismissDisconnect() {
        _disconnectConfirmationVisible.value = false
    }
}
