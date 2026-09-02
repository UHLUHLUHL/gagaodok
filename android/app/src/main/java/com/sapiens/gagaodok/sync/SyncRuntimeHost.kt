package com.sapiens.gagaodok.sync

/**
 * 앱 lifecycle이 붙잡는 단 하나의 지점.
 *
 * 기본값이 전부 꺼짐이므로 여기에 연결하는 것만으로는 요청이 한 건도 나가지
 * 않는다. 실제 pull은 연결이 활성화될 때 [attach]로 주입한다.
 */
object SyncRuntimeHost {
    private var coordinator = SyncRuntimeCoordinator(
        SyncRuntimeSwitches(syncEnabled = false, remoteReadEnabled = false, remoteReplyEnabled = false),
    ) {}

    val status: SyncRuntimeStatus get() = coordinator.status
    val canReadRemote: Boolean get() = coordinator.canReadRemote
    val canReplyRemote: Boolean get() = coordinator.canReplyRemote

    /** 연결이 만들어진 뒤에만 부른다. 부르기 전에는 아무 일도 하지 않는 coordinator다. */
    @Synchronized fun attach(switches: SyncRuntimeSwitches, pull: () -> Unit) {
        coordinator = SyncRuntimeCoordinator(switches, pull)
    }

    fun set(switches: SyncRuntimeSwitches) = coordinator.set(switches)
    fun pauseForRevokedToken() = coordinator.pauseForRevokedToken()
    fun run(trigger: SyncRuntimeTrigger) = coordinator.run(trigger)

    /** 상태 표시 문구. syncEnabled=false인 동안 "동기화 중"이라고 말하지 않는다. */
    val statusLabel: String get() = coordinator.status.label
}
