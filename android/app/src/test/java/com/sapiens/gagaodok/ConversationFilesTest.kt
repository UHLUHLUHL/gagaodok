package com.sapiens.gagaodok

import com.sapiens.gagaodok.data.ConversationFiles
import com.sapiens.gagaodok.data.ConversationScope
import com.sapiens.gagaodok.data.ScopedWriteCoordinator
import com.sapiens.gagaodok.data.ScopedWriteKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class ConversationFilesTest {
    private fun coordinator() = ScopedWriteCoordinator(
        CoroutineScope(SupervisorJob() + Dispatchers.Default)
    )

    @Test
    fun initializeWritesExactEmptyArray() {
        val root = Files.createTempDirectory("conversation-files").toFile()
        val scope = ConversationScope(UUID.randomUUID(), UUID.randomUUID())

        ConversationFiles(root).initialize(scope)

        assertEquals("[]", ConversationFiles(root).messageFile(scope).readText())
    }

    @Test
    fun branchCopiesBothFilesAndKeepsWorldlinesSeparate() {
        val root = Files.createTempDirectory("conversation-files").toFile()
        val roomId = UUID.randomUUID()
        val active = ConversationScope(roomId, UUID.randomUUID())
        val branch = ConversationScope(roomId, UUID.randomUUID())
        val files = ConversationFiles(root)
        files.messageFile(active).writeText("[\"active\"]")
        files.digestFile(active).writeText("{\"summary\":\"active\"}")

        files.branch(active, branch)
        files.messageFile(branch).writeText("[\"branch\"]")

        assertEquals("[\"active\"]", files.messageFile(active).readText())
        assertEquals("[\"branch\"]", files.messageFile(branch).readText())
        assertEquals("{\"summary\":\"active\"}", files.digestFile(branch).readText())
    }

    @Test
    fun deleteScopeDoesNotTouchPersonalFile() {
        val root = Files.createTempDirectory("conversation-files").toFile()
        val roomId = UUID.randomUUID()
        val personal = ConversationScope(roomId)
        val group = ConversationScope(roomId, UUID.randomUUID())
        val files = ConversationFiles(root)
        files.initialize(personal)
        files.initialize(group)
        files.digestFile(group).writeText("digest")

        files.delete(group)

        assertTrue(files.messageFile(personal).exists())
        assertFalse(files.messageFile(group).exists())
        assertFalse(files.digestFile(group).exists())
    }

    @Test
    fun flushBeforeBranchIncludesQueuedMessagesAndDigest() {
        val root = Files.createTempDirectory("conversation-files").toFile()
        val roomId = UUID.randomUUID()
        val active = ConversationScope(roomId, UUID.randomUUID())
        val branch = ConversationScope(roomId, UUID.randomUUID())
        val files = ConversationFiles(root)
        val writes = coordinator()

        writes.schedule(active, ScopedWriteKind.MESSAGE, 60_000) {
            files.messageFile(active).writeText("[\"split point\"]")
        }
        writes.schedule(active, ScopedWriteKind.DIGEST, 60_000) {
            files.digestFile(active).writeText("{\"summary\":\"split point\"}")
        }

        writes.flushAndRun(active) { files.branch(active, branch) }

        assertEquals("[\"split point\"]", files.messageFile(branch).readText())
        assertEquals("{\"summary\":\"split point\"}", files.digestFile(branch).readText())
    }

    @Test
    fun suspendingFreshReadFlushesNewestPendingSnapshotFirst() = runBlocking {
        val root = Files.createTempDirectory("conversation-files").toFile()
        val scope = ConversationScope(UUID.randomUUID(), UUID.randomUUID())
        val files = ConversationFiles(root)
        val writes = coordinator()
        files.messageFile(scope).writeText("[\"old\"]")
        writes.schedule(scope, ScopedWriteKind.MESSAGE, 60_000) {
            files.messageFile(scope).writeText("[\"new\"]")
        }

        val loaded = writes.flushAndRunSuspending(scope) { files.messageFile(scope).readText() }

        assertEquals("[\"new\"]", loaded)
    }

    @Test
    fun cancelBeforeDeletePreventsQueuedWritesFromRecreatingFiles() {
        val root = Files.createTempDirectory("conversation-files").toFile()
        val scope = ConversationScope(UUID.randomUUID(), UUID.randomUUID())
        val files = ConversationFiles(root)
        val writes = coordinator()
        files.initialize(scope)
        files.digestFile(scope).writeText("old")

        writes.schedule(scope, ScopedWriteKind.MESSAGE, 60_000) {
            files.messageFile(scope).writeText("[\"late\"]")
        }
        writes.schedule(scope, ScopedWriteKind.DIGEST, 60_000) {
            files.digestFile(scope).writeText("late")
        }
        writes.closeAndRun(listOf(scope)) { files.delete(scope) }

        assertFalse(files.messageFile(scope).exists())
        assertFalse(files.digestFile(scope).exists())
    }

    @Test
    fun completedOlderWriteCannotRemoveNewerPendingWrite() {
        val root = Files.createTempDirectory("conversation-files").toFile()
        val scope = ConversationScope(UUID.randomUUID(), UUID.randomUUID())
        val files = ConversationFiles(root)
        val writes = coordinator()
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)

        writes.schedule(scope, ScopedWriteKind.MESSAGE) {
            started.countDown()
            release.await()
            files.messageFile(scope).writeText("[\"old\"]")
        }
        assertTrue(started.await(1, TimeUnit.SECONDS))
        writes.schedule(scope, ScopedWriteKind.MESSAGE, 60_000) {
            files.messageFile(scope).writeText("[\"new\"]")
        }
        release.countDown()
        writes.flushAndRun(scope) {}

        assertEquals("[\"new\"]", files.messageFile(scope).readText())
    }

    @Test
    fun writesScheduledDuringDeletionAreRejectedAndCannotRecreateFiles() {
        val root = Files.createTempDirectory("conversation-files").toFile()
        val scope = ConversationScope(UUID.randomUUID(), UUID.randomUUID())
        val files = ConversationFiles(root)
        val writes = coordinator()
        val deletionStarted = CountDownLatch(1)
        val allowDeletion = CountDownLatch(1)
        files.initialize(scope)

        val deleting = Thread {
            writes.closeAndRun(listOf(scope)) {
                deletionStarted.countDown()
                allowDeletion.await()
                files.delete(scope)
            }
        }
        deleting.start()
        assertTrue(deletionStarted.await(1, TimeUnit.SECONDS))

        val accepted = writes.schedule(scope, ScopedWriteKind.MESSAGE) {
            files.messageFile(scope).writeText("[\"recreated\"]")
        }
        allowDeletion.countDown()
        deleting.join(1_000)

        assertFalse(accepted)
        assertFalse(files.messageFile(scope).exists())
    }
}
