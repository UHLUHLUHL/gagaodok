package com.sapiens.gagaodok.sync

import java.io.File

interface SyncPairingCandidateFlow {
    fun acceptAndSubmit(text: String, deviceId: String, spaceId: String, platform: String): String
    fun redeemCandidate(sasConfirmed: Boolean): SyncPairingRedeemedCandidate
}

class DefaultSyncPairingCandidateFlow(
    private val coordinator: SyncPairingJoinerCoordinator,
    private val client: SyncPairingClient,
) : SyncPairingCandidateFlow {
    override fun acceptAndSubmit(text: String, deviceId: String, spaceId: String, platform: String): String {
        val accepted = coordinator.accept(text, deviceId, spaceId, platform)
        coordinator.submit(client)
        return accepted.shortAuthenticationString
    }

    override fun redeemCandidate(sasConfirmed: Boolean): SyncPairingRedeemedCandidate =
        coordinator.redeemCandidate(client, sasConfirmed)
}

interface SyncCandidateBootstraping {
    fun bootstrap(redeemed: SyncPairingRedeemedCandidate): SyncTransitionCandidate
}

class SyncCandidateBootstrapper(
    private val root: File,
    private val transport: SyncHttpTransport,
) : SyncCandidateBootstraping {
    override fun bootstrap(redeemed: SyncPairingRedeemedCandidate): SyncTransitionCandidate {
        val directory = File(root, "transition-bootstrap")
        directory.deleteRecursively()
        directory.mkdirs()
        return try {
            val replicaFile = File(directory, "replica.json")
            val cursorFile = File(directory, "pull.json")
            val client = SyncWorkerClient(
                redeemed.connection.baseUrl,
                { redeemed.secrets.deviceToken },
                transport,
            )
            val pull = SyncPullCoordinator(client, SyncReplicaStore(replicaFile), cursorFile)
            var pages = 0
            while (!pull.progress().bootstrapComplete) {
                if (pages++ >= MAX_BOOTSTRAP_PAGES) throw SyncPullException(SyncPullException.Reason.MALFORMED_ENVELOPE)
                pull.advanceBootstrap()
            }
            SyncTransitionCandidate(
                connection = redeemed.connection,
                secrets = redeemed.secrets,
                replicaData = replicaFile.readBytes(),
                cursorData = cursorFile.readBytes(),
            )
        } finally {
            directory.deleteRecursively()
        }
    }

    private companion object { const val MAX_BOOTSTRAP_PAGES = 10_000 }
}

class SyncTransitionPairingJoinerService(
    private val pairing: SyncPairingCandidateFlow,
    private val bootstrapper: SyncCandidateBootstraping,
    private val transition: SyncTransitionCommitting,
) : SyncPairingJoinerServicing {
    override fun acceptAndSubmit(text: String, deviceId: String, spaceId: String, platform: String): String =
        pairing.acceptAndSubmit(text, deviceId, spaceId, platform)

    override fun redeem(sasConfirmed: Boolean) {
        val redeemed = pairing.redeemCandidate(sasConfirmed)
        val candidate = bootstrapper.bootstrap(redeemed)
        transition.prepare(candidate)
        transition.markBootstrapVerified()
        transition.commit()
    }
}
