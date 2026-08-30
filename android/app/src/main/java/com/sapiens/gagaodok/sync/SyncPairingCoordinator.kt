package com.sapiens.gagaodok.sync

import java.security.MessageDigest
import java.util.Base64
import org.json.JSONObject

/**
 * Joining an existing account, from both ends.
 *
 * Two roles that know different things. The host already holds the account
 * master key and decides whether to let a device in; the joiner holds nothing
 * and only builds its own device identity. The Worker between them is a
 * mailbox: the plaintext master key never passes through it, because what the
 * joiner receives is a package the host sealed under a key derived from the
 * `pairing_secret` that was handed over by screen.
 */
class SyncPairingException(val reason: Reason) : Exception() {
    enum class Reason {
        NOT_CONNECTED,
        SESSION_EXPIRED,
        /** The user has not confirmed the two screens show the same number. */
        SAS_NOT_CONFIRMED,
        REJECTED,
        STORAGE_FAILED,
        TRANSPORT,
    }
}

/** What the host learned about one waiting device. */
data class SyncPairingCandidate(
    val claimId: String,
    val claimLookup: ByteArray,
    /** The six digits the user compares against the joiner's screen. */
    val shortAuthenticationString: String,
    internal val deviceId: String,
    internal val spaceId: String,
    internal val platform: String,
    internal val claimSecret: ByteArray,
)

/** The host side: the device that is already in. */
class SyncPairingHostCoordinator(
    private val client: SyncPairingClient,
    private val secrets: () -> SyncSecretLoadResult,
    private val random: SyncRandomSource,
) {
    private var sessionId: String? = null
    private var pairingSecret: ByteArray? = null

    /**
     * Open a session and produce the payload to show. Only a device that is
     * actually connected may do this — an unconnected one has no master key to
     * hand over and would strand whoever scanned it.
     */
    fun openSession(accountId: String, baseUrl: String): SyncPairingPayload {
        if (secrets() !is SyncSecretLoadResult.Available) {
            throw SyncPairingException(SyncPairingException.Reason.NOT_CONNECTED)
        }
        val secret = random.bytes(32)
        val lookup = runCatching {
            SyncE2EE.derivePairingMaterial(secret, secret).pairingSessionLookup
        }.getOrElse { throw SyncPairingException(SyncPairingException.Reason.STORAGE_FAILED) }
        val session = uuid(random)

        runCatching { client.createSession(session, lookup) }
            .getOrElse { throw map(it) }

        sessionId = session
        pairingSecret = secret
        return SyncPairingPayload.create(baseUrl, accountId, session, secret)
    }

    /**
     * Read waiting claims and open each one. A claim this host cannot open is
     * not for this session and is dropped rather than shown.
     */
    fun pollCandidates(): List<SyncPairingCandidate> {
        val session = sessionId
        val secret = pairingSecret
        if (session == null || secret == null) {
            throw SyncPairingException(SyncPairingException.Reason.NOT_CONNECTED)
        }
        val claims = runCatching { client.listClaims(session) }.getOrElse { throw map(it) }

        return claims.mapNotNull { claim ->
            runCatching {
                if (claim.state != "submitted") return@runCatching null
                val lookup = Base64.getDecoder().decode(claim.claimLookup)
                val envelope = Base64.getDecoder().decode(claim.claimEnvelope)
                // The claim key comes from the pairing secret alone, so only a
                // host holding the secret it showed can read a submission.
                val claimKey = SyncE2EE.derivePairingMaterial(secret, secret).pairingClaimKey
                val plaintext = SyncE2EE.openPairing(
                    envelope, claimKey, session, claim.claimId, lookup,
                    SyncE2EE.PairingPayloadType.CLAIM,
                )
                val body = JSONObject(String(plaintext, Charsets.UTF_8))
                val claimSecret = Base64.getDecoder().decode(body.getString("claim_secret"))
                val material = SyncE2EE.derivePairingMaterial(secret, claimSecret)
                if (!material.claimLookup.contentEquals(lookup)) return@runCatching null
                SyncPairingCandidate(
                    claimId = claim.claimId,
                    claimLookup = lookup,
                    shortAuthenticationString = material.pairingSAS,
                    deviceId = body.getString("device_id"),
                    spaceId = body.getString("space_id"),
                    platform = body.getString("platform"),
                    claimSecret = claimSecret,
                )
            }.getOrNull()
        }
    }

    /**
     * Approve exactly one candidate, after the user says the numbers match.
     *
     * `sasConfirmed` is not a formality. Without a human comparing the two
     * screens, an attacker who relayed the QR could be the one waiting, and
     * approving would hand them the account master key.
     */
    fun approve(candidate: SyncPairingCandidate, sasConfirmed: Boolean) {
        if (!sasConfirmed) throw SyncPairingException(SyncPairingException.Reason.SAS_NOT_CONFIRMED)
        val session = sessionId
        val secret = pairingSecret
        if (session == null || secret == null) {
            throw SyncPairingException(SyncPairingException.Reason.NOT_CONNECTED)
        }
        val bundle = (secrets() as? SyncSecretLoadResult.Available)?.secrets
            ?: throw SyncPairingException(SyncPairingException.Reason.NOT_CONNECTED)

        val newToken = random.bytes(32)
        val envelope = runCatching {
            val material = SyncE2EE.derivePairingMaterial(secret, candidate.claimSecret)
            // No account id here: the joiner already read it from the payload it
            // scanned, and a second copy would be a second answer to one question.
            val delivery = JSONObject()
                .put("account_master_key", Base64.getEncoder().encodeToString(bundle.accountMasterKey))
                .put("device_token", Base64.getEncoder().encodeToString(newToken))
            SyncE2EE.sealPairing(
                delivery.toString().toByteArray(Charsets.UTF_8),
                material.pairingDeliveryKey,
                random.bytes(12),
                session,
                candidate.claimId,
                candidate.claimLookup,
                SyncE2EE.PairingPayloadType.DELIVERY,
            )
        }.getOrElse { throw SyncPairingException(SyncPairingException.Reason.STORAGE_FAILED) }

        // Only the hash goes to the Worker; the token itself travels sealed.
        val tokenHash = MessageDigest.getInstance("SHA-256").digest(newToken)
            .joinToString("") { "%02x".format(it) }
        runCatching {
            client.approve(
                sessionId = session,
                claimId = candidate.claimId,
                claimLookup = candidate.claimLookup,
                deliveryEnvelope = envelope,
                deviceId = candidate.deviceId,
                spaceId = candidate.spaceId,
                platform = candidate.platform,
                deviceTokenHash = tokenHash,
            )
        }.getOrElse { throw map(it) }
    }

    internal companion object {
        fun uuid(random: SyncRandomSource): String {
            val bytes = random.bytes(16)
            bytes[6] = ((bytes[6].toInt() and 0x0f) or 0x40).toByte()
            bytes[8] = ((bytes[8].toInt() and 0x3f) or 0x80).toByte()
            val hex = bytes.joinToString("") { "%02X".format(it) }
            return listOf(
                hex.substring(0, 8), hex.substring(8, 12), hex.substring(12, 16),
                hex.substring(16, 20), hex.substring(20, 32),
            ).joinToString("-")
        }

        fun map(error: Throwable): SyncPairingException = when {
            error is SyncPairingException -> error
            error is SyncPairingClient.PairingClientException && error.notAuthenticated ->
                SyncPairingException(SyncPairingException.Reason.NOT_CONNECTED)
            error is SyncPairingClient.PairingClientException &&
                (error.statusCode == 404 || error.statusCode == 410) ->
                SyncPairingException(SyncPairingException.Reason.SESSION_EXPIRED)
            error is SyncPairingClient.PairingClientException && error.statusCode != null ->
                SyncPairingException(SyncPairingException.Reason.REJECTED)
            else -> SyncPairingException(SyncPairingException.Reason.TRANSPORT)
        }
    }
}

data class SyncPairingRedeemedCandidate(
    val secrets: SyncSecretBundle,
    val connection: SyncConnectionConfiguration,
)

/** The joiner side: a device that belongs to no account yet. */
class SyncPairingJoinerCoordinator(
    private val random: SyncRandomSource,
    private val vault: SyncSecretVault,
    private val connectionStore: SyncConnectionStateStore,
) {
    data class Accepted(
        val payload: SyncPairingPayload,
        val claimId: String,
        val shortAuthenticationString: String,
    )

    private var payload: SyncPairingPayload? = null
    private var claimId: String? = null
    private var claimSecret: ByteArray? = null
    private var material: SyncE2EE.PairingMaterial? = null
    private var identity: Triple<String, String, String>? = null

    /** Accept a scanned payload and build this device's claim. Nothing is sent. */
    fun accept(text: String, deviceId: String, spaceId: String, platform: String): Accepted {
        val scanned = SyncPairingPayload.decode(text)
        val secret = random.bytes(32)
        val claim = SyncPairingHostCoordinator.uuid(random)
        val derived = runCatching {
            SyncE2EE.derivePairingMaterial(scanned.pairingSecret, secret)
        }.getOrElse { throw SyncPairingException(SyncPairingException.Reason.STORAGE_FAILED) }

        payload = scanned
        claimId = claim
        claimSecret = secret
        material = derived
        identity = Triple(deviceId, spaceId, platform)
        return Accepted(scanned, claim, derived.pairingSAS)
    }

    fun submit(client: SyncPairingClient) {
        val scanned = payload
        val claim = claimId
        val secret = claimSecret
        val derived = material
        val who = identity
        if (scanned == null || claim == null || secret == null || derived == null || who == null) {
            throw SyncPairingException(SyncPairingException.Reason.NOT_CONNECTED)
        }
        val prepared = runCatching {
            val body = JSONObject()
                .put("device_id", who.first)
                .put("space_id", who.second)
                .put("platform", who.third)
                .put("claim_secret", Base64.getEncoder().encodeToString(secret))
            val hostKey = SyncE2EE.derivePairingMaterial(
                scanned.pairingSecret, scanned.pairingSecret,
            ).pairingClaimKey
            val envelope = SyncE2EE.sealPairing(
                body.toString().toByteArray(Charsets.UTF_8),
                hostKey,
                random.bytes(12),
                scanned.sessionId,
                claim,
                derived.claimLookup,
                SyncE2EE.PairingPayloadType.CLAIM,
            )
            val verifier = SyncE2EE.claimRedeemVerifier(
                scanned.sessionId, claim, derived.claimLookup, derived.claimRedeemAuth,
            ).joinToString("") { "%02x".format(it) }
            envelope to verifier
        }.getOrElse { throw SyncPairingException(SyncPairingException.Reason.STORAGE_FAILED) }

        runCatching {
            client.submitClaim(
                sessionId = scanned.sessionId,
                sessionLookup = derived.pairingSessionLookup,
                claimId = claim,
                claimLookup = derived.claimLookup,
                claimEnvelope = prepared.first,
                redeemVerifier = prepared.second,
            )
        }.getOrElse { throw SyncPairingHostCoordinator.map(it) }
    }

    /**
     * Redeem once and store what came back.
     *
     * Nothing is written until the package opens and its contents check out. A
     * half-linked device — secrets without a connection, or the reverse — is a
     * state the user has no way to repair.
     */
    fun redeemCandidate(client: SyncPairingClient, sasConfirmed: Boolean): SyncPairingRedeemedCandidate {
        if (!sasConfirmed) throw SyncPairingException(SyncPairingException.Reason.SAS_NOT_CONFIRMED)
        val scanned = payload
        val claim = claimId
        val derived = material
        val who = identity
        if (scanned == null || claim == null || derived == null || who == null) {
            throw SyncPairingException(SyncPairingException.Reason.NOT_CONNECTED)
        }

        val envelope = runCatching {
            client.redeem(scanned.sessionId, claim, derived.claimLookup, derived.claimRedeemAuth)
        }.getOrElse { throw SyncPairingHostCoordinator.map(it) }

        val bundle = runCatching {
            val plaintext = SyncE2EE.openPairing(
                envelope, derived.pairingDeliveryKey, scanned.sessionId, claim,
                derived.claimLookup, SyncE2EE.PairingPayloadType.DELIVERY,
            )
            val body = JSONObject(String(plaintext, Charsets.UTF_8))
            SyncSecretBundle(
                Base64.getDecoder().decode(body.getString("account_master_key")),
                Base64.getDecoder().decode(body.getString("device_token")),
            )
        }.getOrElse { throw SyncPairingException(SyncPairingException.Reason.REJECTED) }

        return SyncPairingRedeemedCandidate(
            bundle,
            SyncConnectionConfiguration(
                baseUrl = scanned.baseUrl,
                accountId = scanned.accountId,
                deviceId = who.first,
                enabled = false,
                changesCursor = null,
            ),
        )
    }

    fun redeem(client: SyncPairingClient, sasConfirmed: Boolean) {
        val candidate = redeemCandidate(client, sasConfirmed)
        if (!vault.save(candidate.secrets)) throw SyncPairingException(SyncPairingException.Reason.STORAGE_FAILED)
        // The account is the host's, and synchronisation stays off: joining is
        // a connection, not a decision to start syncing.
        val saved = runCatching { connectionStore.save(candidate.connection) }.getOrDefault(false)
        if (!saved) throw SyncPairingException(SyncPairingException.Reason.STORAGE_FAILED)
    }
}
