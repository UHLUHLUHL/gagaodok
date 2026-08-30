package com.sapiens.gagaodok.sync

/** Delivers one QR value per scanner session, even if adjacent frames repeat it. */
class SyncPairingScanGate(private val deliver: (String) -> Unit) {
    private var consumed = false

    @Synchronized fun offer(value: String?): Boolean {
        if (consumed || value.isNullOrEmpty()) return false
        consumed = true
        deliver(value)
        return true
    }

    @Synchronized fun reset() {
        consumed = false
    }
}
