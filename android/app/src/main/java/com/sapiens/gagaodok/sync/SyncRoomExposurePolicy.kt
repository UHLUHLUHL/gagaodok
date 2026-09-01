package com.sapiens.gagaodok.sync

object SyncRoomExposurePolicy {
    fun isVisible(originSpaceId: String, viewerSpaceId: String): Boolean = when {
        originSpaceId == "MAC_SPACE" && viewerSpaceId == "PHONE_SPACE" -> true
        originSpaceId == "TABLET_SPACE" && viewerSpaceId == "MAC_SPACE" -> true
        originSpaceId == "TABLET_SPACE" && viewerSpaceId == "PHONE_SPACE" -> true
        else -> false
    }
}

/** Read-only UI boundary with no ChatStore or local conversation path. */
class SyncRemoteRoomCatalog(
    private val repository: SyncRemoteRoomRepository,
    private val viewerSpaceId: String,
) {
    fun refresh(): List<SyncRemoteRoomSnapshot> = repository.list()
        .filter { SyncRoomExposurePolicy.isVisible(it.handle.originSpaceId, viewerSpaceId) }
        .sortedWith(
            compareByDescending<SyncRemoteRoomSnapshot> { it.messages.lastOrNull()?.timestamp ?: "" }
                .thenBy { it.handle.roomId },
        )

    fun open(handle: SyncRoomHandle): SyncRemoteRoomSnapshot? {
        if (!SyncRoomExposurePolicy.isVisible(handle.originSpaceId, viewerSpaceId)) return null
        return repository.load(handle)
    }
}
