package com.sapiens.gagaodok.sync

import java.io.File
import java.nio.file.Files
import java.util.Base64
import okhttp3.Request
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/**
 * Pairing contract and local end-to-end tests — the Kotlin half of the same
 * contract the Swift suite checks.
 *
 * The Worker is an in-process double enforcing the same state rules. Nothing
 * touches the Keystore, the network, or any conversation file, and a
 * conversation fixture sits beside the stores so "pairing does not touch real
 * data" is checked rather than asserted.
 */
class SyncPairingTest {
    private class MemoryVault : SyncSecretVault {
        var stored: SyncSecretBundle? = null
        var failSave = false
        override fun load(): SyncSecretLoadResult =
            stored?.let { SyncSecretLoadResult.Available(it) } ?: SyncSecretLoadResult.Absent
        override fun save(secrets: SyncSecretBundle): Boolean {
            if (failSave) return false
            stored = secrets
            return true
        }
    }

    /**
     * Seeded, so a second device in a test is a genuinely different device.
     * Sharing one seed would make an "attacker" derive the honest joiner's own
     * claim secret and prove nothing.
     */
    private class CountingRandom(private var counter: Int = 1) : SyncRandomSource {
        override fun bytes(count: Int): ByteArray {
            val seed = counter++
            return ByteArray(count) { ((it * 7 + seed) and 0xff).toByte() }
        }
    }

    private class FakeWorker(val hostToken: String) : SyncHttpTransport {
        class ClaimRow(
            val lookup: String,
            val envelope: String,
            var state: String = "submitted",
            var delivery: String? = null,
        )
        val sessions = mutableMapOf<String, Pair<String, Boolean>>()
        val claims = linkedMapOf<String, ClaimRow>()
        var expireSessions = false
        var unauthenticatedPaths = mutableListOf<String>()

        override fun send(request: Request): SyncHttpResponse {
            val path = request.url.encodedPath
            val auth = request.header("Authorization")
            if (auth == null) unauthenticatedPaths += path
            val body = request.body?.let { raw ->
                val buffer = okio.Buffer().also { raw.writeTo(it) }
                runCatching { JSONObject(buffer.readUtf8()) }.getOrNull()
            }
            fun ok(result: JSONObject, status: Int = 200) = SyncHttpResponse(
                status,
                JSONObject().put("protocol_version", 1).put("result", result).toString().toByteArray(),
            )
            fun fail(status: Int) = SyncHttpResponse(status, "{}".toByteArray())

            if (path == "/v1/pairing/sessions" && request.method == "POST") {
                if (auth != hostToken) return fail(401)
                val id = body!!.getString("session_id")
                sessions[id] = body.getString("pairing_session_lookup") to false
                return ok(
                    JSONObject().put("status", "created").put("session_id", id)
                        .put("expires_at", "2030-01-01T00:00:00.000Z"),
                    201,
                )
            }
            val parts = path.split("/").filter { it.isNotEmpty() }
            if (parts.size < 4 || parts[1] != "pairing" || parts[2] != "sessions") return fail(404)
            val sessionId = parts[3]
            val session = sessions[sessionId] ?: return fail(404)
            if (session.second || expireSessions) return fail(404)

            if (parts.size == 5 && parts[4] == "claims" && request.method == "POST") {
                if (body!!.getString("pairing_session_lookup") != session.first) return fail(404)
                val id = body.getString("claim_id")
                claims[id] = ClaimRow(
                    body.getString("claim_lookup"),
                    body.getString("claim_envelope"),
                )
                return ok(JSONObject().put("status", "submitted").put("claim_id", id), 201)
            }
            if (parts.size == 5 && parts[4] == "claims" && request.method == "GET") {
                if (auth != hostToken) return fail(401)
                val array = org.json.JSONArray()
                claims.forEach { (id, row) ->
                    array.put(
                        JSONObject().put("claim_id", id).put("claim_lookup", row.lookup)
                            .put("claim_envelope", row.envelope).put("state", row.state),
                    )
                }
                return ok(JSONObject().put("claims", array))
            }
            if (parts.size != 7 || parts[4] != "claims") return fail(404)
            val row = claims[parts[5]] ?: return fail(404)

            if (parts[6] == "approve") {
                if (auth != hostToken) return fail(401)
                // The lookup must be the one this exact claim carries.
                if (body!!.getString("claim_lookup") != row.lookup || row.state != "submitted") {
                    return fail(409)
                }
                row.state = "approved"
                row.delivery = body.getString("delivery_envelope")
                return ok(JSONObject().put("status", "approved").put("claim_id", parts[5]))
            }
            if (parts[6] == "redeem") {
                val delivery = row.delivery
                if (row.state != "approved" || delivery == null) return fail(409)
                if (body!!.getString("claim_lookup") != row.lookup) return fail(404)
                row.state = "consumed"
                sessions[sessionId] = session.first to true
                return ok(
                    JSONObject().put("status", "consumed").put("device_id", "X")
                        .put("delivery_envelope", delivery),
                )
            }
            return fail(404)
        }
    }

    private class Harness(val dir: File) {
        val conversation: File = dir.resolve("conversations.json")
            .apply { writeText(CONVERSATION_FIXTURE) }
        val hostTokenBytes = ByteArray(32) { it.toByte() }
        val worker = FakeWorker(
            "Device gdt1_" + Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { it.toByte() }),
        )
        val hostVault = MemoryVault().apply {
            stored = SyncSecretBundle(ByteArray(32) { (255 - it).toByte() }, ByteArray(32) { it.toByte() })
        }
        val joinerVault = MemoryVault()
        val connectionStore = SyncConnectionStateStore(dir.resolve("connection.json"))
        val host = SyncPairingHostCoordinator(
            SyncPairingClient(BASE_URL, { (hostVault.load() as? SyncSecretLoadResult.Available)?.secrets?.deviceToken }, worker),
            { hostVault.load() },
            CountingRandom(),
        )
        val joinerClient = SyncPairingClient(BASE_URL, { null }, worker)
        val joiner = SyncPairingJoinerCoordinator(CountingRandom(), joinerVault, connectionStore)

        fun assertConversationUntouched(what: String) {
            assertEquals("$what: the conversation fixture changed", CONVERSATION_FIXTURE, conversation.readText())
        }
    }

    private fun harness(work: (Harness) -> Unit) {
        val dir = Files.createTempDirectory("pairing").toFile()
        try { work(Harness(dir)) } finally { dir.deleteRecursively() }
    }

    // MARK: QR payload contract

    @Test fun `the QR payload matches the shared fixture`() {
        val vector = fixture().getJSONObject("pairing_qr")
        val payload = SyncPairingPayload.create(
            vector.getString("base_url"),
            vector.getString("account_id"),
            vector.getString("session_id"),
            hex(vector.getString("pairing_secret_hex")),
        )
        assertArrayEquals(hex(vector.getString("payload_hex")), payload.encoded())
        assertEquals(vector.getString("payload_base64url"), payload.encodedText())
        assertEquals(payload, SyncPairingPayload.decode(vector.getString("payload_base64url")))
    }

    @Test fun `malformed and non-canonical payloads are refused`() {
        val good = samplePayload()
        val bytes = good.encoded()
        val text = good.encodedText()

        assertRejects(bytes + byteArrayOf(0)) // trailing bytes
        assertRejects("GDK1".toByteArray() + bytes.copyOfRange(4, bytes.size)) // the AAD magic
        assertRejects(bytes.copyOfRange(0, bytes.size - 1)) // truncated

        // A padded Base64 spelling decodes to the same bytes and must still be
        // refused: two spellings of one payload is one too many.
        assertThrows(SyncPairingPayload.PayloadException::class.java) {
            SyncPairingPayload.decode("$text=")
        }
        // A lowercase UUID is a different spelling of the same identity.
        assertThrows(SyncPairingPayload.PayloadException::class.java) {
            SyncPairingPayload.create(
                BASE_URL, ACCOUNT.lowercase(), SESSION, ByteArray(32),
            )
        }
        assertThrows(SyncPairingPayload.PayloadException::class.java) {
            SyncPairingPayload.create("http://pairing.invalid", ACCOUNT, SESSION, ByteArray(32))
        }
        assertThrows(SyncPairingPayload.PayloadException::class.java) {
            SyncPairingPayload.create("https://pairing.invalid/sync", ACCOUNT, SESSION, ByteArray(32))
        }
        assertThrows(SyncPairingPayload.PayloadException::class.java) {
            SyncPairingPayload.create("https://user@pairing.invalid", ACCOUNT, SESSION, ByteArray(32))
        }
        assertThrows(SyncPairingPayload.PayloadException::class.java) {
            SyncPairingPayload.create(BASE_URL, ACCOUNT, SESSION, ByteArray(31))
        }
    }

    @Test fun `the payload carries no secret beyond the pairing secret`() = harness { h ->
        val payload = h.host.openSession(ACCOUNT, BASE_URL)
        val raw = payload.encoded()
        val bundle = (h.hostVault.load() as SyncSecretLoadResult.Available).secrets
        assertFalse("master key must not appear", contains(raw, bundle.accountMasterKey))
        assertFalse("host token must not appear", contains(raw, bundle.deviceToken))
        assertFalse(payload.encodedText().contains("http://"))
        h.assertConversationUntouched("open session")
    }

    // MARK: end to end

    @Test fun `host and joiner reach the same account`() = harness { h ->
        val payload = h.host.openSession(ACCOUNT, BASE_URL)
        val accepted = h.joiner.accept(payload.encodedText(), JOINER_DEVICE, "PHONE_SPACE", "android_phone")
        // Nothing has been sent yet.
        assertTrue(h.worker.claims.isEmpty())

        h.joiner.submit(h.joinerClient)
        val candidates = h.host.pollCandidates()
        assertEquals(1, candidates.size)
        val candidate = candidates.first()
        assertEquals(accepted.shortAuthenticationString, candidate.shortAuthenticationString)
        assertEquals(6, candidate.shortAuthenticationString.length)

        // Approving without the human confirmation is refused.
        val refusal = assertThrows(SyncPairingException::class.java) {
            h.host.approve(candidate, sasConfirmed = false)
        }
        assertEquals(SyncPairingException.Reason.SAS_NOT_CONFIRMED, refusal.reason)
        // Redeeming before approval is refused too.
        assertThrows(SyncPairingException::class.java) { h.joiner.redeem(h.joinerClient, true) }
        assertNull(h.joinerVault.stored)

        h.host.approve(candidate, sasConfirmed = true)
        h.joiner.redeem(h.joinerClient, sasConfirmed = true)

        val joined = (h.joinerVault.load() as SyncSecretLoadResult.Available).secrets
        val hostBundle = (h.hostVault.load() as SyncSecretLoadResult.Available).secrets
        assertArrayEquals(hostBundle.accountMasterKey, joined.accountMasterKey)
        assertFalse(hostBundle.deviceToken.contentEquals(joined.deviceToken))

        val configuration = (h.connectionStore.load() as SyncConnectionLoadResult.Available).configuration
        assertEquals(ACCOUNT, configuration.accountId)
        assertFalse("joining must not enable sync", configuration.enabled)
        h.assertConversationUntouched("join")

        // A second redeem is refused and what is stored does not change.
        assertThrows(SyncPairingException::class.java) { h.joiner.redeem(h.joinerClient, true) }
        assertArrayEquals(joined.deviceToken, h.joinerVault.stored!!.deviceToken)
    }

    @Test fun `redeem candidate leaves the active vault and connection untouched`() = harness { h ->
        val payload = h.host.openSession(ACCOUNT, BASE_URL)
        h.joiner.accept(payload.encodedText(), JOINER_DEVICE, "PHONE_SPACE", "android_phone")
        h.joiner.submit(h.joinerClient)
        val candidate = h.host.pollCandidates().first()
        h.host.approve(candidate, sasConfirmed = true)

        val redeemed = h.joiner.redeemCandidate(h.joinerClient, sasConfirmed = true)

        assertEquals(ACCOUNT, redeemed.connection.accountId)
        assertFalse(redeemed.connection.enabled)
        assertNull(h.joinerVault.stored)
        assertTrue(h.connectionStore.load() is SyncConnectionLoadResult.Absent)
        h.assertConversationUntouched("candidate redeem")
    }

    @Test fun `a duplicated QR does not yield another device's package`() = harness { h ->
        val payload = h.host.openSession(ACCOUNT, BASE_URL)
        h.joiner.accept(payload.encodedText(), JOINER_DEVICE, "PHONE_SPACE", "android_phone")
        h.joiner.submit(h.joinerClient)
        val candidate = h.host.pollCandidates().first()
        h.host.approve(candidate, sasConfirmed = true)

        val attackerVault = MemoryVault()
        val attackerStore = SyncConnectionStateStore(h.dir.resolve("attacker.json"))
        val attacker = SyncPairingJoinerCoordinator(CountingRandom(200), attackerVault, attackerStore)
        val attackerAccepted = attacker.accept(
            payload.encodedText(), "CCCCCCCC-0000-4000-8000-00000000000C", "PHONE_SPACE", "android_phone",
        )
        // Its digits differ, which is what lets the user tell them apart.
        assertNotEquals(
            candidate.shortAuthenticationString,
            attackerAccepted.shortAuthenticationString,
        )
        attacker.submit(h.joinerClient)
        assertThrows(SyncPairingException::class.java) { attacker.redeem(h.joinerClient, true) }
        assertNull(attackerVault.stored)
        assertTrue(attackerStore.load() is SyncConnectionLoadResult.Absent)
    }

    @Test fun `an unconnected device cannot host`() = harness { h ->
        h.hostVault.stored = null
        val error = assertThrows(SyncPairingException::class.java) {
            h.host.openSession(ACCOUNT, BASE_URL)
        }
        assertEquals(SyncPairingException.Reason.NOT_CONNECTED, error.reason)
        assertTrue(h.worker.sessions.isEmpty())
    }

    @Test fun `an expired session stops the flow`() = harness { h ->
        val payload = h.host.openSession(ACCOUNT, BASE_URL)
        h.joiner.accept(payload.encodedText(), JOINER_DEVICE, "PHONE_SPACE", "android_phone")
        h.worker.expireSessions = true
        val error = assertThrows(SyncPairingException::class.java) { h.joiner.submit(h.joinerClient) }
        assertEquals(SyncPairingException.Reason.SESSION_EXPIRED, error.reason)
    }

    @Test fun `a vault failure leaves no connection behind`() = harness { h ->
        val payload = h.host.openSession(ACCOUNT, BASE_URL)
        h.joiner.accept(payload.encodedText(), JOINER_DEVICE, "PHONE_SPACE", "android_phone")
        h.joiner.submit(h.joinerClient)
        h.host.approve(h.host.pollCandidates().first(), sasConfirmed = true)

        h.joinerVault.failSave = true
        assertThrows(SyncPairingException::class.java) { h.joiner.redeem(h.joinerClient, true) }
        assertTrue(h.connectionStore.load() is SyncConnectionLoadResult.Absent)
    }

    // MARK: state model and escrow policy

    @Test fun `actions come from the state, not the view`() {
        assertTrue(SyncPairingActions.forHost(SyncPairingHostState.VerifySAS("123456")).canApprove)
        assertFalse(SyncPairingActions.forHost(SyncPairingHostState.SessionReady).canApprove)
        assertFalse(SyncPairingActions.forJoiner(SyncPairingJoinerState.QrAccepted).canRedeem)
        assertFalse(SyncPairingActions.forJoiner(SyncPairingJoinerState.LinkedSyncOff).canAcceptPayload)
    }

    @Test fun `the escrow never invents a phrase and closes at seven days`() {
        assertFalse(SyncRecoveryEscrowPolicy.mayReveal(hasEntropy = false, stashedAt = 0, now = 0))
        assertTrue(SyncRecoveryEscrowPolicy.mayReveal(hasEntropy = true, stashedAt = 0, now = 0))
        assertFalse(
            SyncRecoveryEscrowPolicy.isWithinWindow(0, SyncRecoveryEscrowPolicy.WINDOW_MILLIS),
        )
        assertEquals(16, SyncRecoveryEscrowPolicy.ENTROPY_LENGTH)
    }

    // MARK: helpers

    private fun samplePayload() =
        SyncPairingPayload.create(BASE_URL, ACCOUNT, SESSION, ByteArray(32) { it.toByte() })

    private fun assertRejects(bytes: ByteArray) {
        assertThrows(SyncPairingPayload.PayloadException::class.java) {
            SyncPairingPayload.decode(bytes)
        }
    }

    private fun contains(haystack: ByteArray, needle: ByteArray): Boolean =
        (0..haystack.size - needle.size).any { start ->
            haystack.copyOfRange(start, start + needle.size).contentEquals(needle)
        }

    private fun hex(value: String) =
        ByteArray(value.length / 2) { value.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun fixture(): JSONObject {
        val file = generateSequence(File(System.getProperty("user.dir"))) { it.parentFile }
            .map { File(it, "tools/fixtures/e2ee_contract_vectors.json") }
            .first { it.isFile }
        return JSONObject(file.readText())
    }

    private companion object {
        const val BASE_URL = "https://pairing.invalid"
        const val ACCOUNT = "AAAAAAAA-0000-4000-8000-00000000000A"
        const val SESSION = "33333333-3333-4333-8333-333333333333"
        const val JOINER_DEVICE = "BBBBBBBB-0000-4000-8000-00000000000B"
        const val CONVERSATION_FIXTURE = """{"rooms":[{"id":"local","messages":["안녕"]}]}"""
    }
}
