package com.sapiens.gagaodok.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncPairingScanGateTest {
    @Test fun `only the first non-empty QR value is delivered`() {
        val delivered = mutableListOf<String>()
        val gate = SyncPairingScanGate(delivered::add)

        assertFalse(gate.offer(null))
        assertFalse(gate.offer(""))
        assertTrue(gate.offer("R0RQMQ"))
        assertFalse(gate.offer("SECOND"))

        assertEquals(listOf("R0RQMQ"), delivered)
    }

    @Test fun `reset permits exactly one new QR value`() {
        val delivered = mutableListOf<String>()
        val gate = SyncPairingScanGate(delivered::add)
        gate.offer("FIRST")
        gate.reset()
        gate.offer("SECOND")
        gate.offer("THIRD")

        assertEquals(listOf("FIRST", "SECOND"), delivered)
    }
}
