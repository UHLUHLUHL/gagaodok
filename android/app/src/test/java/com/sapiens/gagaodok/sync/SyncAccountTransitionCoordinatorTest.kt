package com.sapiens.gagaodok.sync

import java.nio.file.Files
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

private class SlotVault : SyncSlottedSecretVault {
    val values = mutableMapOf<SyncSecretSlot, SyncSecretBundle>()
    override fun load(slot: SyncSecretSlot): SyncSecretLoadResult =
        values[slot]?.let(SyncSecretLoadResult::Available) ?: SyncSecretLoadResult.Absent
    override fun save(secrets: SyncSecretBundle, slot: SyncSecretSlot): Boolean { values[slot] = secrets; return true }
    override fun remove(slot: SyncSecretSlot): Boolean { values.remove(slot); return true }
}

private class BoundaryFailure : Exception()

private class AndroidTransitionHarness(enabled: Boolean = false, pending: Boolean = false) {
    val root = Files.createTempDirectory("android-sync-transition").toFile()
    private val sync = root.resolve("sync")
    val vault = SlotVault()
    val files = SyncTransitionFiles(sync)
    val journal = SyncAccountTransitionJournal(sync.resolve("transition.json"))
    val connection = SyncConnectionStateStore(sync.resolve("connection.json"))
    val outbox = SyncOutbox(sync.resolve("outbox.bin"))
    val conversation = root.resolve("conversation-sentinel.bin")
    val oldSecrets = SyncSecretBundle(ByteArray(32) { 1 }, ByteArray(32) { 2 })
    val newSecrets = SyncSecretBundle(ByteArray(32) { 3 }, ByteArray(32) { 4 })
    val oldConnection = SyncConnectionConfiguration(
        "https://sync.invalid", "AAAAAAAA-0000-4000-8000-00000000000A",
        "AAAAAAAA-0000-4000-8000-00000000000D", enabled, "old-cursor",
    )
    val newConnection = SyncConnectionConfiguration(
        "https://sync.invalid", "BBBBBBBB-0000-4000-8000-00000000000B",
        "BBBBBBBB-0000-4000-8000-00000000000D", false, null,
    )
    val candidate get() = SyncTransitionCandidate(
        newConnection, newSecrets, "new-replica".toByteArray(), "new-cursor".toByteArray(),
    )

    init {
        check(connection.save(oldConnection))
        files.writeActive("old-replica".toByteArray(), SyncTransitionFileRole.REPLICA)
        files.writeActive("old-cursor".toByteArray(), SyncTransitionFileRole.CURSOR)
        conversation.writeText("LOCAL-CONVERSATION-UNCHANGED")
        vault.save(oldSecrets, SyncSecretSlot.ACTIVE)
        if (pending) outbox.enqueue("CCCCCCCC-0000-4000-8000-00000000000C", "{\"opaque\":true}".toByteArray())
    }

    fun coordinator(failAt: SyncCommitBoundary? = null) = SyncAccountTransitionCoordinator(
        vault, connection, files, journal, outbox,
        nowMilliseconds = { 1_777_777_777_000 },
        afterBoundary = { if (it == failAt) throw BoundaryFailure() },
    )
}

class SyncAccountTransitionCoordinatorTest {
    @Test fun `enabled sync and pending outbox block transition`() {
        listOf(
            AndroidTransitionHarness(enabled = true) to SyncAccountTransitionError.SYNC_ENABLED,
            AndroidTransitionHarness(pending = true) to SyncAccountTransitionError.OUTBOX_PENDING,
        ).forEach { (h, expected) ->
            try { h.coordinator().prepare(h.candidate); fail("expected $expected") }
            catch (e: SyncAccountTransitionException) { assertEquals(expected, e.reason) }
            finally { h.root.deleteRecursively() }
        }
    }

    @Test fun `every commit boundary recovers exactly one complete disabled account`() {
        SyncCommitBoundary.entries.forEach { boundary ->
            val h = AndroidTransitionHarness()
            try {
                val before = h.conversation.readBytes()
                val coordinator = h.coordinator(boundary)
                coordinator.prepare(h.candidate)
                coordinator.markBootstrapVerified()
                try { coordinator.commit(); fail("expected $boundary failure") } catch (_: BoundaryFailure) {}
                coordinator.recoverIfNeeded()
                val loaded = h.connection.load()
                val active = h.vault.load(SyncSecretSlot.ACTIVE)
                val oldComplete = loaded == SyncConnectionLoadResult.Available(h.oldConnection) && active == SyncSecretLoadResult.Available(h.oldSecrets)
                val newComplete = loaded == SyncConnectionLoadResult.Available(h.newConnection) && active == SyncSecretLoadResult.Available(h.newSecrets)
                assertTrue("$boundary must choose exactly one account", oldComplete.xor(newComplete))
                assertFalse(h.files.hasTransientFiles())
                assertEquals(SyncSecretLoadResult.Absent, h.vault.load(SyncSecretSlot.STAGING))
                assertEquals(SyncSecretLoadResult.Absent, h.vault.load(SyncSecretSlot.ROLLBACK))
                assertArrayEquals(before, h.conversation.readBytes())
            } finally { h.root.deleteRecursively() }
        }
    }

    @Test fun `successful commit activates candidate disabled and unlink preserves conversation`() {
        val h = AndroidTransitionHarness()
        try {
            val coordinator = h.coordinator()
            coordinator.prepare(h.candidate)
            coordinator.markBootstrapVerified()
            coordinator.commit()
            assertEquals(SyncConnectionLoadResult.Available(h.newConnection), h.connection.load())
            assertEquals(SyncSecretLoadResult.Available(h.newSecrets), h.vault.load(SyncSecretSlot.ACTIVE))
            assertEquals(SyncAccountTransitionState.COMPLETED, coordinator.state)

            val before = h.conversation.readBytes()
            coordinator.unlink()
            assertEquals(SyncConnectionLoadResult.Absent, h.connection.load())
            assertEquals(SyncSecretLoadResult.Absent, h.vault.load(SyncSecretSlot.ACTIVE))
            assertArrayEquals(before, h.conversation.readBytes())
        } finally { h.root.deleteRecursively() }
    }
}
