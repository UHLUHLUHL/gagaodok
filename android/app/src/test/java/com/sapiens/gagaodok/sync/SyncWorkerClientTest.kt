package com.sapiens.gagaodok.sync
import java.nio.file.Files
import okhttp3.Request
import org.junit.Assert.*
import org.junit.Test
class SyncWorkerClientTest {
 @Test fun `retries exact outbox bytes and acknowledges only success`() { val dir=Files.createTempDirectory("client").toFile();try{val outbox=SyncOutbox(dir.resolve("outbox"));val id="10000000-0000-4000-8000-000000000001";val raw="{ \"ciphertext\" : \"EXACT\" }".toByteArray();outbox.enqueue(id,raw);val requests=mutableListOf<Request>();val statuses=ArrayDeque(listOf(503,200));val transport=SyncHttpTransport{request->requests+=request;SyncHttpResponse(statuses.removeFirst(),ByteArray(0))};val client=SyncWorkerClient("https://sync.invalid",ByteArray(32){it.toByte()},transport);assertThrows(SyncWorkerClientException::class.java){client.drainOne(outbox)};assertEquals(1,outbox.pending().size);client.drainOne(outbox);assertTrue(outbox.pending().isEmpty());assertEquals(2,requests.size);for(request in requests){assertArrayEquals(raw,request.body!!.let{body->okio.Buffer().also(body::writeTo).readByteArray()});assertTrue(request.header("Authorization")!!.startsWith("Device gdt1_"))}}finally{dir.deleteRecursively()} }
}
