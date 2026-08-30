import Foundation

public struct SyncTransitionCandidate {
    public let connection: SyncConnectionConfiguration
    public let secrets: SyncSecretBundle
    public let replicaData: Data
    public let cursorData: Data

    public init(
        connection: SyncConnectionConfiguration,
        secrets: SyncSecretBundle,
        replicaData: Data,
        cursorData: Data
    ) {
        self.connection = connection
        self.secrets = secrets
        self.replicaData = replicaData
        self.cursorData = cursorData
    }
}

public enum SyncCommitBoundary: String, CaseIterable {
    case rollbackSecretSaved
    case rollbackFilesPrepared
    case journalCommitting
    case activeSecretPromoted
    case activeFilesPromoted
}

public enum SyncAccountTransitionState: Equatable {
    case idle
    case preparing
    case verifying
    case bootstrapping
    case readyToCommit
    case committing
    case completed
    case cancelled
    case recoverableError
    case manualRecoveryRequired
}

public enum SyncAccountTransitionError: Error, Equatable {
    case syncEnabled
    case outboxPending
    case alreadySameAccount
    case candidateUnverified
    case noActiveAccount
    case storageFailed
    case manualRecoveryRequired
}

public final class SyncAccountTransitionCoordinator {
    public private(set) var state: SyncAccountTransitionState = .idle

    private let vault: SyncSlottedSecretVault
    private let connectionStore: SyncConnectionStateStore
    private let files: SyncTransitionFiles
    private let journal: SyncAccountTransitionJournal
    private let outbox: SyncOutbox
    private let nowMilliseconds: () -> Int64
    private let afterBoundary: (SyncCommitBoundary) throws -> Void
    private var candidate: SyncTransitionCandidate?

    public init(
        vault: SyncSlottedSecretVault,
        connectionStore: SyncConnectionStateStore,
        files: SyncTransitionFiles,
        journal: SyncAccountTransitionJournal,
        outbox: SyncOutbox,
        nowMilliseconds: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        afterBoundary: @escaping (SyncCommitBoundary) throws -> Void = { _ in }
    ) {
        self.vault = vault
        self.connectionStore = connectionStore
        self.files = files
        self.journal = journal
        self.outbox = outbox
        self.nowMilliseconds = nowMilliseconds
        self.afterBoundary = afterBoundary
    }

    public func prepare(candidate: SyncTransitionCandidate) throws {
        let old = try activeDisabledConnection()
        guard old.accountID != candidate.connection.accountID else {
            throw SyncAccountTransitionError.alreadySameAccount
        }
        guard !candidate.connection.enabled else { throw SyncAccountTransitionError.syncEnabled }

        state = .preparing
        do {
            try vault.save(candidate.secrets, slot: .staging)
            try files.stage(connectionStore.encoded(candidate.connection), role: .connection)
            try files.stage(candidate.replicaData, role: .replica)
            try files.stage(candidate.cursorData, role: .cursor)
            try journal.save(SyncAccountTransitionRecord(
                stage: .staged,
                oldAccountID: old.accountID,
                newAccountID: candidate.connection.accountID,
                createdAtMilliseconds: nowMilliseconds()
            ))
            self.candidate = candidate
            state = .verifying
        } catch {
            try? cleanupTransient()
            state = .recoverableError
            throw SyncAccountTransitionError.storageFailed
        }
    }

    public func markBootstrapVerified() {
        guard state == .verifying || state == .bootstrapping else { return }
        state = .readyToCommit
    }

    public func commit() throws {
        guard state == .readyToCommit, let candidate else {
            throw SyncAccountTransitionError.candidateUnverified
        }
        let old = try activeDisabledConnection()
        guard case .available(let activeSecrets) = vault.load(slot: .active),
              case .available(let stagingSecrets) = vault.load(slot: .staging),
              stagingSecrets == candidate.secrets else {
            throw SyncAccountTransitionError.storageFailed
        }

        state = .committing
        do {
            try vault.save(activeSecrets, slot: .rollback)
            try afterBoundary(.rollbackSecretSaved)
            try files.prepareRollback()
            try afterBoundary(.rollbackFilesPrepared)
            try journal.save(SyncAccountTransitionRecord(
                stage: .committing,
                oldAccountID: old.accountID,
                newAccountID: candidate.connection.accountID,
                createdAtMilliseconds: nowMilliseconds()
            ))
            try afterBoundary(.journalCommitting)
            try vault.save(stagingSecrets, slot: .active)
            try afterBoundary(.activeSecretPromoted)
            try files.promote()
            try files.removeActive(role: .outbox)
            try afterBoundary(.activeFilesPromoted)

            guard connectionStore.load() == .available(candidate.connection),
                  candidate.connection.enabled == false,
                  vault.load(slot: .active) == .available(candidate.secrets) else {
                throw SyncAccountTransitionError.storageFailed
            }
            try cleanupTransient()
            self.candidate = nil
            state = .completed
        } catch {
            state = .recoverableError
            throw error
        }
    }

    public func cancel() throws {
        guard state != .committing else { throw SyncAccountTransitionError.storageFailed }
        try cleanupTransient()
        candidate = nil
        state = .cancelled
    }

    public func recoverIfNeeded() throws {
        guard let record = try journal.load() else {
            try cleanupTransient(removeJournal: false)
            state = .idle
            return
        }

        switch (record.operation, record.stage) {
        case (.switchAccount, .staged):
            try cleanupTransient()
            candidate = nil
            state = .idle
        case (.switchAccount, .committing):
            if activeMatches(accountID: record.newAccountID) {
                try cleanupTransient()
                candidate = nil
                state = .completed
            } else if case .available(let rollback) = vault.load(slot: .rollback) {
                do {
                    try vault.save(rollback, slot: .active)
                    try files.restore()
                    guard activeMatches(accountID: record.oldAccountID) else {
                        throw SyncAccountTransitionError.manualRecoveryRequired
                    }
                    try cleanupTransient()
                    candidate = nil
                    state = .idle
                } catch {
                    state = .manualRecoveryRequired
                    throw SyncAccountTransitionError.manualRecoveryRequired
                }
            } else {
                state = .manualRecoveryRequired
                throw SyncAccountTransitionError.manualRecoveryRequired
            }
        case (.unlink, .committing):
            if connectionStore.load() == .absent && vault.load(slot: .active) == .absent {
                try cleanupTransient()
                state = .completed
            } else if case .available(let rollback) = vault.load(slot: .rollback) {
                try vault.save(rollback, slot: .active)
                try files.restore()
                guard activeMatches(accountID: record.oldAccountID) else {
                    state = .manualRecoveryRequired
                    throw SyncAccountTransitionError.manualRecoveryRequired
                }
                try cleanupTransient()
                state = .idle
            } else {
                state = .manualRecoveryRequired
                throw SyncAccountTransitionError.manualRecoveryRequired
            }
        case (.unlink, .staged):
            try cleanupTransient()
            state = .idle
        }
    }

    public func unlink() throws {
        let old = try activeDisabledConnection()
        guard case .available(let activeSecrets) = vault.load(slot: .active) else {
            throw SyncAccountTransitionError.noActiveAccount
        }
        do {
            try vault.save(activeSecrets, slot: .rollback)
            try files.prepareRollback()
            try journal.save(SyncAccountTransitionRecord(
                stage: .committing,
                operation: .unlink,
                oldAccountID: old.accountID,
                newAccountID: nil,
                createdAtMilliseconds: nowMilliseconds()
            ))
            vault.remove(slot: .active)
            try files.removeAllActive()
            guard connectionStore.load() == .absent, vault.load(slot: .active) == .absent else {
                throw SyncAccountTransitionError.storageFailed
            }
            try cleanupTransient()
            state = .completed
        } catch {
            state = .recoverableError
            throw error
        }
    }

    private func activeDisabledConnection() throws -> SyncConnectionConfiguration {
        guard case .available(let connection) = connectionStore.load() else {
            throw SyncAccountTransitionError.noActiveAccount
        }
        guard !connection.enabled else { throw SyncAccountTransitionError.syncEnabled }
        guard try outbox.pending().isEmpty else { throw SyncAccountTransitionError.outboxPending }
        return connection
    }

    private func activeMatches(accountID: String?) -> Bool {
        guard let accountID,
              case .available(let connection) = connectionStore.load(),
              case .available = vault.load(slot: .active) else { return false }
        return connection.accountID == accountID && connection.enabled == false
    }

    private func cleanupTransient(removeJournal: Bool = true) throws {
        vault.remove(slot: .staging)
        vault.remove(slot: .rollback)
        try files.discardTransient()
        if removeJournal { try journal.remove() }
    }
}
