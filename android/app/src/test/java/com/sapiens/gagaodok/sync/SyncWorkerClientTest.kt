package com.sapiens.gagaodok.sync
import java.nio.file.Files
import okhttp3.Request
import org.junit.Assert.*
import org.junit.Test
class SyncWorkerClientTest {
 @Test fun `retries exact outbox bytes and acknowledges only success`() { val dir=Files.createTempDirectory("client").toFile();try{val outbox=SyncOutbox(dir.resolve("outbox"));val id="10000000-0000-4000-8000-000000000001";val raw="{ \"ciphertext\" : \"EXACT\" }".toByteArray();outbox.enqueue(id,raw);val requests=mutableListOf<Request>();val statuses=ArrayDeque(listOf(503,200));val transport=SyncHttpTransport{request->requests+=request;SyncHttpResponse(statuses.removeFirst(),ByteArray(0))};val client=SyncWorkerClient("https://sync.invalid",ByteArray(32){it.toByte()},transport);assertThrows(SyncWorkerClientException::class.java){client.drainOne(outbox)};assertEquals(1,outbox.pending().size);client.drainOne(outbox);assertTrue(outbox.pending().isEmpty());assertEquals(2,requests.size);for(request in requests){assertArrayEquals(raw,request.body!!.let{body->okio.Buffer().also(body::writeTo).readByteArray()});assertTrue(request.header("Authorization")!!.startsWith("Device gdt1_"))}}finally{dir.deleteRecursively()} }
    /**
     * A client built before enrollment must still authenticate afterwards.
     *
     * The settings screen builds its client once, while nothing is stored yet.
     * A token captured at construction never changes, so on a real install
     * every read stayed refused until the app was restarted. macOS showed this
     * on device; this is the same contract for Android.
     */
    @Test fun `a client built without a token uses the one stored later`() {
        val dir = Files.createTempDirectory("client-late").toFile()
        try {
            val outbox = SyncOutbox(dir.resolve("outbox"))
            val raw = "{ \"ciphertext\" : \"EXACT\" }".toByteArray()
            outbox.enqueue("10000000-0000-4000-8000-000000000002", raw)

            var stored: ByteArray? = null
            val requests = mutableListOf<Request>()
            val transport = SyncHttpTransport { request ->
                requests += request
                SyncHttpResponse(200, ByteArray(0))
            }
            val client = SyncWorkerClient("https://sync.invalid", { stored }, transport)

            // Nothing stored yet: refused here, and never sent unauthenticated.
            assertThrows(SyncWorkerClientException::class.java) { client.drainOne(outbox) }
            assertTrue("no request may leave without a token", requests.isEmpty())
            assertEquals(1, outbox.pending().size)

            stored = ByteArray(32) { it.toByte() }
            client.drainOne(outbox)
            assertEquals(1, requests.size)
            // Only the scheme prefix is asserted; the token itself is never
            // compared, printed or carried into a failure message.
            assertTrue(requests[0].header("Authorization")!!.startsWith("Device gdt1_"))
            assertTrue(outbox.pending().isEmpty())
        } finally {
            dir.deleteRecursively()
        }
    }

    /** A wrong-sized token is refused locally, before any request is built. */
    @Test fun `a token of the wrong size never reaches the network`() {
        val dir = Files.createTempDirectory("client-short").toFile()
        try {
            val outbox = SyncOutbox(dir.resolve("outbox"))
            outbox.enqueue("10000000-0000-4000-8000-000000000003", "{}".toByteArray())
            val requests = mutableListOf<Request>()
            val client = SyncWorkerClient(
                "https://sync.invalid",
                { ByteArray(31) },
                SyncHttpTransport { request -> requests += request; SyncHttpResponse(200, ByteArray(0)) },
            )
            assertThrows(SyncWorkerClientException::class.java) { client.drainOne(outbox) }
            assertTrue(requests.isEmpty())
            assertEquals(1, outbox.pending().size)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun `device inventory uses the authenticated account path`() {
        val requests = mutableListOf<Request>()
        val client = SyncWorkerClient(
            "https://sync.invalid",
            ByteArray(32) { it.toByte() },
            SyncHttpTransport { request -> requests += request; SyncHttpResponse(200, "{}".toByteArray()) },
        )

        client.devices()

        assertEquals(1, requests.size)
        assertEquals("/v1/account/devices", requests.single().url.encodedPath)
        assertNull(requests.single().url.query)
        assertTrue(requests.single().header("Authorization")!!.startsWith("Device gdt1_"))
    }
}
