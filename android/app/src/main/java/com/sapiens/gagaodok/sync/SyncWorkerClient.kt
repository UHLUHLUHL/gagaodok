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
    deviceToken: ByteArray,
    private val transport: SyncHttpTransport = OkHttpSyncTransport(),
) {
    private val baseUrl = baseUrl.removeSuffix("/")
    private val authorization: String
    init {
        require(this.baseUrl.startsWith("https://") && !this.baseUrl.contains('?') && !this.baseUrl.contains('#'))
        require(deviceToken.size == 32)
        authorization = "Device gdt1_" + Base64.getUrlEncoder().withoutPadding().encodeToString(deviceToken)
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
    fun bootstrap(cursor: String? = null, limit: Int = 300): SyncHttpResponse {
        val suffix = cursor?.let { "&cursor=" + java.net.URLEncoder.encode(it, Charsets.UTF_8.name()) } ?: ""
        return get("/v1/sync/bootstrap?limit=$limit$suffix")
    }
    private fun get(path: String): SyncHttpResponse { val response=transport.send(request(path).get().build());if(response.statusCode !in 200..299)throw SyncWorkerClientException(response.statusCode);return response }
    private fun request(path: String)=Request.Builder().url(baseUrl+path).header("Authorization",authorization).header("Cache-Control","no-cache")
    companion object { private val JSON="application/json".toMediaType() }
}
