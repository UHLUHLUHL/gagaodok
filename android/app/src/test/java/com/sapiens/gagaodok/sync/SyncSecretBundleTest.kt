package com.sapiens.gagaodok.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class SyncSecretBundleTest {
    @Test fun `requires exact 32 byte secrets`() {
        for (length in listOf(0, 16, 31, 33, 64)) {
            runCatching { SyncSecretBundle(ByteArray(length), ByteArray(32)) }
                .onSuccess { error("accepted master key length $length") }
            runCatching { SyncSecretBundle(ByteArray(32), ByteArray(length)) }
                .onSuccess { error("accepted token length $length") }
        }
    }

    @Test fun `uses byte content equality rather than array identity`() {
        val first = SyncSecretBundle(ByteArray(32) { it.toByte() }, ByteArray(32) { (it + 1).toByte() })
        val same = SyncSecretBundle(first.accountMasterKey.copyOf(), first.deviceToken.copyOf())
        val different = SyncSecretBundle(first.accountMasterKey.copyOf(), ByteArray(32))
        assertEquals(first, same)
        assertEquals(first.hashCode(), same.hashCode())
        assertNotEquals(first, different)
    }
}
