package com.sapiens.gagaodok.sync

/**
 * 동기화가 도는 계기. 이 넷 말고는 없다.
 *
 * APNs·FCM·background polling을 쓰지 않는다.
 */
enum class SyncRuntimeTrigger { LAUNCH, FOREGROUND, MANUAL, AFTER_SEND }

enum class SyncRuntimeStatus {
    DISABLED,
    IDLE,
    RUNNING,
    PAUSED_REVOKED,
    OFFLINE,
    ;

    /**
     * 동기화가 켜져 있고 정상인가.
     *
     * 표시등 색이 이걸 따른다. RUNNING만 초록으로 두면 대부분의 시간에 꺼진
     * 것과 구별되지 않는다 — 실제로 도는 순간은 아주 짧다.
     */
    val isActive: Boolean
        get() = this == IDLE || this == RUNNING

    /**
     * 화면에 그대로 쓰는 문구.
     *
     * DISABLED에서 "동기화 중"이라고 말하지 않는 것이 이 매핑의 핵심이다.
     * 순수 함수로 둔 이유는 앱을 띄우지 않고도 그 불변식을 시험하기 위해서다.
     */
    val label: String
        get() = when (this) {
            DISABLED -> "동기화가 꺼져 있습니다."
            IDLE -> "마지막으로 확인함"
            RUNNING -> "확인하는 중"
            PAUSED_REVOKED -> "이 기기의 연결이 해제되었습니다."
            OFFLINE -> "연결할 수 없습니다."
        }
}

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
