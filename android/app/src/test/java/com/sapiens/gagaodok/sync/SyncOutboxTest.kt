package com.sapiens.gagaodok.sync
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test
class SyncOutboxTest {
 @Test fun `preserves exact bytes order and acknowledgement across restart`() { val dir=Files.createTempDirectory("outbox").toFile();try{val file=dir.resolve("outbox.bin");val a="10000000-0000-4000-8000-000000000001";val b="10000000-0000-4000-8000-000000000002";val one="{\"ciphertext\":\"ONE\"}".toByteArray();val two="{\"ciphertext\":\"TWO\"}".toByteArray();val box=SyncOutbox(file);assertTrue(box.enqueue(a,one));assertTrue(box.enqueue(b,two));assertFalse(box.enqueue(a,one));assertThrows(SyncOutboxException::class.java){box.enqueue(a,two)};val reopened=SyncOutbox(file);assertEquals(listOf(a,b),reopened.pending().map{it.operationId});assertArrayEquals(one,reopened.pending()[0].rawBody);assertTrue(reopened.acknowledge(a));assertEquals(listOf(b),SyncOutbox(file).pending().map{it.operationId})}finally{dir.deleteRecursively()} }
}
