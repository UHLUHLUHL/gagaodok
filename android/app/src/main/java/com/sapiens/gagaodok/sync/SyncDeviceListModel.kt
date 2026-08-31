package com.sapiens.gagaodok.sync

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import java.time.Instant

data class SyncAccountDevice(
    val id: String,
    val platform: String,
    val linkedAt: String,
    val isCurrent: Boolean,
) {
    val title: String get() = when (platform) {
        "macos" -> "Mac"
        "android_phone" -> "Android 폰"
        "android_tablet" -> "Android 태블릿"
        else -> "알 수 없는 기기"
    }
}

sealed interface SyncDeviceListState {
    data object Idle : SyncDeviceListState
    data object Loading : SyncDeviceListState
    data class Loaded(val devices: List<SyncAccountDevice>) : SyncDeviceListState
    data object Failed : SyncDeviceListState
}

class SyncDeviceListModel(private val client: SyncWorkerClient) {
    private val mutableState = MutableStateFlow<SyncDeviceListState>(SyncDeviceListState.Idle)
    val state: StateFlow<SyncDeviceListState> = mutableState.asStateFlow()

    fun load() {
        if (mutableState.value == SyncDeviceListState.Loading) return
        mutableState.value = SyncDeviceListState.Loading
        mutableState.value = runCatching { SyncDeviceListState.Loaded(parse(client.devices().body)) }
            .getOrElse { SyncDeviceListState.Failed }
    }

    private fun parse(body: ByteArray): List<SyncAccountDevice> {
        val rows = JSONObject(String(body, Charsets.UTF_8)).getJSONObject("result").getJSONArray("devices")
        return List(rows.length()) { index ->
            val row = rows.getJSONObject(index)
            val id = row.getString("device_id").also { require(it.isNotEmpty()) }
            val platform = row.getString("platform").also {
                require(it in setOf("macos", "android_phone", "android_tablet"))
            }
            val linkedAt = row.getString("linked_at").also { Instant.parse(it) }
            SyncAccountDevice(id, platform, linkedAt, row.getBoolean("is_current"))
        }
    }
}
