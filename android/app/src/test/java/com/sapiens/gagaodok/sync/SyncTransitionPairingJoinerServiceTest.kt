package com.sapiens.gagaodok.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class SyncTransitionPairingJoinerServiceTest {
    private val redeemed = SyncPairingRedeemedCandidate(
        SyncSecretBundle(ByteArray(32) { 1 }, ByteArray(32) { 2 }),
        SyncConnectionConfiguration(
            "https://sync.invalid", "BBBBBBBB-0000-4000-8000-00000000000B",
            "BBBBBBBB-0000-4000-8000-00000000000D", false, null,
        ),
    )
    private val transitionCandidate = SyncTransitionCandidate(
        redeemed.connection, redeemed.secrets, "replica".toByteArray(), "cursor".toByteArray(),
    )

    private class Pairing(private val candidate: SyncPairingRedeemedCandidate) : SyncPairingCandidateFlow {
        var accepted = 0
        var redeemed = 0
        override fun acceptAndSubmit(text: String, deviceId: String, spaceId: String, platform: String): String {
            accepted += 1
            return "842588"
        }
        override fun redeemCandidate(sasConfirmed: Boolean): SyncPairingRedeemedCandidate {
            check(sasConfirmed); redeemed += 1; return candidate
        }
    }

    private class Bootstrapper(
        private val candidate: SyncTransitionCandidate,
        private val failure: Throwable? = null,
    ) : SyncCandidateBootstraping {
        var calls = 0
        override fun bootstrap(redeemed: SyncPairingRedeemedCandidate): SyncTransitionCandidate {
            calls += 1
            failure?.let { throw it }
            return candidate
        }
    }

    private class Transition : SyncTransitionCommitting {
        val calls = mutableListOf<String>()
        override fun prepare(candidate: SyncTransitionCandidate) { calls += "prepare" }
        override fun markBootstrapVerified() { calls += "verified" }
        override fun commit() { calls += "commit" }
    }

    @Test fun `redeem bootstraps before staging and commits in order`() {
        val pairing = Pairing(redeemed)
        val bootstrap = Bootstrapper(transitionCandidate)
        val transition = Transition()
        val service = SyncTransitionPairingJoinerService(pairing, bootstrap, transition)

        assertEquals("842588", service.acceptAndSubmit("QR", "DEVICE", "PHONE_SPACE", "android_phone"))
        service.redeem(true)

        assertEquals(1, pairing.accepted)
        assertEquals(1, pairing.redeemed)
        assertEquals(1, bootstrap.calls)
        assertEquals(listOf("prepare", "verified", "commit"), transition.calls)
    }

    @Test fun `bootstrap failure never stages or commits candidate`() {
        val transition = Transition()
        val service = SyncTransitionPairingJoinerService(
            Pairing(redeemed), Bootstrapper(transitionCandidate, IllegalStateException("failed")), transition,
        )
        assertThrows(IllegalStateException::class.java) { service.redeem(true) }
        assertTrue(transition.calls.isEmpty())
        assertFalse(transition.calls.contains("commit"))
    }
}
