package com.sapiens.gagaodok.sync

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

/**
 * Pull coordinator tests.
 *
 * The transport is a double and the only things written are the opaque replica
 * and the coordinator's own progress file. No conversation storage is opened
 * and no projection is decrypted.
 */
class SyncPullCoordinatorTest {
    private class Harness(val dir: File, responses: List<Pair<Int, String>>) {
        val paths = mutableListOf<String>()
        private val queue = ArrayDeque(responses)
        val replica = SyncReplicaStore(dir.resolve("replica.json"))
        val client = SyncWorkerClient(
            "https://synthetic.invalid",
            ByteArray(32) { it.toByte() },
            SyncHttpTransport { request ->
                paths += request.url.encodedPath + "?" + (request.url.encodedQuery ?: "")
                val (status, body) = queue.removeFirst()
                if (status !in 200..299) throw SyncWorkerClientException(status)
                SyncHttpResponse(status, body.toByteArray())
            },
        )
        val coordinator = SyncPullCoordinator(client, replica, dir.resolve("pull.json"))
    }

    private fun harness(responses: List<Pair<Int, String>>, work: (Harness) -> Unit) {
        val dir = Files.createTempDirectory("pull").toFile()
        try { work(Harness(dir, responses)) } finally { dir.deleteRecursively() }
    }

    private fun bootstrapBody(watermark: Int, hasMore: Boolean, cursor: String?, room: String) =
        """{"protocol_version":1,"request_id":"AAAAAAAA-0000-4000-8000-00000000000A","result":{
        "snapshot_high_watermark_seq":$watermark,"has_more":$hasMore,
        "next_cursor":${cursor?.let { "\"$it\"" } ?: "null"},
        "items":[{"entity_type":"room","identity":{"space_id":"MAC_SPACE","room_id":"$room"},
        "projection":{"space_id":"MAC_SPACE","room_id":"$room","title":"AQE=","revision":0}}]}}"""

    private fun changesBody(scanned: Int, hasMore: Boolean, revision: Int) =
        """{"protocol_version":1,"request_id":"AAAAAAAA-0000-4000-8000-00000000000B","result":{
        "scanned_through_seq":$scanned,"account_high_watermark_seq":$scanned,"has_more":$hasMore,
        "changes":[{"change_seq":$scanned,"entity_type":"room","change_kind":"upsert","revision":$revision,
        "identity":{"space_id":"MAC_SPACE","room_id":"$ROOM_A"},
        "projection":{"space_id":"MAC_SPACE","room_id":"$ROOM_A","title":"AQE=","revision":$revision}}]}}"""

    @Test fun `bootstrap pages then hands over at the watermark`() = harness(
        listOf(200 to bootstrapBody(12, true, "CURSOR-1", ROOM_A), 200 to bootstrapBody(12, false, null, ROOM_B)),
    ) { h ->
        val first = h.coordinator.advanceBootstrap()
        assertTrue(first.hasMore)
        assertEquals("CURSOR-1", first.bootstrapCursor)
        assertFalse(first.bootstrapComplete)
        assertNull(first.changesCursor)

        val second = h.coordinator.advanceBootstrap()
        assertTrue(second.bootstrapComplete)
        assertNull(second.bootstrapCursor)
        // The handover: the account cursor begins exactly at the snapshot ceiling.
        assertEquals(12L, second.changesCursor)

        assertEquals(2, h.paths.size)
        assertTrue(h.paths[1].contains("cursor=CURSOR-1"))
        assertEquals(2, h.replica.snapshot().size)
    }

    /** A cursor without a snapshot would hold only what changed recently. */
    @Test fun `changes is refused before bootstrap finishes`() = harness(emptyList()) { h ->
        val error = assertThrows(SyncPullException::class.java) { h.coordinator.advanceChanges() }
        assertEquals(SyncPullException.Reason.BOOTSTRAP_INCOMPLETE, error.reason)
        assertTrue(h.paths.isEmpty())
    }

    @Test fun `re-applying a changes page changes nothing`() = harness(
        listOf(
            200 to bootstrapBody(5, false, null, ROOM_A),
            200 to changesBody(7, false, 3),
            200 to changesBody(7, false, 3),
        ),
    ) { h ->
        h.coordinator.advanceBootstrap()
        assertEquals(7L, h.coordinator.advanceChanges().changesCursor)
        val after = h.replica.snapshot()
        h.coordinator.advanceChanges()
        assertEquals(after, h.replica.snapshot())
    }

    @Test fun `a refused page writes nothing and does not advance the cursor`() = harness(
        listOf(
            200 to bootstrapBody(5, false, null, ROOM_A),
            // An entity type this build does not know.
            200 to """{"protocol_version":1,"request_id":"AAAAAAAA-0000-4000-8000-00000000000C","result":{
            "scanned_through_seq":9,"account_high_watermark_seq":9,"has_more":false,
            "changes":[{"change_seq":9,"entity_type":"unknown_entity","change_kind":"upsert","revision":0,
            "identity":{"space_id":"MAC_SPACE"},"projection":{"space_id":"MAC_SPACE"}}]}}""",
            200 to changesBody(9, false, 1),
        ),
    ) { h ->
        h.coordinator.advanceBootstrap()
        val before = h.replica.snapshot()
        // Whole-page rejection: applying the half a build understands would
        // leave a replica no one can reason about.
        assertThrows(SyncReplicaStoreException::class.java) { h.coordinator.advanceChanges() }
        assertEquals(before, h.replica.snapshot())
        assertEquals(5L, h.coordinator.progress().changesCursor)

        assertEquals(9L, h.coordinator.advanceChanges().changesCursor)
        // The retry refetched the same position rather than skipping it.
        assertEquals(h.paths[1], h.paths[2])
    }

    @Test fun `malformed envelopes are refused whole`() {
        val bodies = listOf(
            // A protocol version this build does not implement.
            """{"protocol_version":2,"request_id":"A","result":{"snapshot_high_watermark_seq":1,"has_more":false,"next_cursor":null,"items":[]}}""",
            // An unexpected top-level key.
            """{"protocol_version":1,"request_id":"A","result":{"snapshot_high_watermark_seq":1,"has_more":false,"next_cursor":null,"items":[]},"extra":1}""",
            // An unexpected result key.
            """{"protocol_version":1,"request_id":"A","result":{"snapshot_high_watermark_seq":1,"has_more":false,"next_cursor":null,"items":[],"extra":1}}""",
            // has_more with no cursor to continue from.
            """{"protocol_version":1,"request_id":"A","result":{"snapshot_high_watermark_seq":1,"has_more":true,"next_cursor":null,"items":[]}}""",
            // A finished page that still hands back a cursor.
            """{"protocol_version":1,"request_id":"A","result":{"snapshot_high_watermark_seq":1,"has_more":false,"next_cursor":"C","items":[]}}""",
        )
        bodies.forEach { body ->
            harness(listOf(200 to body)) { h ->
                val error = assertThrows(SyncPullException::class.java) { h.coordinator.advanceBootstrap() }
                assertEquals(SyncPullException.Reason.MALFORMED_ENVELOPE, error.reason)
                assertFalse(h.coordinator.progress().bootstrapComplete)
                assertNull(h.coordinator.progress().snapshotWatermark)
            }
        }
    }

    /** The server carries the watermark in the cursor so it cannot move. */
    @Test fun `a snapshot that moved between pages is refused`() = harness(
        listOf(200 to bootstrapBody(12, true, "CURSOR-1", ROOM_A), 200 to bootstrapBody(99, false, null, ROOM_B)),
    ) { h ->
        h.coordinator.advanceBootstrap()
        val error = assertThrows(SyncPullException::class.java) { h.coordinator.advanceBootstrap() }
        assertEquals(SyncPullException.Reason.MALFORMED_ENVELOPE, error.reason)
        assertFalse(h.coordinator.progress().bootstrapComplete)
        assertEquals(12L, h.coordinator.progress().snapshotWatermark)
    }

    @Test fun `an http failure leaves progress alone`() = harness(listOf(503 to "{}")) { h ->
        val error = assertThrows(SyncPullException::class.java) { h.coordinator.advanceBootstrap() }
        assertEquals(SyncPullException.Reason.HTTP_STATUS, error.reason)
        assertEquals(503, error.statusCode)
        assertNull(h.coordinator.progress().snapshotWatermark)
        assertTrue(h.replica.snapshot().isEmpty())
    }

    private companion object {
        const val ROOM_A = "10000000-0000-4000-8000-0000000000A1"
        const val ROOM_B = "10000000-0000-4000-8000-0000000000A2"
    }
}
