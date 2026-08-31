package com.sapiens.gagaodok.sync

import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncDeviceListModelTest {
    @Test fun `loads only after an explicit action and maps safe labels`() {
        val requests = mutableListOf<Request>()
        val body = """{"result":{"devices":[{"device_id":"B0000000-0000-4000-8000-000000000001","platform":"macos","linked_at":"2026-08-31T00:00:00Z","is_current":true},{"device_id":"B0000000-0000-4000-8000-000000000002","platform":"android_tablet","linked_at":"2026-08-31T00:01:00Z","is_current":false}]}}""".toByteArray()
        val model = SyncDeviceListModel(
            SyncWorkerClient("https://sync.invalid", ByteArray(32), SyncHttpTransport { request ->
                requests += request
                SyncHttpResponse(200, body)
            }),
        )

        assertEquals(SyncDeviceListState.Idle, model.state.value)
        assertTrue(requests.isEmpty())
        model.load()

        val devices = (model.state.value as SyncDeviceListState.Loaded).devices
        assertEquals(listOf("Mac", "Android 태블릿"), devices.map { it.title })
        assertTrue(devices.first().isCurrent)
        assertEquals(1, requests.size)
    }

    @Test fun `malformed server rows fail closed`() {
        val body = """{"result":{"devices":[{"device_id":"x","platform":"unknown","linked_at":"secret","is_current":false}]}}""".toByteArray()
        val model = SyncDeviceListModel(
            SyncWorkerClient("https://sync.invalid", ByteArray(32), SyncHttpTransport { SyncHttpResponse(200, body) }),
        )
        model.load()
        assertEquals(SyncDeviceListState.Failed, model.state.value)
    }
}
