package com.sapiens.gagaodok.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.util.UUID

class ConversationFiles(private val root: File) {
    fun messageFile(scope: ConversationScope): File = File(root, scope.messageFileName)

    fun digestFile(scope: ConversationScope): File = File(root, scope.digestFileName)

    fun initialize(scope: ConversationScope) {
        root.mkdirs()
        messageFile(scope).writeText("[]")
    }

    fun branch(source: ConversationScope, destination: ConversationScope) {
        require(source.roomId == destination.roomId) { "Worldlines must belong to the same room" }
        copy(messageFile(source), messageFile(destination))
        copy(digestFile(source), digestFile(destination))
    }

    fun delete(scope: ConversationScope) {
        messageFile(scope).delete()
        digestFile(scope).delete()
    }

    fun deleteWorldlines(roomId: UUID) {
        val prefix = "room_${roomId.toString().uppercase()}_worldline_"
        root.listFiles()?.forEach { file ->
            if (file.name.startsWith(prefix) &&
                (file.name.endsWith("_messages.json") || file.name.endsWith("_digest.json"))
            ) file.delete()
        }
    }

    private fun copy(source: File, destination: File) {
        destination.parentFile?.mkdirs()
        if (source.exists()) source.copyTo(destination, overwrite = true) else destination.delete()
    }
}

enum class ScopedWriteKind { MESSAGE, DIGEST }

/** Coordinates deferred writes so branching and deletion have a stable file boundary. */
class ScopedWriteCoordinator(private val coroutineScope: CoroutineScope) {
    private data class Key(val scope: ConversationScope, val kind: ScopedWriteKind)
    private data class Pending(val token: Any, val job: Job, val write: () -> Unit)

    private val pendingLock = Any()
    private val pending = mutableMapOf<Key, Pending>()
    private val closedScopes = mutableSetOf<ConversationScope>()
    private val lifecycleLock = Mutex()
    private val writeLock = Mutex()

    fun schedule(
        scope: ConversationScope,
        kind: ScopedWriteKind,
        delayMillis: Long = 0L,
        write: () -> Unit
    ): Boolean {
        val key = Key(scope, kind)
        val token = Any()
        lateinit var job: Job
        synchronized(pendingLock) {
            if (scope in closedScopes) return false
            pending[key]?.job?.cancel()
            job = coroutineScope.launch(start = CoroutineStart.LAZY) {
                delay(delayMillis)
                lifecycleLock.withLock {
                    writeLock.withLock { write() }
                    removeIfCurrent(key, token)
                }
            }
            pending[key] = Pending(token, job, write)
            job.start()
        }
        return true
    }

    fun flushAndRun(scope: ConversationScope, action: () -> Unit) = runBlocking {
        flushAndRunSuspending(scope, action)
    }

    suspend fun <T> flushAndRunSuspending(scope: ConversationScope, action: () -> T): T =
        flushAndRunSuspending(listOf(scope), flushPending = true, action)

    fun closeAndRun(scopes: List<ConversationScope>, action: () -> Unit) = runBlocking {
        val detached = closeAndDetach(scopes)
        lifecycleLock.withLock {
            detached.forEach { it.job.cancelAndJoin() }
            writeLock.withLock { action() }
        }
    }

    fun flushAll() {
        val scopes = synchronized(pendingLock) { pending.keys.map { it.scope }.distinct() }
        runBlocking { flushAndRunSuspending(scopes, flushPending = true) {} }
    }

    private suspend fun <T> flushAndRunSuspending(
        scopes: List<ConversationScope>,
        flushPending: Boolean,
        action: () -> T
    ): T {
        return lifecycleLock.withLock {
            val detached = detach(scopes)
            detached.forEach { it.job.cancelAndJoin() }
            writeLock.withLock {
                if (flushPending) detached.forEach { it.write() }
                action()
            }
        }
    }

    private fun detach(scopes: List<ConversationScope>): List<Pending> = synchronized(pendingLock) {
        pending.keys.filter { it.scope in scopes }.mapNotNull { pending.remove(it) }
    }

    private fun closeAndDetach(scopes: List<ConversationScope>): List<Pending> = synchronized(pendingLock) {
        closedScopes += scopes
        pending.keys.filter { it.scope in scopes }.mapNotNull { pending.remove(it) }
    }

    private fun removeIfCurrent(key: Key, token: Any) {
        synchronized(pendingLock) {
            if (pending[key]?.token === token) pending.remove(key)
        }
    }
}
