package com.sapiens.gagaodok.sync

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class SyncConnectionStateTest {
    @Test fun `configuration is disabled by default and enrollment replay is exact`() {
        val root = Files.createTempDirectory("sync-state").toFile()
        try {
            val stateFile = File(root, "state.json")
            val store = SyncConnectionStateStore(stateFile)
            assertEquals(SyncConnectionLoadResult.Absent, store.load())
            val config = SyncConnectionConfiguration(
                "https://sync.example.test",
                "10000000-0000-4000-8000-000000000001",
                "20000000-0000-4000-8000-000000000002",
                false,
                null,
            )
            assertTrue(store.save(config))
            assertEquals(SyncConnectionLoadResult.Available(config), store.load())
            stateFile.writeText("not-json")
            assertEquals(SyncConnectionLoadResult.RelinkRequired, store.load())
            assertThrows(IllegalArgumentException::class.java) { config.copy(baseUrl = "http://sync.example.test") }

            val journal = SyncEnrollmentJournal(File(root, "enrollment.bin"))
            val body = "{\"account_id\":\"SYNTHETIC\"}".toByteArray()
            assertTrue(journal.stage(config.deviceId, body))
            assertArrayEquals(body, journal.pending()!!.rawBody)
            assertFalse(journal.stage(config.deviceId, body))
            assertThrows(SyncConnectionStateException::class.java) {
                journal.stage(config.deviceId, "different".toByteArray())
            }
            assertTrue(journal.acknowledge(config.deviceId))
            assertNull(journal.pending())
        } finally { root.deleteRecursively() }
    }
}
