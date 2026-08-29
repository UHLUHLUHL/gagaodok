package com.sapiens.gagaodok.sync

import java.io.File
import java.nio.file.Files
import okhttp3.Request
import org.junit.Assert.*
import org.junit.Test

/**
 * Synthetic onboarding screen state model tests.
 *
 * Every dependency is a double. No Keystore entry is touched, no request leaves
 * the machine, and the only files written are the coordinators' own. A
 * conversation fixture sits beside them and is checked byte for byte
 * afterwards, because "the screen does not touch real data" is the claim this
 * whole surface rests on.
 */
class SyncOnboardingModelTest {
    private class MemoryVault : SyncSecretVault {
        var stored: SyncSecretBundle? = null
        var saveCount = 0
        override fun load(): SyncSecretLoadResult =
            stored?.let { SyncSecretLoadResult.Available(it) } ?: SyncSecretLoadResult.Absent
        override fun save(secrets: SyncSecretBundle): Boolean { stored = secrets; saveCount += 1; return true }
    }

    private class Harness(val dir: File, enroll: List<Int>, pullBodies: List<Pair<Int, String>>) {
        /** Stands in for an existing conversation file. Never referenced by the model. */
        val conversation: File = dir.resolve("conversations.json").apply { writeText(CONVERSATION_FIXTURE) }
        val vault = MemoryVault()
        val enrollRequests = mutableListOf<Request>()
        val enrollBodies = mutableListOf<ByteArray>()
        private val enrollQueue = ArrayDeque(enroll)
        private val pullQueue = ArrayDeque(pullBodies)
        val replica = SyncReplicaStore(dir.resolve("replica.json"))
        val pullPaths = mutableListOf<String>()
        val model: SyncOnboardingModel

        init {
            val onboarding = SyncOnboardingCoordinator(
                baseUrl = "https://synthetic.invalid",
                vault = vault,
                connectionStore = SyncConnectionStateStore(dir.resolve("connection.json")),
                journal = SyncEnrollmentJournal(dir.resolve("enrollment.bin")),
                transport = SyncHttpTransport { request ->
                    enrollRequests += request
                    enrollBodies += okio.Buffer().also { request.body!!.writeTo(it) }.readByteArray()
                    SyncHttpResponse(enrollQueue.removeFirst(), "{}".toByteArray())
                },
                random = SyncRandomSource { count -> ByteArray(count) { ((it * 7 + count) and 0xff).toByte() } },
                words = SyncRecoveryMnemonic.words(
                    File("../../Sources/KakaoSapiens/Resources/sync/english-bip39.txt").readText(),
                ),
            )
            val client = SyncWorkerClient(
                "https://synthetic.invalid",
                ByteArray(32) { it.toByte() },
                SyncHttpTransport { request ->
                    pullPaths += request.url.encodedPath
                    val (status, body) = pullQueue.removeFirst()
                    if (status !in 200..299) throw SyncWorkerClientException(status)
                    SyncHttpResponse(status, body.toByteArray())
                },
            )
            model = SyncOnboardingModel(
                onboarding = onboarding,
                pull = SyncPullCoordinator(client, replica, dir.resolve("pull.json")),
                replica = replica,
                spaceId = "PHONE_SPACE",
                platform = "android_phone",
                identity = { SyncOnboardingIdentity(ACCOUNT, DEVICE, ENROLLMENT) },
            )
        }

        fun assertConversationUntouched(what: String) {
            assertEquals("$what: the conversation fixture changed", CONVERSATION_FIXTURE, conversation.readText())
        }
    }

    private fun harness(
        enroll: List<Int> = emptyList(),
        pull: List<Pair<Int, String>> = emptyList(),
        work: (Harness) -> Unit,
    ) {
        val dir = Files.createTempDirectory("sync-ui").toFile()
        try { work(Harness(dir, enroll, pull)) } finally { dir.deleteRecursively() }
    }

    private fun bootstrapBody(watermark: Int, hasMore: Boolean, cursor: String?) =
        """{"protocol_version":1,"request_id":"AAAAAAAA-0000-4000-8000-00000000000A","result":{
        "snapshot_high_watermark_seq":$watermark,"has_more":$hasMore,
        "next_cursor":${cursor?.let { "\"$it\"" } ?: "null"},
        "items":[{"entity_type":"room","identity":{"space_id":"PHONE_SPACE","room_id":"$ROOM"},
        "projection":{"space_id":"PHONE_SPACE","room_id":"$ROOM","title":"AQE=","revision":0}}]}}"""

    /** Appearing is not consent. */
    @Test fun `opening the screen sends, stores and writes nothing`() = harness { h ->
        h.model.refresh()
        assertEquals(SyncOnboardingUiState.Disconnected, h.model.state.value)
        assertTrue(h.enrollRequests.isEmpty())
        assertTrue(h.pullPaths.isEmpty())
        assertNull(h.vault.stored)
        assertNull(h.model.recoveryPhrase.value)
        assertTrue(h.model.actions.canBeginConnection)
        assertFalse(h.model.actions.canConfirmPhrase)
        h.assertConversationUntouched("refresh")
    }

    @Test fun `the phrase must be confirmed before anything is sent`() = harness { h ->
        h.model.beginConnection()
        assertEquals(SyncOnboardingUiState.AwaitingPhraseConfirmation, h.model.state.value)
        assertEquals(12, h.model.recoveryPhrase.value!!.split(" ").size)
        // The phrase is on screen and still nothing has left the device.
        assertTrue(h.enrollRequests.isEmpty())
        assertNull(h.vault.stored)
        assertFalse(h.model.actions.canBeginConnection)
        h.assertConversationUntouched("prepare")
    }

    @Test fun `confirming sends once and leaves sync off`() = harness(enroll = listOf(201)) { h ->
        h.model.beginConnection()
        h.model.confirmPhraseSaved()
        assertEquals(SyncOnboardingUiState.ConnectedSyncOff, h.model.state.value)
        assertEquals(1, h.enrollRequests.size)
        assertEquals(1, h.vault.saveCount)
        // The phrase is gone from memory the moment it is no longer needed.
        assertNull(h.model.recoveryPhrase.value)
        assertTrue(h.model.actions.canAdvanceBootstrap)
        h.assertConversationUntouched("enrollment")
    }

    @Test fun `a refusal offers only the staged retry`() = harness(enroll = listOf(503, 200)) { h ->
        h.model.beginConnection()
        h.model.confirmPhraseSaved()
        assertEquals(
            SyncOnboardingUiState.RetryableError(SyncOnboardingUiError.ENROLLMENT_REFUSED_RETRY_PENDING),
            h.model.state.value,
        )
        assertNull(h.vault.stored)
        assertNull(h.model.recoveryPhrase.value)
        // Starting over would build a second enrollment for the same account.
        assertFalse(h.model.actions.canBeginConnection)
        assertTrue(h.model.actions.canRetryEnrollment)

        h.model.retryEnrollment()
        assertEquals(SyncOnboardingUiState.ConnectedSyncOff, h.model.state.value)
        assertEquals(2, h.enrollBodies.size)
        assertArrayEquals(h.enrollBodies[0], h.enrollBodies[1])
        h.assertConversationUntouched("retry")
    }

    @Test fun `bootstrap writes only the shadow replica`() = harness(
        enroll = listOf(201),
        pull = listOf(
            200 to bootstrapBody(4, true, "CURSOR-1"),
            200 to bootstrapBody(4, false, null),
        ),
    ) { h ->
        h.model.beginConnection()
        h.model.confirmPhraseSaved()

        h.model.advanceBootstrap()
        assertTrue(h.model.state.value is SyncOnboardingUiState.Bootstrapping)
        h.model.advanceBootstrap()
        assertEquals(SyncOnboardingUiState.ReplicaReady(1), h.model.state.value)
        assertEquals(1, h.replica.snapshot().size)
        assertFalse(h.model.actions.canAdvanceBootstrap)
        h.assertConversationUntouched("bootstrap")
    }

    @Test fun `a refused page is retryable and writes nothing`() = harness(
        enroll = listOf(201),
        pull = listOf(
            // An envelope this build does not understand.
            200 to """{"protocol_version":9,"request_id":"A","result":{}}""",
            200 to bootstrapBody(4, false, null),
        ),
    ) { h ->
        h.model.beginConnection()
        h.model.confirmPhraseSaved()

        h.model.advanceBootstrap()
        assertEquals(
            SyncOnboardingUiState.RetryableError(SyncOnboardingUiError.BOOTSTRAP_FAILED),
            h.model.state.value,
        )
        assertTrue(h.replica.snapshot().isEmpty())
        assertTrue(h.model.actions.canAdvanceBootstrap)

        h.model.advanceBootstrap()
        assertTrue(h.model.state.value is SyncOnboardingUiState.ReplicaReady)
        h.assertConversationUntouched("refused page")
    }

    @Test fun `re-applying a page changes nothing`() = harness(
        enroll = listOf(201),
        pull = listOf(
            200 to bootstrapBody(4, true, "CURSOR-1"),
            200 to bootstrapBody(4, true, "CURSOR-2"),
        ),
    ) { h ->
        h.model.beginConnection()
        h.model.confirmPhraseSaved()
        h.model.advanceBootstrap()
        val after = h.replica.snapshot()
        // The same identity again, as a device that crashed mid-apply would see.
        h.model.advanceBootstrap()
        assertEquals(after, h.replica.snapshot())
    }

    /** A half link is reported, and no replacement key is generated. */
    @Test fun `a half-linked device says so and generates nothing`() = harness { h ->
        h.vault.stored = SyncSecretBundle(ByteArray(32) { 1 }, ByteArray(32) { 2 })
        h.model.refresh()
        assertEquals(SyncOnboardingUiState.RelinkRequired, h.model.state.value)
        assertFalse(h.model.actions.canBeginConnection)
        assertFalse(h.model.actions.canAdvanceBootstrap)

        h.model.beginConnection()
        assertEquals(SyncOnboardingUiState.RelinkRequired, h.model.state.value)
        assertTrue(h.enrollRequests.isEmpty())
        assertNull(h.model.recoveryPhrase.value)
    }

    @Test fun `disconnect is a confirmation only`() = harness(enroll = listOf(201)) { h ->
        h.model.beginConnection()
        h.model.confirmPhraseSaved()
        h.model.requestDisconnect()
        assertTrue(h.model.disconnectConfirmationVisible.value)
        // Nothing is removed in this build.
        assertNotNull(h.vault.stored)
        assertEquals(SyncOnboardingUiState.ConnectedSyncOff, h.model.state.value)
        h.model.dismissDisconnect()
        assertFalse(h.model.disconnectConfirmationVisible.value)
    }

    @Test fun `nothing sensitive is describable from the state`() = harness(enroll = listOf(503)) { h ->
        h.model.beginConnection()
        val phrase = h.model.recoveryPhrase.value.orEmpty()
        h.model.confirmPhraseSaved()

        // Whatever a screen or a log could render must not carry the phrase,
        // the endpoint, a token or ciphertext.
        val describable = "${h.model.state.value} ${h.model.actions}"
        phrase.split(" ").forEach { assertFalse(describable.contains(it)) }
        listOf("synthetic.invalid", "gdt1_", "AQE=", "https://").forEach {
            assertFalse(describable.contains(it))
        }
    }

    private companion object {
        const val ACCOUNT = "A0000000-0000-4000-8000-000000000001"
        const val DEVICE = "80000000-0000-4000-8000-000000000002"
        const val ENROLLMENT = "B0000000-0000-4000-8000-0000000000E2"
        const val ROOM = "10000000-0000-4000-8000-0000000000A1"
        const val CONVERSATION_FIXTURE = """{"rooms":[{"id":"local-room","messages":["안녕"]}]}"""
    }
}
