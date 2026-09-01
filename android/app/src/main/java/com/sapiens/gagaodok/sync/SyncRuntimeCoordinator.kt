package com.sapiens.gagaodok.sync

/**
 * 동기화가 도는 계기. 이 넷 말고는 없다.
 *
 * APNs·FCM·background polling을 쓰지 않는다.
 */
enum class SyncRuntimeTrigger { LAUNCH, FOREGROUND, MANUAL, AFTER_SEND }

enum class SyncRuntimeStatus { DISABLED, IDLE, RUNNING, PAUSED_REVOKED, OFFLINE }

/** Independent gates: a connected account does nothing until sync is enabled. */
data class SyncRuntimeSwitches(
    val syncEnabled: Boolean,
    val remoteReadEnabled: Boolean,
    val remoteReplyEnabled: Boolean,
)

/**
 * Owns scheduling only. The caller owns the opaque pull/upload transaction;
 * this coordinator never opens a local conversation or a remote projection.
 *
 * 스위치를 끄는 것은 지우는 것이 아니다. replica·로컬 대화·outbox·journal은
 * 그대로 남는다.
 */
class SyncRuntimeCoordinator(
    private var switches: SyncRuntimeSwitches,
    private val pull: () -> Unit,
) {
    private var pulling = false
    private var revoked = false

    var status: SyncRuntimeStatus =
        if (switches.syncEnabled) SyncRuntimeStatus.IDLE else SyncRuntimeStatus.DISABLED
        private set

    val canReadRemote: Boolean get() = switches.syncEnabled && switches.remoteReadEnabled && !revoked
    val canReplyRemote: Boolean get() = switches.syncEnabled && switches.remoteReplyEnabled && !revoked

    @Synchronized fun set(next: SyncRuntimeSwitches) {
        switches = next
        if (!revoked) {
            status = if (next.syncEnabled) SyncRuntimeStatus.IDLE else SyncRuntimeStatus.DISABLED
        }
    }

    /** token이 폐기되면 멈추되 outbox와 journal은 남긴다. */
    @Synchronized fun pauseForRevokedToken() {
        revoked = true
        status = SyncRuntimeStatus.PAUSED_REVOKED
    }

    /**
     * 네 계기 전부에서 이것을 부른다.
     *
     * syncEnabled가 꺼져 있으면 요청이 한 건도 나가지 않는다. 설정 화면이나
     * 원격 방 화면을 열었다는 이유만으로는 나가지 않는다.
     */
    @Synchronized fun run(trigger: SyncRuntimeTrigger) {
        if (revoked) return
        if (!switches.syncEnabled) { status = SyncRuntimeStatus.DISABLED; return }
        // 단일 실행 잠금. 겹쳐 불러도 한 번만 돈다.
        if (pulling) return
        pulling = true
        status = SyncRuntimeStatus.RUNNING
        try {
            pull()
        } finally {
            pulling = false
            if (!revoked) status = SyncRuntimeStatus.IDLE
        }
    }

    /** 기존 호출부 호환. */
    @Synchronized fun foreground() = run(SyncRuntimeTrigger.FOREGROUND)
}
