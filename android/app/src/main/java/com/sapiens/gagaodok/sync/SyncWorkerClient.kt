package com.sapiens.gagaodok.sync

import java.util.Base64
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

data class SyncHttpResponse(val statusCode: Int, val body: ByteArray)
fun interface SyncHttpTransport { fun send(request: Request): SyncHttpResponse }
class OkHttpSyncTransport(private val client: OkHttpClient = OkHttpClient()) : SyncHttpTransport {
    override fun send(request: Request): SyncHttpResponse = client.newCall(request).execute().use {
        SyncHttpResponse(it.code, it.body?.bytes() ?: ByteArray(0))
    }
}
class SyncWorkerClientException(val statusCode: Int? = null) : Exception()

class SyncWorkerClient(
    baseUrl: String,
    /**
     * Read afresh for every request rather than captured once.
     *
     * The settings screen builds its client before enrollment has stored
     * anything, so a token captured at construction would stay empty for the
     * rest of the app session and every read would be refused until a restart.
     */
    private val token: () -> ByteArray?,
    private val transport: SyncHttpTransport = OkHttpSyncTransport(),
) {
    private val baseUrl = baseUrl.removeSuffix("/")
    init {
        require(this.baseUrl.startsWith("https://") && !this.baseUrl.contains('?') && !this.baseUrl.contains('#'))
    }

    /** A client for a token that already exists and will not change. */
    constructor(
        baseUrl: String,
        deviceToken: ByteArray,
        transport: SyncHttpTransport = OkHttpSyncTransport(),
    ) : this(baseUrl, { deviceToken }, transport) {
        require(deviceToken.size == 32)
    }

    /**
     * Built per request from whatever is stored right now.
     *
     * A missing or wrong-sized token is refused here, before a request exists:
     * an unauthenticated request is never sent. The exception carries no
     * status and no value.
     */
    private fun authorization(): String {
        val deviceToken = token()
        if (deviceToken == null || deviceToken.size != 32) throw SyncWorkerClientException()
        return "Device gdt1_" + Base64.getUrlEncoder().withoutPadding().encodeToString(deviceToken)
    }

    @Synchronized fun drainOne(outbox: SyncOutbox): SyncHttpResponse? {
        val entry = outbox.pending().firstOrNull() ?: return null
        val request = request("/v1/sync/operations").post(entry.rawBody.toRequestBody(JSON)).build()
        val response = transport.send(request)
        if (response.statusCode !in 200..299) throw SyncWorkerClientException(response.statusCode)
        outbox.acknowledge(entry.operationId)
        return response
    }
    fun changes(after: Long, limit: Int = 300): SyncHttpResponse = get("/v1/sync/changes?after_seq=$after&limit=$limit")
    fun devices(): SyncHttpResponse = get("/v1/account/devices")
    fun bootstrap(cursor: String? = null, limit: Int = 300): SyncHttpResponse {
        val suffix = cursor?.let { "&cursor=" + java.net.URLEncoder.encode(it, Charsets.UTF_8.name()) } ?: ""
        return get("/v1/sync/bootstrap?limit=$limit$suffix")
    }
    fun putAttachmentContent(attachmentId: String, body: ByteArray): SyncHttpResponse = checked(
        transport.send(
            request("/v1/attachments/${canonicalAttachmentId(attachmentId)}/content")
                .put(body.toRequestBody(OCTET_STREAM)).build(),
        ),
    )

    /**
     * Body 없는 POST다.
     *
     * 예전에 body를 실었더니 원격 complete가 거부해 첨부가 ready가 되지 못했다.
     * local suite가 전부 통과하는 상태였는데도 그랬다.
     */
    fun completeAttachment(attachmentId: String): SyncHttpResponse = checked(
        transport.send(
            request("/v1/attachments/${canonicalAttachmentId(attachmentId)}/complete")
                .post(ByteArray(0).toRequestBody(null)).build(),
        ),
    )

    fun getAttachmentContent(attachmentId: String): SyncHttpResponse = checked(
        transport.send(
            request("/v1/attachments/${canonicalAttachmentId(attachmentId)}/content").get().build(),
        ),
    )

    /** Worker의 경로 매칭이 정규 대문자 UUID만 받는다. */
    private fun canonicalAttachmentId(value: String): String {
        require(value == java.util.UUID.fromString(value).toString().uppercase()) {
            "attachment id must be canonical"
        }
        return value
    }

    private fun checked(response: SyncHttpResponse): SyncHttpResponse {
        if (response.statusCode !in 200..299) throw SyncWorkerClientException(response.statusCode)
        return response
    }

    private fun get(path: String): SyncHttpResponse { val response=transport.send(request(path).get().build());if(response.statusCode !in 200..299)throw SyncWorkerClientException(response.statusCode);return response }
    private fun request(path: String)=Request.Builder().url(baseUrl+path).header("Authorization",authorization()).header("Cache-Control","no-cache")
    companion object {
        private val JSON = "application/json".toMediaType()
        private val OCTET_STREAM = "application/octet-stream".toMediaType()
    }
}
