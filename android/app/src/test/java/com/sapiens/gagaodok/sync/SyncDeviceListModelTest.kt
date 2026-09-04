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

    private val twoDevices = """{"result":{"devices":[{"device_id":"B0000000-0000-4000-8000-000000000001","platform":"macos","linked_at":"2026-08-31T00:00:00Z","is_current":true},{"device_id":"B0000000-0000-4000-8000-000000000002","platform":"android_tablet","linked_at":"2026-08-31T00:01:00Z","is_current":false}]}}"""

    private fun modelOver(
        requests: MutableList<Request>,
        respond: (Request) -> SyncHttpResponse,
    ) = SyncDeviceListModel(
        SyncWorkerClient("https://sync.invalid", ByteArray(32), SyncHttpTransport { request ->
            requests += request
            respond(request)
        }),
    )

    @Test fun `revoking asks first and then calls the account endpoint`() {
        val requests = mutableListOf<Request>()
        val model = modelOver(requests) { SyncHttpResponse(200, twoDevices.toByteArray()) }
        model.load()
        val tablet = (model.state.value as SyncDeviceListState.Loaded).devices.last()

        model.requestRevoke(tablet)
        // Nothing has left the device yet: asking is not doing.
        assertEquals(1, requests.size)
        assertEquals(tablet, model.pendingRevoke.value)

        model.confirmRevoke()
        assertEquals(null, model.pendingRevoke.value)
        assertTrue(requests.any { it.method == "POST" && it.url.encodedPath == "/v1/account/devices/${tablet.id}/revoke" })
        // The list is read back rather than edited locally.
        assertTrue(requests.count { it.method == "GET" } >= 2)
    }

    /**
     * Revoking is a server-side act. Doing it to this device would leave it
     * holding keys the account no longer honours — the half-linked state the
     * tablet hit on 2026-09-04. Leaving locally is a different button.
     */
    @Test fun `the current device is never offered for removal`() {
        val requests = mutableListOf<Request>()
        val model = modelOver(requests) { SyncHttpResponse(200, twoDevices.toByteArray()) }
        model.load()
        val current = (model.state.value as SyncDeviceListState.Loaded).devices.first()

        assertEquals(false, model.canRevoke(current))
        model.requestRevoke(current)
        assertEquals(null, model.pendingRevoke.value)
        model.confirmRevoke()
        assertEquals(1, requests.size)
    }

    @Test fun `a refused revoke says so and leaves the list alone`() {
        val requests = mutableListOf<Request>()
        val model = modelOver(requests) { request ->
            if (request.method == "POST") SyncHttpResponse(409, ByteArray(0))
            else SyncHttpResponse(200, twoDevices.toByteArray())
        }
        model.load()
        val before = (model.state.value as SyncDeviceListState.Loaded).devices
        model.requestRevoke(before.last())
        model.confirmRevoke()

        assertTrue(model.revokeFailed.value)
        assertEquals(before, (model.state.value as SyncDeviceListState.Loaded).devices)
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
