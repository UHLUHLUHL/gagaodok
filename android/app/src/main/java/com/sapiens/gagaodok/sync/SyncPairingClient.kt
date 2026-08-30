package com.sapiens.gagaodok.sync

import java.util.Base64
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

/**
 * The four pairing calls, and nothing else.
 *
 * Two of them are authenticated as the host device and two are not: a joiner
 * has no token yet, which is the whole reason pairing exists. The token is read
 * per request rather than captured, for the same reason the pull client reads
 * it per request.
 */
class SyncPairingClient(
    baseUrl: String,
    private val token: () -> ByteArray?,
    private val transport: SyncHttpTransport = OkHttpSyncTransport(),
) {
    data class Claim(
        val claimId: String,
        val claimLookup: String,
        val claimEnvelope: String,
        val state: String,
    )

    data class Session(val sessionId: String, val expiresAt: String, val replayed: Boolean)

    /** The status alone. Server text could carry a lookup or an envelope. */
    class PairingClientException(val statusCode: Int? = null, val notAuthenticated: Boolean = false) : Exception()

    private val baseUrl = baseUrl.removeSuffix("/")

    init {
        require(this.baseUrl.startsWith("https://") && !this.baseUrl.contains('?') && !this.baseUrl.contains('#'))
    }

    // host

    fun createSession(sessionId: String, sessionLookup: ByteArray): Session {
        val result = send(
            "/v1/pairing/sessions",
            JSONObject()
                .put("protocol_version", 1)
                .put("session_id", sessionId)
                .put("pairing_session_lookup", wire(sessionLookup)),
            authenticated = true,
        )
        return Session(
            sessionId = result.getString("session_id"),
            expiresAt = result.getString("expires_at"),
            replayed = result.optString("status") == "replayed",
        )
    }

    fun listClaims(sessionId: String): List<Claim> {
        val result = send("/v1/pairing/sessions/$sessionId/claims", null, authenticated = true)
        val array: JSONArray = result.getJSONArray("claims")
        return (0 until array.length()).map { index ->
            val entry = array.getJSONObject(index)
            Claim(
                claimId = entry.getString("claim_id"),
                claimLookup = entry.getString("claim_lookup"),
                claimEnvelope = entry.getString("claim_envelope"),
                state = entry.getString("state"),
            )
        }
    }

    fun approve(
        sessionId: String,
        claimId: String,
        claimLookup: ByteArray,
        deliveryEnvelope: ByteArray,
        deviceId: String,
        spaceId: String,
        platform: String,
        deviceTokenHash: String,
    ) {
        send(
            "/v1/pairing/sessions/$sessionId/claims/$claimId/approve",
            JSONObject()
                .put("protocol_version", 1)
                .put("claim_lookup", wire(claimLookup))
                .put("delivery_envelope", wire(deliveryEnvelope))
                .put(
                    "device",
                    JSONObject()
                        .put("device_id", deviceId)
                        .put("space_id", spaceId)
                        .put("platform", platform)
                        .put("display_name", JSONObject.NULL)
                        .put("device_token_hash", deviceTokenHash),
                ),
            authenticated = true,
        )
    }

    // joiner

    fun submitClaim(
        sessionId: String,
        sessionLookup: ByteArray,
        claimId: String,
        claimLookup: ByteArray,
        claimEnvelope: ByteArray,
        redeemVerifier: String,
    ) {
        val result = send(
            "/v1/pairing/sessions/$sessionId/claims",
            JSONObject()
                .put("protocol_version", 1)
                .put("pairing_session_lookup", wire(sessionLookup))
                .put("claim_id", claimId)
                .put("claim_lookup", wire(claimLookup))
                .put("claim_envelope", wire(claimEnvelope))
                .put("claim_redeem_verifier", redeemVerifier),
            authenticated = false,
        )
        // Deliberately no ciphertext is expected here. At submit time the host
        // has not approved anything, so a response carrying a delivery package
        // would mean the server handed out a package nobody authorised.
        if (result.optString("status") != "submitted") throw PairingClientException()
    }

    /** Returns the delivery envelope. Only ever succeeds once per claim. */
    fun redeem(
        sessionId: String,
        claimId: String,
        claimLookup: ByteArray,
        redeemAuth: ByteArray,
    ): ByteArray {
        val result = send(
            "/v1/pairing/sessions/$sessionId/claims/$claimId/redeem",
            JSONObject()
                .put("protocol_version", 1)
                .put("claim_lookup", wire(claimLookup))
                .put("claim_redeem_auth", wire(redeemAuth)),
            authenticated = false,
        )
        return runCatching { Base64.getDecoder().decode(result.getString("delivery_envelope")) }
            .getOrElse { throw PairingClientException() }
    }

    private fun send(path: String, body: JSONObject?, authenticated: Boolean): JSONObject {
        val builder = Request.Builder().url(baseUrl + path).header("Cache-Control", "no-cache")
        if (authenticated) {
            // Refused here rather than sent unauthenticated.
            val deviceToken = token()
            if (deviceToken == null || deviceToken.size != 32) {
                throw PairingClientException(notAuthenticated = true)
            }
            builder.header(
                "Authorization",
                "Device gdt1_" + Base64.getUrlEncoder().withoutPadding().encodeToString(deviceToken),
            )
        }
        val request = if (body == null) {
            builder.get().build()
        } else {
            builder.post(body.toString().toByteArray().toRequestBody(JSON)).build()
        }

        val response = transport.send(request)
        if (response.statusCode !in 200..299) throw PairingClientException(response.statusCode)
        val root = runCatching { JSONObject(String(response.body, Charsets.UTF_8)) }
            .getOrElse { throw PairingClientException() }
        if (root.optInt("protocol_version", -1) != 1) throw PairingClientException()
        return root.optJSONObject("result") ?: throw PairingClientException()
    }

    private companion object {
        val JSON = "application/json".toMediaType()

        /**
         * Request bodies use padded standard Base64, which is what the Worker's
         * canonical-Base64 check accepts. The Authorization header is the one
         * place that uses unpadded Base64URL.
         */
        fun wire(value: ByteArray): String = Base64.getEncoder().encodeToString(value)
    }
}
