package com.sapiens.gagaodok.sync

import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.MessageKind
import com.sapiens.gagaodok.model.MessageSender
import java.io.File
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Protocol
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Choosing and copying this device's own room.
 *
 * Rooms and messages are supplied as plain lists, so no real conversation file
 * is opened and nothing is written anywhere but a temporary outbox.
 */
class SyncShadowWriteModelTest {

    @get:Rule val folder = TemporaryFolder()

    private val account = "A0000000-0000-4000-8000-000000000001"
    private val device = "B0000000-0000-4000-8000-000000000002"
    private val masterKey = ByteArray(32) { index -> ((index * 3 + 11) and 0xff).toByte() }
    private val token = ByteArray(32) { index -> ((index * 5 + 29) and 0xff).toByte() }
    private val title = "역방향테스트"

    private class RecordingTransport(private val status: Int = 200) : SyncHttpTransport {
        val sent = mutableListOf<ByteArray>()
        override fun send(request: Request): SyncHttpResponse {
            val sink = okio.Buffer()
            request.body?.writeTo(sink)
            sent.add(sink.readByteArray())
            return SyncHttpResponse(status, """{"result":{"status":"applied"}}""".toByteArray())
        }
    }

    private fun room(name: String, id: UUID = UUID.randomUUID()) = ChatRoom(id = id, title = name)

    private fun message(index: Int, turn: UUID?, withAttachment: Boolean = false, text: String = "폰에서 쓴 줄 $index") =
        ChatMessage(
            id = UUID(0, index.toLong()),
            sender = if (index % 2 == 0) MessageSender.USER else MessageSender.SAPIENS,
            text = text,
            timestamp = 1_800_000_000_000L + index * 1000L,
            turnId = turn,
            kind = MessageKind.SPEECH,
            attachment = if (withAttachment) null else null,
        )

    private fun model(
        rooms: List<ChatRoom>,
        messages: List<ChatMessage>,
        transport: SyncHttpTransport = RecordingTransport(),
        secrets: SyncSecretLoadResult = SyncSecretLoadResult.Available(
            SyncSecretBundle(masterKey, token)
        ),
    ): Pair<SyncShadowWriteModel, SyncOutbox> {
        val outbox = SyncOutbox(File(folder.newFolder(), "outbox.bin"))
        return SyncShadowWriteModel(
            rooms = { rooms },
            messages = { messages },
            roomTitle = title,
            accountId = account,
            deviceId = device,
            spaceId = "PHONE_SPACE",
            client = SyncWorkerClient("https://synthetic.invalid", { token }, transport),
            outbox = outbox,
            loadSecrets = { secrets },
        ) to outbox
    }

    @Test
    fun `names the room before anything is sent`() {
        val turn = UUID(1, 1)
        val target = room(title)
        val transport = RecordingTransport()
        val (model, _) = model(listOf(room("다른 방"), target), List(4) { message(it, turn) }, transport)

        model.inspect()
        val ready = model.state.value as SyncShadowWriteState.Ready
        assertEquals(title, ready.target.title)
        assertEquals(target.id, ready.target.roomId)
        assertEquals(4, ready.target.bubbleCount)
        // Inspecting is a read. Nothing has left the device yet.
        assertTrue("inspect sent something", transport.sent.isEmpty())
    }

    @Test
    fun `refuses to send before the room has been named`() {
        val (model, outbox) = model(listOf(room(title)), listOf(message(0, null)))
        model.run()
        assertTrue(model.state.value is SyncShadowWriteState.Failed)
        assertTrue("something was queued", outbox.pending().isEmpty())
    }

    @Test
    fun `refuses two rooms with the same name rather than guessing`() {
        val (model, outbox) = model(listOf(room(title), room(title)), listOf(message(0, null)))
        model.inspect()
        val failed = model.state.value as SyncShadowWriteState.Failed
        // Picking either one would copy whichever happened to sort first.
        assertTrue(failed.reason.contains("둘 이상"))
        assertTrue(outbox.pending().isEmpty())
    }

    @Test
    fun `reports a room this device does not have`() {
        val (model, _) = model(listOf(room("다른 방")), emptyList())
        model.inspect()
        val failed = model.state.value as SyncShadowWriteState.Failed
        assertTrue(failed.reason.contains(title))
    }

    @Test
    fun `copies the room and sends no plaintext`() {
        val turn = UUID(1, 1)
        val messages = List(4) { message(it, if (it < 2) turn else null) }
        val transport = RecordingTransport()
        val (model, outbox) = model(listOf(room(title)), messages, transport)

        model.inspect()
        model.run()
        val finished = (model.state.value as SyncShadowWriteState.Finished).result

        assertEquals(4, finished.manifest.bubbleCount)
        // Two bubbles share a turn; the other two are each their own.
        assertEquals(3, finished.manifest.turnCount)
        assertEquals(1 + 3 + 4, finished.manifest.operationCount)
        assertEquals(finished.manifest.operationCount, finished.uploadedOperations)
        assertTrue("the outbox was not drained", outbox.pending().isEmpty())

        val raw = transport.sent.joinToString("") { it.toString(Charsets.UTF_8) }
        for (item in messages) {
            assertTrue("bubble text travelled in the clear", !raw.contains(item.text))
        }
        assertTrue("the room title travelled in the clear", !raw.contains(title))
        for (body in transport.sent) {
            val json = Json.parseToJsonElement(body.toString(Charsets.UTF_8)).jsonObject
            assertEquals(
                "PHONE_SPACE",
                json.getValue("target").jsonObject.getValue("space_id").jsonPrimitive.content,
            )
        }
    }

    @Test
    fun `keeps the journal when the server refuses`() {
        val turn = UUID(1, 1)
        val (model, outbox) = model(
            listOf(room(title)), List(2) { message(it, turn) }, RecordingTransport(status = 503),
        )
        model.inspect()
        model.run()

        assertTrue(model.state.value is SyncShadowWriteState.Failed)
        // Nothing was acknowledged, so the pass resumes instead of being
        // rebuilt from a conversation that may have moved on since.
        assertEquals(1 + 1 + 2, outbox.pending().size)
    }
}
