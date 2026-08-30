package com.sapiens.gagaodok.sync

import java.io.File
import java.io.FileOutputStream
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

interface SyncSlottedSecretVault {
    fun load(slot: SyncSecretSlot): SyncSecretLoadResult
    fun save(secrets: SyncSecretBundle, slot: SyncSecretSlot): Boolean
    fun remove(slot: SyncSecretSlot): Boolean
}

class KeystoreSyncSlottedSecretVault(private val store: SyncSecretStore) : SyncSlottedSecretVault {
    override fun load(slot: SyncSecretSlot) = store.load(slot)
    override fun save(secrets: SyncSecretBundle, slot: SyncSecretSlot) = store.save(secrets, slot)
    override fun remove(slot: SyncSecretSlot) = store.remove(slot)
}

@Serializable
enum class SyncTransitionStage { STAGED, COMMITTING }

@Serializable
enum class SyncTransitionOperation { SWITCH_ACCOUNT, UNLINK }

@Serializable
data class SyncAccountTransitionRecord(
    val version: Int = 1,
    val stage: SyncTransitionStage,
    val operation: SyncTransitionOperation = SyncTransitionOperation.SWITCH_ACCOUNT,
    @SerialName("old_account_id") val oldAccountId: String,
    @SerialName("new_account_id") val newAccountId: String? = null,
    @SerialName("created_at_ms") val createdAtMilliseconds: Long,
)

class SyncAccountTransitionStoreException(message: String) : Exception(message)

class SyncAccountTransitionJournal(private val file: File) {
    private val json = Json { ignoreUnknownKeys = false; explicitNulls = false }

    @Synchronized fun save(record: SyncAccountTransitionRecord) {
        validate(record)
        atomicWrite(json.encodeToString(SyncAccountTransitionRecord.serializer(), record).toByteArray())
    }

    @Synchronized fun load(): SyncAccountTransitionRecord? {
        if (!file.exists()) return null
        return runCatching {
            json.decodeFromString(SyncAccountTransitionRecord.serializer(), file.readText()).also(::validate)
        }.getOrElse { throw SyncAccountTransitionStoreException("corrupt transition journal") }
    }

    @Synchronized fun remove(): Boolean = !file.exists() || file.delete()

    private fun validate(record: SyncAccountTransitionRecord) {
        if (record.version != 1 || !UUID.matches(record.oldAccountId) || record.createdAtMilliseconds <= 0) {
            throw SyncAccountTransitionStoreException("invalid transition journal")
        }
        when (record.operation) {
            SyncTransitionOperation.SWITCH_ACCOUNT -> if (
                record.newAccountId == null || !UUID.matches(record.newAccountId) || record.newAccountId == record.oldAccountId
            ) throw SyncAccountTransitionStoreException("invalid transition identity")
            SyncTransitionOperation.UNLINK -> if (record.newAccountId != null) {
                throw SyncAccountTransitionStoreException("invalid unlink identity")
            }
        }
    }

    private fun atomicWrite(bytes: ByteArray) {
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, "${file.name}.tmp")
        FileOutputStream(temp).use { it.write(bytes); it.fd.sync() }
        if (!temp.renameTo(file)) { temp.delete(); throw SyncAccountTransitionStoreException("atomic replace failed") }
    }

    companion object {
        private val UUID = Regex("[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}")
    }
}

enum class SyncTransitionFileRole(val fileName: String) {
    CONNECTION("connection.json"),
    REPLICA("replica.json"),
    CURSOR("pull.json"),
    OUTBOX("outbox.bin"),
}

class SyncTransitionFiles(private val directory: File) {
    @Synchronized fun writeActive(bytes: ByteArray, role: SyncTransitionFileRole) = atomicWrite(bytes, file(role, ""))
    @Synchronized fun stage(bytes: ByteArray, role: SyncTransitionFileRole) = atomicWrite(bytes, file(role, ".staging"))
    @Synchronized fun readActive(role: SyncTransitionFileRole): ByteArray? = file(role, "").takeIf(File::exists)?.readBytes()

    @Synchronized fun prepareRollback() {
        SyncTransitionFileRole.entries.forEach { role ->
            val active = file(role, "")
            val rollback = file(role, ".rollback")
            if (active.exists()) atomicWrite(active.readBytes(), rollback) else rollback.delete()
        }
    }

    @Synchronized fun promote() {
        SyncTransitionFileRole.entries.forEach { role ->
            val staging = file(role, ".staging")
            if (staging.exists()) atomicWrite(staging.readBytes(), file(role, ""))
        }
        if (!file(SyncTransitionFileRole.CONNECTION, "").exists()) {
            throw SyncAccountTransitionStoreException("missing staged connection")
        }
    }

    @Synchronized fun restore() {
        if (!file(SyncTransitionFileRole.CONNECTION, ".rollback").exists()) {
            throw SyncAccountTransitionStoreException("missing rollback connection")
        }
        SyncTransitionFileRole.entries.forEach { role ->
            val rollback = file(role, ".rollback")
            val active = file(role, "")
            if (rollback.exists()) atomicWrite(rollback.readBytes(), active) else active.delete()
        }
    }

    @Synchronized fun discardTransient() {
        SyncTransitionFileRole.entries.forEach { role ->
            file(role, ".staging").delete()
            file(role, ".rollback").delete()
        }
    }

    @Synchronized fun removeActive(role: SyncTransitionFileRole): Boolean =
        !file(role, "").exists() || file(role, "").delete()

    @Synchronized fun removeAllActive() {
        SyncTransitionFileRole.entries.forEach { role ->
            if (!removeActive(role)) throw SyncAccountTransitionStoreException("active remove failed")
        }
    }

    @Synchronized fun hasTransientFiles(): Boolean = SyncTransitionFileRole.entries.any { role ->
        file(role, ".staging").exists() || file(role, ".rollback").exists()
    }

    private fun file(role: SyncTransitionFileRole, suffix: String) = File(directory, role.fileName + suffix)

    private fun atomicWrite(bytes: ByteArray, target: File) {
        target.parentFile?.mkdirs()
        val temp = File(target.parentFile, "${target.name}.tmp")
        FileOutputStream(temp).use { it.write(bytes); it.fd.sync() }
        if (!temp.renameTo(target)) { temp.delete(); throw SyncAccountTransitionStoreException("atomic replace failed") }
    }
}
