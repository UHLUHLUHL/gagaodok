package com.sapiens.gagaodok.sync

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.URI
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class SyncConnectionConfiguration(
    val baseUrl: String,
    val accountId: String,
    val deviceId: String,
    val enabled: Boolean = false,
    val changesCursor: String? = null,
) {
    init {
        val uri = runCatching { URI(baseUrl) }.getOrNull()
        require(uri?.scheme == "https" && !uri.host.isNullOrEmpty() && uri.userInfo == null && uri.query == null && uri.fragment == null)
        require(UUID.matches(accountId) && UUID.matches(deviceId))
        require(changesCursor == null || changesCursor.isNotEmpty() && changesCursor.length <= 4096)
    }
    companion object { internal val UUID = Regex("[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}") }
}

sealed interface SyncConnectionLoadResult {
    data object Absent : SyncConnectionLoadResult
    data class Available(val configuration: SyncConnectionConfiguration) : SyncConnectionLoadResult
    data object RelinkRequired : SyncConnectionLoadResult
}
class SyncConnectionStateException(message: String) : Exception(message)

class SyncConnectionStateStore(private val file: File) {
    @Synchronized fun load(): SyncConnectionLoadResult {
        if (!file.exists()) return SyncConnectionLoadResult.Absent
        return runCatching {
            val stored = Json.decodeFromString<Stored>(file.readText())
            require(stored.version == 1)
            SyncConnectionLoadResult.Available(stored.configuration)
        }.getOrElse { SyncConnectionLoadResult.RelinkRequired }
    }
    @Synchronized fun save(configuration: SyncConnectionConfiguration): Boolean = runCatching {
        file.parentFile?.mkdirs(); atomicWrite(Json.encodeToString(Stored.serializer(), Stored(1, configuration)).toByteArray()); true
    }.getOrDefault(false)
    private fun atomicWrite(bytes: ByteArray) {
        val temp = File(file.parentFile, "${file.name}.tmp")
        FileOutputStream(temp).use { it.write(bytes); it.fd.sync() }
        if (!temp.renameTo(file)) { temp.delete(); throw SyncConnectionStateException("atomic replace failed") }
    }
    @Serializable private data class Stored(val version: Int, val configuration: SyncConnectionConfiguration)
}

data class SyncPendingEnrollment(val enrollmentId: String, val rawBody: ByteArray) {
    override fun equals(other: Any?) = other is SyncPendingEnrollment && enrollmentId == other.enrollmentId && rawBody.contentEquals(other.rawBody)
    override fun hashCode() = 31 * enrollmentId.hashCode() + rawBody.contentHashCode()
}

class SyncEnrollmentJournal(private val file: File) {
    @Synchronized fun stage(enrollmentId: String, rawBody: ByteArray): Boolean {
        if (!SyncConnectionConfiguration.UUID.matches(enrollmentId) || rawBody.isEmpty() || rawBody.size > MAX_BODY) throw SyncConnectionStateException("invalid enrollment")
        pending()?.let {
            if (it.enrollmentId != enrollmentId || !it.rawBody.contentEquals(rawBody)) throw SyncConnectionStateException("replay mismatch")
            return false
        }
        persist(enrollmentId, rawBody); return true
    }
    @Synchronized fun pending(): SyncPendingEnrollment? {
        if (!file.exists()) return null
        return runCatching {
            DataInputStream(FileInputStream(file)).use { input ->
                require(input.readInt() == MAGIC && input.readInt() == VERSION)
                val id=input.readUTF(); val size=input.readInt()
                require(SyncConnectionConfiguration.UUID.matches(id) && size in 1..MAX_BODY)
                val body=ByteArray(size).also(input::readFully); require(input.read() == -1)
                SyncPendingEnrollment(id, body)
            }
        }.getOrElse { throw SyncConnectionStateException("corrupt store") }
    }
    @Synchronized fun acknowledge(enrollmentId: String): Boolean {
        val existing=pending() ?: return false
        if (existing.enrollmentId != enrollmentId) throw SyncConnectionStateException("replay mismatch")
        return file.delete()
    }
    private fun persist(id:String,body:ByteArray){
        file.parentFile?.mkdirs();val temp=File(file.parentFile,"${file.name}.tmp")
        FileOutputStream(temp).use{stream->DataOutputStream(stream).use{out->out.writeInt(MAGIC);out.writeInt(VERSION);out.writeUTF(id);out.writeInt(body.size);out.write(body);out.flush();stream.fd.sync()}}
        if(!temp.renameTo(file)){temp.delete();throw SyncConnectionStateException("atomic replace failed")}
    }
    companion object{private const val MAGIC=0x47454e31;private const val VERSION=1;private const val MAX_BODY=1_048_576}
}
