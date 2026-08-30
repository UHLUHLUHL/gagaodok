package com.sapiens.gagaodok.sync

import java.nio.file.Files
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

class SyncAccountTransitionStoreTest {
    @Test fun `secret slots use distinct encrypted blob keys`() {
        assertEquals(3, SyncSecretSlot.entries.map(SyncSecretStore::blobKey).toSet().size)
    }

    @Test fun `journal round trips closed non secret shape and rejects unknown key`() {
        val root = Files.createTempDirectory("sync-transition-store").toFile()
        try {
            val file = root.resolve("transition.json")
            val journal = SyncAccountTransitionJournal(file)
            val record = SyncAccountTransitionRecord(
                stage = SyncTransitionStage.STAGED,
                oldAccountId = "AAAAAAAA-0000-4000-8000-00000000000A",
                newAccountId = "BBBBBBBB-0000-4000-8000-00000000000B",
                createdAtMilliseconds = 1_777_777_777_000,
            )
            journal.save(record)
            assertEquals(record, journal.load())
            val text = file.readText()
            assertFalse(text.contains("token"))
            assertFalse(text.contains("master"))
            file.writeText(
                """{"version":1,"stage":"STAGED","operation":"SWITCH_ACCOUNT","old_account_id":"AAAAAAAA-0000-4000-8000-00000000000A","new_account_id":"BBBBBBBB-0000-4000-8000-00000000000B","created_at_ms":1,"token":"forbidden"}"""
            )
            assertThrows(SyncAccountTransitionStoreException::class.java) { journal.load() }
        } finally { root.deleteRecursively() }
    }

    @Test fun `promote restore and cleanup preserve exact bytes`() {
        val root = Files.createTempDirectory("sync-transition-files").toFile()
        try {
            val files = SyncTransitionFiles(root)
            val old = "old-connection".toByteArray()
            val candidate = "new-connection".toByteArray()
            files.writeActive(old, SyncTransitionFileRole.CONNECTION)
            files.stage(candidate, SyncTransitionFileRole.CONNECTION)
            files.prepareRollback()
            files.promote()
            assertArrayEquals(candidate, files.readActive(SyncTransitionFileRole.CONNECTION))
            files.restore()
            assertArrayEquals(old, files.readActive(SyncTransitionFileRole.CONNECTION))
            files.discardTransient()
            assertFalse(files.hasTransientFiles())
        } finally { root.deleteRecursively() }
    }
}
