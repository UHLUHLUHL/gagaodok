package com.sapiens.gagaodok.sync

data class SyncTransitionCandidate(
    val connection: SyncConnectionConfiguration,
    val secrets: SyncSecretBundle,
    val replicaData: ByteArray,
    val cursorData: ByteArray,
)

enum class SyncCommitBoundary {
    ROLLBACK_SECRET_SAVED,
    ROLLBACK_FILES_PREPARED,
    JOURNAL_COMMITTING,
    ACTIVE_SECRET_PROMOTED,
    ACTIVE_FILES_PROMOTED,
}

enum class SyncAccountTransitionState {
    IDLE, PREPARING, VERIFYING, BOOTSTRAPPING, READY_TO_COMMIT, COMMITTING,
    COMPLETED, CANCELLED, RECOVERABLE_ERROR, MANUAL_RECOVERY_REQUIRED,
}

enum class SyncAccountTransitionError {
    SYNC_ENABLED, OUTBOX_PENDING, ALREADY_SAME_ACCOUNT, CANDIDATE_UNVERIFIED,
    NO_ACTIVE_ACCOUNT, STORAGE_FAILED, MANUAL_RECOVERY_REQUIRED,
}

class SyncAccountTransitionException(val reason: SyncAccountTransitionError) : Exception(reason.name)

class SyncAccountTransitionCoordinator(
    private val vault: SyncSlottedSecretVault,
    private val connectionStore: SyncConnectionStateStore,
    private val files: SyncTransitionFiles,
    private val journal: SyncAccountTransitionJournal,
    private val outbox: SyncOutbox,
    private val nowMilliseconds: () -> Long = { System.currentTimeMillis() },
    private val afterBoundary: (SyncCommitBoundary) -> Unit = {},
) {
    var state: SyncAccountTransitionState = SyncAccountTransitionState.IDLE
        private set
    private var candidate: SyncTransitionCandidate? = null

    fun prepare(candidate: SyncTransitionCandidate) {
        val old = activeDisabledConnection()
        if (old.accountId == candidate.connection.accountId) fail(SyncAccountTransitionError.ALREADY_SAME_ACCOUNT)
        if (candidate.connection.enabled) fail(SyncAccountTransitionError.SYNC_ENABLED)
        state = SyncAccountTransitionState.PREPARING
        try {
            if (!vault.save(candidate.secrets, SyncSecretSlot.STAGING)) fail(SyncAccountTransitionError.STORAGE_FAILED)
            files.stage(connectionStore.encoded(candidate.connection), SyncTransitionFileRole.CONNECTION)
            files.stage(candidate.replicaData, SyncTransitionFileRole.REPLICA)
            files.stage(candidate.cursorData, SyncTransitionFileRole.CURSOR)
            journal.save(
                SyncAccountTransitionRecord(
                    stage = SyncTransitionStage.STAGED,
                    oldAccountId = old.accountId,
                    newAccountId = candidate.connection.accountId,
                    createdAtMilliseconds = nowMilliseconds(),
                )
            )
            this.candidate = candidate
            state = SyncAccountTransitionState.VERIFYING
        } catch (error: SyncAccountTransitionException) {
            cleanupQuietly()
            state = SyncAccountTransitionState.RECOVERABLE_ERROR
            throw error
        } catch (_: Exception) {
            cleanupQuietly()
            state = SyncAccountTransitionState.RECOVERABLE_ERROR
            fail(SyncAccountTransitionError.STORAGE_FAILED)
        }
    }

    fun markBootstrapVerified() {
        if (state == SyncAccountTransitionState.VERIFYING || state == SyncAccountTransitionState.BOOTSTRAPPING) {
            state = SyncAccountTransitionState.READY_TO_COMMIT
        }
    }

    fun commit() {
        val selected = candidate ?: fail(SyncAccountTransitionError.CANDIDATE_UNVERIFIED)
        if (state != SyncAccountTransitionState.READY_TO_COMMIT) fail(SyncAccountTransitionError.CANDIDATE_UNVERIFIED)
        val old = activeDisabledConnection()
        val activeSecrets = (vault.load(SyncSecretSlot.ACTIVE) as? SyncSecretLoadResult.Available)?.secrets
            ?: fail(SyncAccountTransitionError.STORAGE_FAILED)
        val stagingSecrets = (vault.load(SyncSecretSlot.STAGING) as? SyncSecretLoadResult.Available)?.secrets
            ?: fail(SyncAccountTransitionError.STORAGE_FAILED)
        if (stagingSecrets != selected.secrets) fail(SyncAccountTransitionError.STORAGE_FAILED)

        state = SyncAccountTransitionState.COMMITTING
        try {
            if (!vault.save(activeSecrets, SyncSecretSlot.ROLLBACK)) fail(SyncAccountTransitionError.STORAGE_FAILED)
            afterBoundary(SyncCommitBoundary.ROLLBACK_SECRET_SAVED)
            files.prepareRollback()
            afterBoundary(SyncCommitBoundary.ROLLBACK_FILES_PREPARED)
            journal.save(
                SyncAccountTransitionRecord(
                    stage = SyncTransitionStage.COMMITTING,
                    oldAccountId = old.accountId,
                    newAccountId = selected.connection.accountId,
                    createdAtMilliseconds = nowMilliseconds(),
                )
            )
            afterBoundary(SyncCommitBoundary.JOURNAL_COMMITTING)
            if (!vault.save(stagingSecrets, SyncSecretSlot.ACTIVE)) fail(SyncAccountTransitionError.STORAGE_FAILED)
            afterBoundary(SyncCommitBoundary.ACTIVE_SECRET_PROMOTED)
            files.promote()
            if (!files.removeActive(SyncTransitionFileRole.OUTBOX)) fail(SyncAccountTransitionError.STORAGE_FAILED)
            afterBoundary(SyncCommitBoundary.ACTIVE_FILES_PROMOTED)
            if (
                connectionStore.load() != SyncConnectionLoadResult.Available(selected.connection) ||
                selected.connection.enabled ||
                vault.load(SyncSecretSlot.ACTIVE) != SyncSecretLoadResult.Available(selected.secrets)
            ) fail(SyncAccountTransitionError.STORAGE_FAILED)
            cleanupTransient()
            candidate = null
            state = SyncAccountTransitionState.COMPLETED
        } catch (error: Exception) {
            state = SyncAccountTransitionState.RECOVERABLE_ERROR
            throw error
        }
    }

    fun cancel() {
        if (state == SyncAccountTransitionState.COMMITTING) fail(SyncAccountTransitionError.STORAGE_FAILED)
        cleanupTransient()
        candidate = null
        state = SyncAccountTransitionState.CANCELLED
    }

    fun recoverIfNeeded() {
        val record = journal.load()
        if (record == null) {
            cleanupTransient(removeJournal = false)
            state = SyncAccountTransitionState.IDLE
            return
        }
        when (record.operation to record.stage) {
            SyncTransitionOperation.SWITCH_ACCOUNT to SyncTransitionStage.STAGED -> {
                cleanupTransient(); candidate = null; state = SyncAccountTransitionState.IDLE
            }
            SyncTransitionOperation.SWITCH_ACCOUNT to SyncTransitionStage.COMMITTING -> recoverSwitch(record)
            SyncTransitionOperation.UNLINK to SyncTransitionStage.COMMITTING -> recoverUnlink(record)
            SyncTransitionOperation.UNLINK to SyncTransitionStage.STAGED -> {
                cleanupTransient(); state = SyncAccountTransitionState.IDLE
            }
        }
    }

    fun unlink() {
        val old = activeDisabledConnection()
        val activeSecrets = (vault.load(SyncSecretSlot.ACTIVE) as? SyncSecretLoadResult.Available)?.secrets
            ?: fail(SyncAccountTransitionError.NO_ACTIVE_ACCOUNT)
        try {
            if (!vault.save(activeSecrets, SyncSecretSlot.ROLLBACK)) fail(SyncAccountTransitionError.STORAGE_FAILED)
            files.prepareRollback()
            journal.save(
                SyncAccountTransitionRecord(
                    stage = SyncTransitionStage.COMMITTING,
                    operation = SyncTransitionOperation.UNLINK,
                    oldAccountId = old.accountId,
                    createdAtMilliseconds = nowMilliseconds(),
                )
            )
            if (!vault.remove(SyncSecretSlot.ACTIVE)) fail(SyncAccountTransitionError.STORAGE_FAILED)
            files.removeAllActive()
            if (connectionStore.load() != SyncConnectionLoadResult.Absent || vault.load(SyncSecretSlot.ACTIVE) != SyncSecretLoadResult.Absent) {
                fail(SyncAccountTransitionError.STORAGE_FAILED)
            }
            cleanupTransient()
            state = SyncAccountTransitionState.COMPLETED
        } catch (error: Exception) {
            state = SyncAccountTransitionState.RECOVERABLE_ERROR
            throw error
        }
    }

    private fun recoverSwitch(record: SyncAccountTransitionRecord) {
        if (activeMatches(record.newAccountId)) {
            cleanupTransient(); candidate = null; state = SyncAccountTransitionState.COMPLETED; return
        }
        val rollback = (vault.load(SyncSecretSlot.ROLLBACK) as? SyncSecretLoadResult.Available)?.secrets
            ?: manualRecovery()
        try {
            if (!vault.save(rollback, SyncSecretSlot.ACTIVE)) manualRecovery()
            files.restore()
            if (!activeMatches(record.oldAccountId)) manualRecovery()
            cleanupTransient(); candidate = null; state = SyncAccountTransitionState.IDLE
        } catch (_: Exception) { manualRecovery() }
    }

    private fun recoverUnlink(record: SyncAccountTransitionRecord) {
        if (connectionStore.load() == SyncConnectionLoadResult.Absent && vault.load(SyncSecretSlot.ACTIVE) == SyncSecretLoadResult.Absent) {
            cleanupTransient(); state = SyncAccountTransitionState.COMPLETED; return
        }
        val rollback = (vault.load(SyncSecretSlot.ROLLBACK) as? SyncSecretLoadResult.Available)?.secrets
            ?: manualRecovery()
        try {
            if (!vault.save(rollback, SyncSecretSlot.ACTIVE)) manualRecovery()
            files.restore()
            if (!activeMatches(record.oldAccountId)) manualRecovery()
            cleanupTransient(); state = SyncAccountTransitionState.IDLE
        } catch (_: Exception) { manualRecovery() }
    }

    private fun activeDisabledConnection(): SyncConnectionConfiguration {
        val connection = (connectionStore.load() as? SyncConnectionLoadResult.Available)?.configuration
            ?: fail(SyncAccountTransitionError.NO_ACTIVE_ACCOUNT)
        if (connection.enabled) fail(SyncAccountTransitionError.SYNC_ENABLED)
        if (outbox.pending().isNotEmpty()) fail(SyncAccountTransitionError.OUTBOX_PENDING)
        return connection
    }

    private fun activeMatches(accountId: String?): Boolean {
        val connection = (connectionStore.load() as? SyncConnectionLoadResult.Available)?.configuration ?: return false
        return accountId != null && connection.accountId == accountId && !connection.enabled &&
            vault.load(SyncSecretSlot.ACTIVE) is SyncSecretLoadResult.Available
    }

    private fun cleanupTransient(removeJournal: Boolean = true) {
        if (!vault.remove(SyncSecretSlot.STAGING) || !vault.remove(SyncSecretSlot.ROLLBACK)) {
            fail(SyncAccountTransitionError.STORAGE_FAILED)
        }
        files.discardTransient()
        if (removeJournal && !journal.remove()) fail(SyncAccountTransitionError.STORAGE_FAILED)
    }

    private fun cleanupQuietly() {
        runCatching { cleanupTransient() }
    }

    private fun manualRecovery(): Nothing {
        state = SyncAccountTransitionState.MANUAL_RECOVERY_REQUIRED
        fail(SyncAccountTransitionError.MANUAL_RECOVERY_REQUIRED)
    }

    private fun fail(reason: SyncAccountTransitionError): Nothing = throw SyncAccountTransitionException(reason)
}
