package com.sapiens.gagaodok.sync

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

enum class SyncRemoteReplyStage { PREPARED, ROOM_READY, TURN_CREATED, USER_BUBBLE_CREATED, AI_BUBBLE_CREATED, COMPLETE }
data class SyncRemoteReplyOperation(val operationId: String, val rawBody: ByteArray) {
    override fun equals(other: Any?) = other is SyncRemoteReplyOperation && operationId == other.operationId && rawBody.contentEquals(other.rawBody)
    override fun hashCode() = 31 * operationId.hashCode() + rawBody.contentHashCode()
}
data class SyncRemoteReplyJournalEntry(
    val replyId: String, val handle: SyncRoomHandle, val writerSpaceId: String, val userText: String,
    var stage: SyncRemoteReplyStage, var operations: MutableList<SyncRemoteReplyOperation>,
    val acknowledged: MutableSet<String> = mutableSetOf(), val observed: MutableSet<String> = mutableSetOf(),
)
class SyncRemoteReplyJournalException(message: String) : Exception(message)

/** Crash-safe reply journal. Raw bytes are written and replayed unchanged. */
class SyncRemoteReplyJournal(private val file: File) {
    private val entries = mutableListOf<SyncRemoteReplyJournalEntry>()
    init { load() }

    @Synchronized fun prepare(replyId: String, handle: SyncRoomHandle, writerSpaceId: String, userText: String, operations: List<SyncRemoteReplyOperation>) {
        requireReply(replyId, writerSpaceId, userText, operations)
        val value = SyncRemoteReplyJournalEntry(replyId, handle, writerSpaceId, userText, SyncRemoteReplyStage.PREPARED, operations.map { SyncRemoteReplyOperation(it.operationId, it.rawBody.copyOf()) }.toMutableList())
        entries.firstOrNull { it.replyId == replyId }?.let { if (it != value) throw SyncRemoteReplyJournalException("reply mismatch"); return }
        entries += value; persist()
    }
    @Synchronized fun entry(replyId: String): SyncRemoteReplyJournalEntry? = entries.firstOrNull { it.replyId == replyId }?.let { entry ->
        entry.copy(operations = entry.operations.map { operation -> SyncRemoteReplyOperation(operation.operationId, operation.rawBody.copyOf()) }.toMutableList(), acknowledged = entry.acknowledged.toMutableSet(), observed = entry.observed.toMutableSet())
    }
    @Synchronized fun advance(replyId: String, stage: SyncRemoteReplyStage) { val entry = required(replyId); if (stage.ordinal < entry.stage.ordinal) throw SyncRemoteReplyJournalException("stage regression"); entry.stage = stage; persist() }
    @Synchronized fun acknowledge(replyId: String, operationId: String) { val entry = required(replyId); if (entry.operations.none { it.operationId == operationId }) throw SyncRemoteReplyJournalException("unknown operation"); entry.acknowledged += operationId; persist() }
    @Synchronized fun observeProjection(replyId: String, operationId: String) { val entry = required(replyId); if (entry.operations.none { it.operationId == operationId }) throw SyncRemoteReplyJournalException("unknown operation"); entry.observed += operationId; if (entry.stage == SyncRemoteReplyStage.COMPLETE && entry.operations.all { it.operationId in entry.observed }) entries.remove(entry); persist() }
    @Synchronized fun rebuildForBubbleOrderConflict(replyId: String, userBubbleAcknowledged: Boolean, replacementUser: SyncRemoteReplyOperation?, replacementAI: SyncRemoteReplyOperation) {
        val entry = required(replyId); if (entry.operations.size < 2) throw SyncRemoteReplyJournalException("invalid rebuild")
        if (userBubbleAcknowledged) { if (replacementUser != null) throw SyncRemoteReplyJournalException("invalid rebuild"); entry.operations[entry.operations.lastIndex] = copy(replacementAI) }
        else { if (replacementUser == null) throw SyncRemoteReplyJournalException("invalid rebuild"); entry.operations.removeAt(entry.operations.lastIndex); entry.operations.removeAt(entry.operations.lastIndex); entry.operations += copy(replacementUser); entry.operations += copy(replacementAI) }
        validateOperations(entry.operations); val ids = entry.operations.map { it.operationId }.toSet(); entry.acknowledged.retainAll(ids); entry.observed.retainAll(ids); persist()
    }

    private fun required(id: String) = entries.firstOrNull { it.replyId == id } ?: throw SyncRemoteReplyJournalException("missing reply")
    private fun copy(o: SyncRemoteReplyOperation) = SyncRemoteReplyOperation(o.operationId, o.rawBody.copyOf())
    private fun requireReply(id: String, space: String, text: String, operations: List<SyncRemoteReplyOperation>) { if (!UUID.matches(id) || space.isEmpty() || text.isEmpty()) throw SyncRemoteReplyJournalException("invalid reply"); validateOperations(operations) }
    private fun validateOperations(operations: List<SyncRemoteReplyOperation>) { if (operations.isEmpty() || operations.any { !UUID.matches(it.operationId) || it.rawBody.isEmpty() || it.rawBody.size > MAX_BODY } || operations.map { it.operationId }.toSet().size != operations.size) throw SyncRemoteReplyJournalException("invalid operation") }
    private fun load() { if (!file.exists()) return; runCatching { DataInputStream(FileInputStream(file)).use { input -> require(input.readInt() == MAGIC && input.readInt() == VERSION); val count = input.readInt(); require(count in 0..MAX_ENTRIES); repeat(count) { val reply = input.readUTF(); val handle = SyncRoomHandle(input.readUTF(), input.readUTF()); val space = input.readUTF(); val text = input.readUTF(); val stage = SyncRemoteReplyStage.entries[input.readInt()]; val operations = MutableList(input.readInt()) { val id = input.readUTF(); SyncRemoteReplyOperation(id, ByteArray(input.readInt()).also(input::readFully)) }; val ack = MutableList(input.readInt()) { input.readUTF() }.toMutableSet(); val observed = MutableList(input.readInt()) { input.readUTF() }.toMutableSet(); requireReply(reply, space, text, operations); entries += SyncRemoteReplyJournalEntry(reply, handle, space, text, stage, operations, ack, observed) }; require(input.read() == -1) } }.getOrElse { throw SyncRemoteReplyJournalException("corrupt store") } }
    private fun persist() { file.parentFile?.mkdirs(); val temp = File(file.parentFile, "${file.name}.tmp"); FileOutputStream(temp).use { stream -> DataOutputStream(stream).use { out -> out.writeInt(MAGIC); out.writeInt(VERSION); out.writeInt(entries.size); entries.forEach { e -> out.writeUTF(e.replyId); out.writeUTF(e.handle.originSpaceId); out.writeUTF(e.handle.roomId); out.writeUTF(e.writerSpaceId); out.writeUTF(e.userText); out.writeInt(e.stage.ordinal); out.writeInt(e.operations.size); e.operations.forEach { o -> out.writeUTF(o.operationId); out.writeInt(o.rawBody.size); out.write(o.rawBody) }; out.writeInt(e.acknowledged.size); e.acknowledged.forEach(out::writeUTF); out.writeInt(e.observed.size); e.observed.forEach(out::writeUTF) }; out.flush(); stream.fd.sync() } }; if (!temp.renameTo(file)) { temp.delete(); throw SyncRemoteReplyJournalException("atomic replace failed") } }
    companion object { private const val MAGIC = 0x47525231; private const val VERSION = 1; private const val MAX_BODY = 1_048_576; private const val MAX_ENTRIES = 10_000; private val UUID = Regex("[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}") }
}
