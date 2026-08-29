package com.sapiens.gagaodok.sync

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

data class SyncOutboxEntry(val operationId: String, val rawBody: ByteArray) {
    override fun equals(other: Any?): Boolean = other is SyncOutboxEntry && operationId == other.operationId && rawBody.contentEquals(other.rawBody)
    override fun hashCode(): Int = 31 * operationId.hashCode() + rawBody.contentHashCode()
}
class SyncOutboxException(message: String) : Exception(message)

/** Durable journal retaining the exact encrypted request bytes across retries. */
class SyncOutbox(private val file: File) {
    private data class Stored(val order: Long, val operationId: String, val rawBody: ByteArray)
    private var nextOrder = 1L
    private val entries = mutableListOf<Stored>()
    init { load() }

    @Synchronized fun enqueue(operationId: String, rawBody: ByteArray): Boolean {
        if (!UUID.matches(operationId)) throw SyncOutboxException("invalid operation id")
        if (rawBody.isEmpty() || rawBody.size > MAX_BODY) throw SyncOutboxException("invalid body")
        entries.firstOrNull { it.operationId == operationId }?.let {
            if (!it.rawBody.contentEquals(rawBody)) throw SyncOutboxException("replay mismatch")
            return false
        }
        entries += Stored(nextOrder++, operationId, rawBody.copyOf())
        persist(); return true
    }
    @Synchronized fun pending(): List<SyncOutboxEntry> = entries.sortedBy { it.order }.map { SyncOutboxEntry(it.operationId, it.rawBody.copyOf()) }
    @Synchronized fun acknowledge(operationId: String): Boolean { val changed=entries.removeAll{it.operationId==operationId};if(changed)persist();return changed }

    private fun load() {
        if (!file.exists()) return
        runCatching {
            DataInputStream(FileInputStream(file)).use { input ->
                require(input.readInt() == MAGIC); require(input.readInt() == VERSION)
                nextOrder=input.readLong(); val count=input.readInt(); require(count in 0..MAX_ENTRIES)
                repeat(count){ val order=input.readLong();val id=input.readUTF();val size=input.readInt();require(UUID.matches(id)&&size in 1..MAX_BODY);entries+=Stored(order,id,ByteArray(size).also(input::readFully)) }
                require(input.read() == -1)
            }
        }.getOrElse { throw SyncOutboxException("corrupt store") }
    }
    private fun persist() {
        file.parentFile?.mkdirs();val temp=File(file.parentFile,"${file.name}.tmp")
        FileOutputStream(temp).use { stream -> DataOutputStream(stream).use { output -> output.writeInt(MAGIC);output.writeInt(VERSION);output.writeLong(nextOrder);output.writeInt(entries.size);for(e in entries){output.writeLong(e.order);output.writeUTF(e.operationId);output.writeInt(e.rawBody.size);output.write(e.rawBody)};output.flush();stream.fd.sync() } }
        if (!temp.renameTo(file)) { temp.delete(); throw SyncOutboxException("atomic replace failed") }
    }
    companion object { private const val MAGIC=0x474f4231;private const val VERSION=1;private const val MAX_BODY=1_048_576;private const val MAX_ENTRIES=10_000;private val UUID=Regex("[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}") }
}
