package com.sapiens.gagaodok.sync

import java.io.File
import java.nio.file.Files
import okhttp3.Request
import org.junit.Assert.*
import org.junit.Test

/**
 * Onboarding coordinator tests.
 *
 * Every dependency is a double: no Keystore entry is read or written, no
 * request leaves the machine, and no conversation storage is opened. The
 * fixtures are synthetic identifiers only.
 */
class SyncOnboardingCoordinatorTest {
    private class MemoryVault : SyncSecretVault {
        var stored: SyncSecretBundle? = null
        var saveCount = 0
        var forced: SyncSecretLoadResult? = null
        override fun load(): SyncSecretLoadResult =
            forced ?: stored?.let { SyncSecretLoadResult.Available(it) } ?: SyncSecretLoadResult.Absent
        override fun save(secrets: SyncSecretBundle): Boolean { stored = secrets; saveCount += 1; return true }
    }

    private class Harness(val dir: File, statuses: List<Int>) {
        val vault = MemoryVault()
        val connection = SyncConnectionStateStore(dir.resolve("connection.json"))
        val journal = SyncEnrollmentJournal(dir.resolve("enrollment.bin"))
        val requests = mutableListOf<Request>()
        val bodies = mutableListOf<ByteArray>()
        private val queue = ArrayDeque(statuses)
        val coordinator = SyncOnboardingCoordinator(
            baseUrl = "https://synthetic.invalid",
            vault = vault,
            connectionStore = connection,
            journal = journal,
            transport = SyncHttpTransport { request ->
                requests += request
                bodies += okio.Buffer().also { request.body!!.writeTo(it) }.readByteArray()
                SyncHttpResponse(queue.removeFirst(), "{}".toByteArray())
            },
            random = SyncRandomSource { count -> ByteArray(count) { ((it * 7 + count) and 0xff).toByte() } },
            words = SyncRecoveryMnemonic.words(
                File("../../Sources/KakaoSapiens/Resources/sync/english-bip39.txt").readText(),
            ),
        )
    }

    private fun harness(statuses: List<Int>, work: (Harness) -> Unit) {
        val dir = Files.createTempDirectory("onboarding").toFile()
        try { work(Harness(dir, statuses)) } finally { dir.deleteRecursively() }
    }

    private fun Harness.prepare() = coordinator.prepare(ACCOUNT, DEVICE, ENROLLMENT, "MAC_SPACE", "macos")

    @Test fun `a fresh install is disconnected`() = harness(emptyList()) { h ->
        assertEquals(SyncOnboardingStatus.Disconnected, h.coordinator.status())
    }

    @Test fun `prepare shows a phrase and sends, stages and stores nothing`() = harness(emptyList()) { h ->
        val draft = h.prepare()
        assertEquals(12, draft.recoveryPhrase.split(" ").size)
        assertTrue(h.requests.isEmpty())
        assertNull(h.journal.pending())
        assertNull(h.vault.stored)
        assertEquals(SyncConnectionLoadResult.Absent, h.connection.load())
    }

    /** Without the phrase back there is nothing to recover the account with. */
    @Test fun `an unconfirmed phrase never enrolls`() = harness(emptyList()) { h ->
        val draft = h.prepare()
        val error = assertThrows(SyncOnboardingException::class.java) {
            h.coordinator.confirm(draft, "not the phrase")
        }
        assertEquals(SyncOnboardingException.Reason.PHRASE_NOT_CONFIRMED, error.reason)
        assertTrue(h.requests.isEmpty())
        assertNull(h.journal.pending())
        assertNull(h.vault.stored)
    }

    @Test fun `a successful enrollment connects but leaves sync off`() = harness(listOf(201)) { h ->
        val draft = h.prepare()
        val configuration = h.coordinator.confirm(draft, draft.recoveryPhrase)

        assertEquals(1, h.requests.size)
        assertEquals("POST", h.requests[0].method)
        assertEquals("/v1/enrollment/initialize", h.requests[0].url.encodedPath)
        // Enrollment creates the device a token would prove, so it carries none.
        assertNull(h.requests[0].header("Authorization"))
        assertArrayEquals(draft.enrollmentPackage.rawRequestBody, h.bodies[0])

        assertFalse(configuration.enabled)
        assertEquals(ACCOUNT, configuration.accountId)
        assertNull(configuration.changesCursor)
        assertEquals(1, h.vault.saveCount)
        assertEquals(SyncOnboardingStatus.Connected(configuration), h.coordinator.status())
        assertNull(h.journal.pending())

        // The phrase never reaches storage.
        val onDisk = h.dir.walkTopDown().filter { it.isFile }.joinToString("") { it.readText(Charsets.ISO_8859_1) }
        draft.recoveryPhrase.split(" ").forEach { assertFalse(onDisk.contains("\"$it\"")) }
    }

    @Test fun `a refusal keeps the exact bytes and the retry replays them`() = harness(listOf(503, 200)) { h ->
        val draft = h.prepare()
        val error = assertThrows(SyncOnboardingException::class.java) {
            h.coordinator.confirm(draft, draft.recoveryPhrase)
        }
        assertEquals(SyncOnboardingException.Reason.ENROLLMENT_REJECTED, error.reason)
        assertEquals(503, error.statusCode)
        assertNull(h.vault.stored)
        assertEquals(SyncConnectionLoadResult.Absent, h.connection.load())
        assertArrayEquals(draft.enrollmentPackage.rawRequestBody, h.journal.pending()!!.rawBody)

        val configuration = h.coordinator.retryPendingEnrollment(draft.enrollmentPackage.secrets)
        assertEquals(2, h.bodies.size)
        // Byte-identical, which is what makes the retry a replay.
        assertArrayEquals(h.bodies[0], h.bodies[1])
        assertEquals(ACCOUNT, configuration.accountId)
        assertFalse(configuration.enabled)
        assertNull(h.journal.pending())
    }

    /** Half a link is not a link, and the missing half cannot be guessed. */
    @Test fun `a half-linked device refuses to start over`() = harness(emptyList()) { h ->
        h.vault.stored = SyncSecretBundle(ByteArray(32) { 1 }, ByteArray(32) { 2 })
        assertEquals(SyncOnboardingStatus.RelinkRequired, h.coordinator.status())
        val error = assertThrows(SyncOnboardingException::class.java) { h.prepare() }
        assertEquals(SyncOnboardingException.Reason.RELINK_REQUIRED, error.reason)
    }

    @Test fun `a connected device refuses a second enrollment`() = harness(listOf(201)) { h ->
        val draft = h.prepare()
        h.coordinator.confirm(draft, draft.recoveryPhrase)
        val error = assertThrows(SyncOnboardingException::class.java) { h.prepare() }
        assertEquals(SyncOnboardingException.Reason.ALREADY_CONNECTED, error.reason)
    }

    private companion object {
        const val ACCOUNT = "A0000000-0000-4000-8000-000000000001"
        const val DEVICE = "80000000-0000-4000-8000-000000000001"
        const val ENROLLMENT = "B0000000-0000-4000-8000-0000000000E1"
    }
}
