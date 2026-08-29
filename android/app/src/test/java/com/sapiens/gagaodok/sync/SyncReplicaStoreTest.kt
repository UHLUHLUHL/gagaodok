package com.sapiens.gagaodok.sync

import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class SyncReplicaStoreTest {
    @Test fun `applies opaque projection only to shadow store`() {
        val root=Files.createTempDirectory("replica").toFile()
        try {
            val source=root.resolve("real-chat.json");source.writeText("DO-NOT-TOUCH")
            val store=SyncReplicaStore(root.resolve("shadow.json"))
            store.apply("""[{"entity_type":"room","identity":{"space_id":"MAC_SPACE","room_id":"10000000-0000-4000-8000-000000000001"},"projection":{"title":"opaque","extensions":[{"key":"x.y.z","value":"unknown"}]}}]""".toByteArray())
            assertEquals(1,store.snapshot().size);assertTrue(store.snapshot()[0].projectionJson.contains("unknown"))
            store.apply("""[{"entity_type":"room","identity":{"room_id":"10000000-0000-4000-8000-000000000001","space_id":"MAC_SPACE"},"projection":{"title":"new"}}]""".toByteArray())
            assertEquals(1,store.snapshot().size);assertTrue(store.snapshot()[0].projectionJson.contains("new"));assertEquals("DO-NOT-TOUCH",source.readText())
            assertThrows(SyncReplicaStoreException::class.java){store.apply("""[{"entity_type":"unknown","identity":{},"projection":{}}]""".toByteArray())}
            assertEquals(1,store.snapshot().size)
        } finally { root.deleteRecursively() }
    }
}
