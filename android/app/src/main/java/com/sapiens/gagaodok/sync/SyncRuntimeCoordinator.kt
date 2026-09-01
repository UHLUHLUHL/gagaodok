package com.sapiens.gagaodok.sync

/** Independent gates: a connected account does nothing until sync is enabled. */
data class SyncRuntimeSwitches(
    val syncEnabled: Boolean,
    val remoteReadEnabled: Boolean,
    val remoteReplyEnabled: Boolean,
)

/**
 * Owns scheduling only. The caller owns the opaque pull/upload transaction;
 * this coordinator never opens a local conversation or a remote projection.
 */
class SyncRuntimeCoordinator(
    private var switches: SyncRuntimeSwitches,
    private val pull: () -> Unit,
) {
    private var pulling = false

    val canReadRemote: Boolean get() = switches.syncEnabled && switches.remoteReadEnabled
    val canReplyRemote: Boolean get() = switches.syncEnabled && switches.remoteReplyEnabled

    @Synchronized fun set(next: SyncRuntimeSwitches) { switches = next }

    @Synchronized fun foreground() {
        if (!switches.syncEnabled || pulling) return
        pulling = true
        try { pull() } finally { pulling = false }
    }
}
