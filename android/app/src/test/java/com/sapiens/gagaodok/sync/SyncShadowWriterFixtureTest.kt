package com.sapiens.gagaodok.sync

import java.io.File
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Writer behaviour, and the fixture the Worker suite checks against.
 *
 * Emitting the fixture from the writer itself — rather than hand-writing the
 * JSON — is the point. The previous cross-language fixture was assembled by
 * hand and encoded an assumption about the wire that was simply wrong, so both
 * sides agreed with each other and disagreed with reality. What this file
 * writes is exactly what the device would send.
 *
 * Everything here is synthetic: a made-up account, a made-up room, invented
 * lines.
 */
class SyncShadowWriterFixtureTest {

    @get:Rule val folder = TemporaryFolder()

    private val account = "A0000000-0000-4000-8000-000000000001"
    private val device = "B0000000-0000-4000-8000-000000000002"
    private val room = "C0000000-0000-4000-8000-00000000000B"
    private val turn = "D0000000-0000-4000-8000-00000000000B"
    private val masterKey = ByteArray(32) { index -> ((index * 3 + 11) and 0xff).toByte() }

    private fun counter(): () -> String {
        var value = 0
        return { value += 1; String.format("F1000000-0000-4000-8000-%012X", value) }
    }

    private fun writer(
        originSpaceId: String = "PHONE_SPACE",
        writerSpaceId: String = "PHONE_SPACE",
    ) = SyncShadowWriter(
        accountId = account,
        deviceId = device,
        originSpaceId = originSpaceId,
        writerSpaceId = writerSpaceId,
        masterKey = masterKey,
        randomBytes = { count -> ByteArray(count) { index -> ((index * 7 + count) and 0xff).toByte() } },
        newOperationId = counter(),
        now = { "2026-08-31T00:00:00Z" },
    )

    private val bubbles = listOf(
        SyncShadowOutgoingBubble(
            messageId = "E1000000-0000-4000-8000-000000000001",
            turnId = turn, sender = "user", kind = "speech",
            text = "폰에서 쓴 첫 줄", timestampRfc3339 = "2026-08-31T00:00:00Z",
        ),
        SyncShadowOutgoingBubble(
            messageId = "E1000000-0000-4000-8000-000000000002",
            turnId = turn, sender = "sapiens", kind = "speech",
            text = "폰에서 쓴 두 번째 줄", timestampRfc3339 = "2026-08-31T00:00:01Z",
        ),
    )

    private fun run(): Pair<SyncShadowWriteManifest, JsonArray> {
        val outbox = SyncOutbox(File(folder.newFolder(), "outbox.bin"))
        val manifest = writer().write(room, "폰 시험방", bubbles, outbox)
        val queued = buildJsonArray {
            outbox.pending().forEach { add(Json.parseToJsonElement(it.rawBody.toString(Charsets.UTF_8))) }
        }
        return manifest to queued
    }

    @Test
    fun `writes room, turn and bubbles in this device's own space`() {
        val (manifest, queued) = run()
        assertEquals(
            listOf("create_room", "create_turn", "create_bubble", "create_bubble"),
            queued.map { it.jsonObject.getValue("op").jsonPrimitive.content },
        )
        assertEquals(1, manifest.turnCount)
        assertEquals(2, manifest.bubbleCount)
        assertEquals(queued.size, manifest.operationCount)
        for (element in queued) {
            val target = element.jsonObject.getValue("target").jsonObject
            // A device may only write its own space; anything else is refused
            // by the Worker, so sending it would be a bug, not a negotiation.
            assertEquals("PHONE_SPACE", target.getValue("space_id").jsonPrimitive.content)
        }
    }

    @Test
    fun `carries a MAC origin while writing a phone continuation shard`() {
        val outbox = SyncOutbox(File(folder.newFolder(), "outbox.bin"))
        writer(originSpaceId = "MAC_SPACE", writerSpaceId = "PHONE_SPACE")
            .write(room, "이어쓰기", emptyList(), outbox)
        val operation = Json.parseToJsonElement(
            outbox.pending().single().rawBody.toString(Charsets.UTF_8),
        ).jsonObject
        assertEquals(
            "PHONE_SPACE",
            operation.getValue("target").jsonObject.getValue("space_id").jsonPrimitive.content,
        )
        assertEquals(
            "MAC_SPACE",
            operation.getValue("metadata_set").jsonObject
                .getValue("origin_space_id").jsonPrimitive.content,
        )
    }

    @Test
    fun `seals every meaningful field and leaves only indexed metadata plain`() {
        val (_, queued) = run()
        val raw = queued.toString()
        for (bubble in bubbles) {
            assertTrue("bubble text travelled in the clear", !raw.contains(bubble.text))
        }
        assertTrue("the room title travelled in the clear", !raw.contains("폰 시험방"))
        assertTrue(
            "the master key travelled",
            !raw.contains(Base64.getEncoder().encodeToString(masterKey)),
        )
        for (element in queued) {
            val item = element.jsonObject
            if (item.getValue("op").jsonPrimitive.content != "create_bubble") continue
            assertEquals(setOf("timestamp"), item.getValue("metadata_set").jsonObject.keys)
            assertEquals(setOf("sender", "kind", "text"), item.getValue("set").jsonObject.keys)
        }
    }

    @Test
    fun `seals a worldline room so the reader's derivation actually opens it`() {
        val worldline = "A1000000-0000-4000-8000-00000000000B"
        val outbox = SyncOutbox(File(folder.newFolder(), "outbox.bin"))
        val manifest = writer().write(room, "폰 단톡방", bubbles, outbox, worldlineId = worldline)
        assertEquals(worldline, manifest.worldlineId)

        val queued = outbox.pending().map {
            Json.parseToJsonElement(it.rawBody.toString(Charsets.UTF_8)).jsonObject
        }

        // A room row has no worldline component in its identity, so every
        // reader derives its key with null. Sealing the title under the
        // worldline scope would make a title nobody could ever open.
        val roomRow = queued.first { it.getValue("op").jsonPrimitive.content == "create_room" }
        assertTrue(
            "the room target must not carry a worldline",
            roomRow.getValue("target").jsonObject.getValue("worldline_id") is
                kotlinx.serialization.json.JsonNull,
        )
        val roomKeys = SyncE2EE.deriveScopeKeys(
            masterKey, SyncE2EE.Scope(account, "PHONE_SPACE", room, null),
        )
        val title = SyncE2EE.open(
            Base64.getDecoder().decode(
                roomRow.getValue("set").jsonObject.getValue("title").jsonPrimitive.content,
            ),
            roomKeys.fieldAEADKey,
            SyncE2EE.AADContext(
                SyncE2EE.Scope(account, "PHONE_SPACE", room, null),
                "room", room, "title", null, null,
            ),
        )
        assertEquals("폰 단톡방", title.toString(Charsets.UTF_8))

        // A bubble, by contrast, is worldline-scoped and only opens under it.
        val bubbleKeys = SyncE2EE.deriveScopeKeys(
            masterKey, SyncE2EE.Scope(account, "PHONE_SPACE", room, worldline),
        )
        val bubbleRow = queued.first { it.getValue("op").jsonPrimitive.content == "create_bubble" }
        val messageId = bubbleRow.getValue("target").jsonObject
            .getValue("message_id").jsonPrimitive.content
        val order = bubbleRow.getValue("bubble_order").jsonPrimitive.content.toLong()
        assertEquals(
            worldline,
            bubbleRow.getValue("target").jsonObject.getValue("worldline_id").jsonPrimitive.content,
        )
        val text = SyncE2EE.open(
            Base64.getDecoder().decode(
                bubbleRow.getValue("set").jsonObject.getValue("text").jsonPrimitive.content,
            ),
            bubbleKeys.fieldAEADKey,
            SyncE2EE.AADContext(
                SyncE2EE.Scope(account, "PHONE_SPACE", room, worldline),
                "bubble", messageId, "text", order, null,
            ),
        )
        assertEquals(bubbles[0].text, text.toString(Charsets.UTF_8))

        // And not under the null-worldline scope the room row uses.
        val wrong = runCatching {
            SyncE2EE.open(
                Base64.getDecoder().decode(
                    bubbleRow.getValue("set").jsonObject.getValue("text").jsonPrimitive.content,
                ),
                roomKeys.fieldAEADKey,
                SyncE2EE.AADContext(
                    SyncE2EE.Scope(account, "PHONE_SPACE", room, null),
                    "bubble", messageId, "text", order, null,
                ),
            )
        }
        assertTrue("a worldline bubble opened without its worldline", wrong.isFailure)
    }

    @Test
    fun `emits the fixture the worker suite pins against`() {
        val (manifest, queued) = run()
        val continuationOutbox = SyncOutbox(File(folder.newFolder(), "continuation-outbox.bin"))
        writer(originSpaceId = "MAC_SPACE", writerSpaceId = "PHONE_SPACE")
            .write(room, "이어쓰기", emptyList(), continuationOutbox)
        val continuation = Json.parseToJsonElement(
            continuationOutbox.pending().single().rawBody.toString(Charsets.UTF_8),
        )
        val payload = buildJsonObject {
            put("account_id", account)
            put("device_id", device)
            put("space_id", "PHONE_SPACE")
            put("room_id", manifest.roomId)
            put("master_key_base64", Base64.getEncoder().encodeToString(masterKey))
            put(
                "expected",
                buildJsonObject {
                    put("turn_count", manifest.turnCount)
                    put("bubble_count", manifest.bubbleCount)
                    put("content_hash", manifest.contentHash)
                },
            )
            put("operations", queued)
            put("continuation_room_operation", continuation)
        }
        // Written into the repository, next to the Swift-produced fixture, so
        // the Worker suite and the macOS reader both consume real writer output.
        val target = File(System.getProperty("gagaodok.fixtureDir") ?: "src/test/resources")
        target.mkdirs()
        val file = File(target, "kotlin-shadow-operations.json")
        file.writeText(Json { prettyPrint = true }.encodeToString(JsonObject.serializer(), payload))
        assertTrue(file.length() > 0)
    }
}
