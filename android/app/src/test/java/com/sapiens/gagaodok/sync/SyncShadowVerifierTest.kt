package com.sapiens.gagaodok.sync

import java.io.File
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Cross-device contract: rows the macOS importer actually produced, opened here.
 *
 * The fixture is emitted by the Swift side, not written in Kotlin. A payload
 * built locally would only prove this file agrees with itself; the failure this
 * guards against is the two platforms drifting apart in key derivation or AAD
 * construction, which nothing on one platform alone can catch.
 *
 * Everything in it is synthetic — a made-up account, a made-up room, two
 * invented lines.
 */
class SyncShadowVerifierTest {

    @get:Rule val folder = TemporaryFolder()

    private val fixture: JsonObject = Json.parseToJsonElement(
        checkNotNull(javaClass.classLoader?.getResourceAsStream("swift-shadow-replica.json"))
            .readBytes().toString(Charsets.UTF_8)
    ).jsonObject

    private val accountId get() = fixture.getValue("account_id").jsonPrimitive.content
    private val roomId get() = fixture.getValue("room_id").jsonPrimitive.content
    private val expected get() = fixture.getValue("expected").jsonObject
    private val masterKey: ByteArray
        get() = Base64.getDecoder()
            .decode(fixture.getValue("master_key_base64").jsonPrimitive.content)

    private fun secrets(key: ByteArray = masterKey): () -> SyncSecretLoadResult = {
        SyncSecretLoadResult.Available(
            SyncSecretBundle(accountMasterKey = key, deviceToken = ByteArray(32) { 7 })
        )
    }

    private fun replica(entries: JsonArray = fixture.getValue("entries").jsonArray): SyncReplicaStore {
        val store = SyncReplicaStore(File(folder.newFolder(), "replica.json"))
        store.apply(entries.toString().toByteArray(Charsets.UTF_8))
        return store
    }

    @Test
    fun `opens every bubble the mac wrote and agrees on the digest`() {
        val result = SyncShadowVerifier.verify(replica(), accountId, roomId, secrets())

        assertEquals(expected.getValue("bubble_count").jsonPrimitive.content.toInt(), result.bubbleCount)
        assertEquals(expected.getValue("turn_count").jsonPrimitive.content.toInt(), result.turnCount)
        assertTrue("a bubble the mac wrote did not open here", result.allDecrypted)
        // The digest is computed independently on each side from identity and
        // order. Agreeing on it means the same bubbles arrived in the same
        // order, and neither device had to show a line to prove it.
        assertEquals(
            expected.getValue("content_hash").jsonPrimitive.content,
            result.contentHash
        )
    }

    @Test
    fun `refuses to open under a different account key`() {
        val other = ByteArray(32) { index -> (index * 5 + 1).toByte() }
        val result = SyncShadowVerifier.verify(replica(), accountId, roomId, secrets(other))

        // The rows are all there and the digest still matches — identity and
        // order do not depend on the key. What fails is reading them.
        assertEquals(expected.getValue("bubble_count").jsonPrimitive.content.toInt(), result.bubbleCount)
        assertEquals(0, result.decryptedCount)
        assertFalse(result.allDecrypted)
    }

    @Test
    fun `refuses a bubble whose order was changed without re-encryption`() {
        val tampered = buildJsonArray {
            for (element in fixture.getValue("entries").jsonArray) {
                val item = element.jsonObject
                if (item.getValue("entity_type").jsonPrimitive.content != "bubble") {
                    add(item); continue
                }
                val projection = item.getValue("projection").jsonObject
                add(
                    buildJsonObject {
                        put("entity_type", "bubble")
                        put("identity", item.getValue("identity"))
                        put(
                            "projection",
                            buildJsonObject {
                                for ((key, value) in projection) {
                                    if (key == "bubble_order") {
                                        // Move it. bubble_order is inside the
                                        // AAD, so this must not open.
                                        put(key, value.jsonPrimitive.content.toLong() + 10)
                                    } else put(key, value)
                                }
                            }
                        )
                    }
                )
            }
        }
        val result = SyncShadowVerifier.verify(replica(tampered), accountId, roomId, secrets())
        assertEquals(0, result.decryptedCount)
    }

    @Test
    fun `refuses a bubble re-attributed to another account`() {
        val stranger = "A0000000-0000-4000-8000-0000000000FF"
        val result = SyncShadowVerifier.verify(replica(), stranger, roomId, secrets())
        // The scope root is derived from the account, so a row claimed by
        // another account cannot be opened even with the right master key.
        assertEquals(0, result.decryptedCount)
    }

    @Test
    fun `reports an absent room rather than an empty success`() {
        val missing = "C0000000-0000-4000-8000-0000000000FF"
        try {
            SyncShadowVerifier.verify(replica(), accountId, missing, secrets())
            throw AssertionError("a room that is not there was reported as verified")
        } catch (error: SyncShadowVerifyException) {
            assertEquals(SyncShadowVerifyException.Reason.ROOM_ABSENT, error.reason)
        }
    }

    @Test
    fun `refuses to run without secrets`() {
        try {
            SyncShadowVerifier.verify(replica(), accountId, roomId) { SyncSecretLoadResult.Absent }
            throw AssertionError("ran without an account key")
        } catch (error: SyncShadowVerifyException) {
            assertEquals(SyncShadowVerifyException.Reason.SECRETS_UNAVAILABLE, error.reason)
        }
    }
}
