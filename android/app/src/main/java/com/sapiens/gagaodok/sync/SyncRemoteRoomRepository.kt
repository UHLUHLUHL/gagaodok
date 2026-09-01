package com.sapiens.gagaodok.sync

import java.io.File
import java.io.FileOutputStream
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class SyncRemoteRoomRepositoryException(message: String) : Exception(message)

/** Owns only sync/remote/rooms and atomically replaces one origin family. */
class SyncRemoteRoomRepository(private val rootDirectory: File) {
    @Synchronized
    fun replace(snapshot: SyncRemoteRoomSnapshot) {
        val target = file(snapshot.handle)
        target.parentFile?.mkdirs()
        val temp = File(target.parentFile, "${target.name}.tmp")
        try {
            FileOutputStream(temp).use {
                it.write(Json.encodeToString(snapshot).toByteArray())
                it.fd.sync()
            }
            if (!temp.renameTo(target)) throw SyncRemoteRoomRepositoryException("atomic replace failed")
        } finally {
            if (temp.exists()) temp.delete()
        }
    }

    @Synchronized
    fun load(handle: SyncRoomHandle): SyncRemoteRoomSnapshot? {
        val target = file(handle)
        if (!target.exists()) return null
        return runCatching { Json.decodeFromString<SyncRemoteRoomSnapshot>(target.readText()) }
            .getOrElse { throw SyncRemoteRoomRepositoryException("corrupt snapshot") }
            .also { if (it.handle != handle) throw SyncRemoteRoomRepositoryException("corrupt snapshot") }
    }

    @Synchronized
    fun list(): List<SyncRemoteRoomSnapshot> {
        val base = File(rootDirectory, "sync/remote/rooms")
        if (!base.exists()) return emptyList()
        return base.walkTopDown().filter { it.isFile && it.extension == "json" }.sortedBy { it.path }.map {
            runCatching { Json.decodeFromString<SyncRemoteRoomSnapshot>(it.readText()) }
                .getOrElse { throw SyncRemoteRoomRepositoryException("corrupt snapshot") }
        }.toList()
    }

    private fun file(handle: SyncRoomHandle): File {
        if (handle.originSpaceId !in SPACES || canonicalUuid(handle.roomId) == null) {
            throw SyncRemoteRoomRepositoryException("invalid handle")
        }
        return File(rootDirectory, "sync/remote/rooms/${handle.originSpaceId}/${handle.roomId}.json")
    }

    private fun canonicalUuid(value: String): String? = runCatching {
        java.util.UUID.fromString(value).toString().uppercase().takeIf { it == value }
    }.getOrNull()

    companion object {
        private val SPACES = setOf("MAC_SPACE", "PHONE_SPACE", "TABLET_SPACE")
    }
}
