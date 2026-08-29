package com.sapiens.gagaodok.sync

import java.net.URI
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Enrollment, end to end, with the order of operations as the contract.
 *
 * The individual pieces already exist — the package builder, the secret store,
 * the enrollment journal, the connection state and the Worker client. What was
 * missing is the sequence they have to run in, because every dangerous outcome
 * here is an ordering mistake: sending before the user has written the phrase
 * down, storing secrets for an enrollment the server never accepted, or
 * acknowledging a journal entry whose request never landed.
 *
 * Sync stays off after a successful enrollment. Connecting an account and
 * turning synchronisation on are separate decisions, and only the second one
 * touches real conversations.
 */

/** The secret store behind an interface, so a test never touches the Keystore. */
interface SyncSecretVault {
    fun load(): SyncSecretLoadResult
    fun save(secrets: SyncSecretBundle): Boolean
}

/** The real vault. Device-local, non-exportable, and never used from a test. */
class KeystoreSyncSecretVault(private val store: SyncSecretStore) : SyncSecretVault {
    override fun load(): SyncSecretLoadResult = store.load()
    override fun save(secrets: SyncSecretBundle): Boolean = store.save(secrets)
}

/**
 * Random material, so a test can make a draft reproducible without weakening
 * what the app actually generates.
 */
fun interface SyncRandomSource {
    fun bytes(count: Int): ByteArray
}

class SystemSyncRandomSource : SyncRandomSource {
    private val random = java.security.SecureRandom()
    override fun bytes(count: Int): ByteArray = ByteArray(count).also(random::nextBytes)
}

sealed interface SyncOnboardingStatus {
    /** No account is linked. This is the state a fresh install is in. */
    data object Disconnected : SyncOnboardingStatus

    /**
     * Linked. `enabled` says whether the user has turned sync on, which is a
     * separate decision from having connected.
     */
    data class Connected(val configuration: SyncConnectionConfiguration) : SyncOnboardingStatus

    /** The secrets and the endpoint state disagree, so neither is trusted. */
    data object RelinkRequired : SyncOnboardingStatus
}

class SyncOnboardingException(
    val reason: Reason,
    val statusCode: Int? = null,
) : Exception(reason.name) {
    enum class Reason {
        ALREADY_CONNECTED,
        RELINK_REQUIRED,

        /** The user was shown a recovery phrase and did not type it back. */
        PHRASE_NOT_CONFIRMED,

        /** The server refused the enrollment. The staged bytes are kept. */
        ENROLLMENT_REJECTED,
        MALFORMED_BODY,
        NO_PENDING_ENROLLMENT,
        STORAGE_FAILED,
    }
}

/**
 * What the user must see exactly once, plus the request that will be sent.
 *
 * The phrase lives here and nowhere else: it is never written to the journal,
 * the vault, the connection state or a log. Losing it means losing the account,
 * and storing it on the device would defeat the point of having one.
 */
data class SyncOnboardingDraft(
    val accountId: String,
    val deviceId: String,
    val enrollmentId: String,
    val recoveryPhrase: String,
    internal val enrollmentPackage: SyncEnrollmentPackage,
)

class SyncOnboardingCoordinator(
    baseUrl: String,
    private val vault: SyncSecretVault,
    private val connectionStore: SyncConnectionStateStore,
    private val journal: SyncEnrollmentJournal,
    private val transport: SyncHttpTransport,
    private val random: SyncRandomSource = SystemSyncRandomSource(),
    private val words: List<String>,
) {
    private val baseUrl = baseUrl.removeSuffix("/")

    init {
        val uri = runCatching { URI(this.baseUrl) }.getOrNull()
        require(uri?.scheme == "https" && !uri.host.isNullOrEmpty() && uri.query == null && uri.fragment == null)
    }

    /**
     * The two halves of "connected" read together.
     *
     * Secrets without endpoint state, or endpoint state without secrets, is a
     * half-finished link. It is reported as RelinkRequired rather than repaired,
     * because the missing half cannot be reconstructed and guessing at it would
     * attach this device to the wrong account.
     */
    fun status(): SyncOnboardingStatus {
        val secrets = vault.load()
        val connection = connectionStore.load()
        return when {
            secrets is SyncSecretLoadResult.Absent && connection is SyncConnectionLoadResult.Absent ->
                SyncOnboardingStatus.Disconnected
            secrets is SyncSecretLoadResult.Available && connection is SyncConnectionLoadResult.Available ->
                SyncOnboardingStatus.Connected(connection.configuration)
            else -> SyncOnboardingStatus.RelinkRequired
        }
    }

    /**
     * Build the enrollment without sending it.
     *
     * Nothing is staged, stored or transmitted here. The caller shows the
     * phrase, and only a caller that can hand it back gets to [confirm].
     */
    fun prepare(
        accountId: String,
        deviceId: String,
        enrollmentId: String,
        spaceId: String,
        platform: String,
    ): SyncOnboardingDraft {
        when (status()) {
            is SyncOnboardingStatus.Connected ->
                throw SyncOnboardingException(SyncOnboardingException.Reason.ALREADY_CONNECTED)
            is SyncOnboardingStatus.RelinkRequired ->
                throw SyncOnboardingException(SyncOnboardingException.Reason.RELINK_REQUIRED)
            is SyncOnboardingStatus.Disconnected -> Unit
        }
        val built = SyncEnrollmentBuilder.build(
            accountId = accountId,
            deviceId = deviceId,
            enrollmentId = enrollmentId,
            spaceId = spaceId,
            platform = platform,
            accountMasterKey = random.bytes(32),
            deviceToken = random.bytes(32),
            // 16 bytes: BIP-39 twelve words, which is what the recovery
            // material and the mnemonic codec both require.
            recoveryEntropy = random.bytes(16),
            recoveryNonce = random.bytes(12),
            words = words,
        )
        return SyncOnboardingDraft(accountId, deviceId, enrollmentId, built.recoveryPhrase, built)
    }

    /**
     * Send the enrollment, then activate — never the other way round.
     *
     * [confirmedPhrase] must be what [prepare] returned. It is the only evidence
     * the app has that the phrase was actually written down, and without it a
     * user could complete enrollment and then be unable to recover the account
     * from any other device.
     */
    fun confirm(draft: SyncOnboardingDraft, confirmedPhrase: String): SyncConnectionConfiguration {
        if (confirmedPhrase != draft.recoveryPhrase) {
            throw SyncOnboardingException(SyncOnboardingException.Reason.PHRASE_NOT_CONFIRMED)
        }
        // Staged first, so a crash between here and the response leaves the
        // exact bytes to retry. Enrollment is idempotent on those bytes; a
        // re-serialised body would be a different request.
        journal.stage(draft.enrollmentId, draft.enrollmentPackage.rawRequestBody)
        return send(
            enrollmentId = draft.enrollmentId,
            rawBody = draft.enrollmentPackage.rawRequestBody,
            accountId = draft.accountId,
            deviceId = draft.deviceId,
            secrets = draft.enrollmentPackage.secrets,
        )
    }

    /**
     * Resend a staged enrollment whose response was never seen.
     *
     * The bytes come from the journal, not from a rebuilt request: the server
     * decides replay by the exact bytes it fingerprinted, so anything else would
     * be a new enrollment for an account that already exists.
     */
    fun retryPendingEnrollment(secrets: SyncSecretBundle): SyncConnectionConfiguration {
        val pending = journal.pending()
            ?: throw SyncOnboardingException(SyncOnboardingException.Reason.NO_PENDING_ENROLLMENT)
        val identity = identityIn(pending.rawBody)
        return send(pending.enrollmentId, pending.rawBody, identity.first, identity.second, secrets)
    }

    private fun send(
        enrollmentId: String,
        rawBody: ByteArray,
        accountId: String,
        deviceId: String,
        secrets: SyncSecretBundle,
    ): SyncConnectionConfiguration {
        // No Authorization header: enrollment is what creates the device this
        // token would prove, so there is nothing to authenticate against yet.
        val request = Request.Builder()
            .url("$baseUrl/v1/enrollment/initialize")
            .header("Cache-Control", "no-cache")
            .post(rawBody.toRequestBody(JSON))
            .build()
        val response = transport.send(request)
        if (response.statusCode !in 200..299) {
            // The journal entry stays. A refusal the client can retry and a
            // refusal it cannot are the server's to distinguish, and dropping
            // the bytes here would lose the only idempotent retry available.
            throw SyncOnboardingException(
                SyncOnboardingException.Reason.ENROLLMENT_REJECTED,
                response.statusCode,
            )
        }

        // Only now. Secrets stored for an enrollment the server never accepted
        // would leave the device believing it is linked to nothing.
        if (!vault.save(secrets)) {
            throw SyncOnboardingException(SyncOnboardingException.Reason.STORAGE_FAILED)
        }
        val configuration = SyncConnectionConfiguration(
            baseUrl = baseUrl,
            accountId = accountId,
            deviceId = deviceId,
            // Connected, not synchronising. Turning sync on is a separate
            // decision the user makes later, and it is the one that reaches
            // real conversations.
            enabled = false,
            changesCursor = null,
        )
        if (!connectionStore.save(configuration)) {
            throw SyncOnboardingException(SyncOnboardingException.Reason.STORAGE_FAILED)
        }
        journal.acknowledge(enrollmentId)
        return configuration
    }

    /**
     * Read the account and device out of a staged body.
     *
     * A retry has no draft to read them from, and they must be the ones the
     * server will have recorded rather than whatever the caller believes.
     */
    private fun identityIn(body: ByteArray): Pair<String, String> = runCatching {
        val root = Json.parseToJsonElement(body.toString(Charsets.UTF_8)).jsonObject
        val accountId = root.getValue("account_id").jsonPrimitive.content
        val deviceId = root.getValue("device").jsonObject.getValue("device_id").jsonPrimitive.content
        accountId to deviceId
    }.getOrElse { throw SyncOnboardingException(SyncOnboardingException.Reason.MALFORMED_BODY) }

    private companion object {
        private val JSON = "application/json".toMediaType()
    }
}
