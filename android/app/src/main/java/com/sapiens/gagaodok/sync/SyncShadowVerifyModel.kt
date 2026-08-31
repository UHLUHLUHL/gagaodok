package com.sapiens.gagaodok.sync

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

sealed interface SyncShadowVerifyState {
    data object Idle : SyncShadowVerifyState
    data object Running : SyncShadowVerifyState
    data class Finished(val result: SyncShadowVerification) : SyncShadowVerifyState
    data class Failed(val reason: String) : SyncShadowVerifyState
}

/**
 * Pull whatever the account has, then see what this device can make of it.
 *
 * The pull and the verification are one action on purpose. Verifying a stale
 * replica would answer a question nobody asked — "could this device read what
 * it happened to have already" — and would pass even when the room the other
 * device just wrote never arrived.
 */
class SyncShadowVerifyModel(
    private val pull: SyncPullCoordinator,
    private val replica: SyncReplicaStore,
    private val accountId: String,
    private val roomId: String,
    private val loadSecrets: () -> SyncSecretLoadResult,
) {
    private val _state = MutableStateFlow<SyncShadowVerifyState>(SyncShadowVerifyState.Idle)
    val state: StateFlow<SyncShadowVerifyState> = _state

    /** Blocking; the screen runs it off the main thread. */
    fun run() {
        if (_state.value is SyncShadowVerifyState.Running) return
        _state.value = SyncShadowVerifyState.Running
        _state.value = runCatching {
            drain()
            SyncShadowVerifyState.Finished(
                SyncShadowVerifier.verify(replica, accountId, roomId, loadSecrets)
            )
        }.getOrElse { error ->
            SyncShadowVerifyState.Failed(
                when (error) {
                    is SyncShadowVerifyException -> when (error.reason) {
                        SyncShadowVerifyException.Reason.SECRETS_UNAVAILABLE ->
                            "이 기기에 계정 키가 없습니다."
                        SyncShadowVerifyException.Reason.ROOM_ABSENT ->
                            "지정한 시험방이 아직 이 기기에 도착하지 않았습니다."
                        SyncShadowVerifyException.Reason.MALFORMED_REPLICA ->
                            "받은 자료의 모양이 계약과 다릅니다."
                    }
                    is SyncPullException -> "서버에서 받지 못했습니다 (${error.reason.name})."
                    else -> "확인하지 못했습니다."
                }
            )
        }
    }

    /**
     * Bootstrap first if this device has never caught up, then follow changes
     * to the end. A device that only ever pulled `changes` from sequence zero
     * would miss everything written before it joined.
     */
    private fun drain() {
        // A page count rather than `while (true)`: a server that kept saying
        // "there is more" would otherwise spin here forever.
        var pages = 0
        while (!pull.progress().bootstrapComplete && pages < MAX_PAGES) {
            pull.advanceBootstrap()
            pages += 1
        }
        do {
            val progress = pull.advanceChanges()
            pages += 1
        } while (progress.hasMore && pages < MAX_PAGES)
    }

    private companion object {
        const val MAX_PAGES = 200
    }
}
