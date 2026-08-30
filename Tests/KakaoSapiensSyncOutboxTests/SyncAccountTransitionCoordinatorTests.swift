import Foundation

private final class SlotVault: SyncSlottedSecretVault {
    var values: [SyncSecretSlot: SyncSecretBundle] = [:]
    func load(slot: SyncSecretSlot) -> SyncSecretLoadResult {
        values[slot].map(SyncSecretLoadResult.available) ?? .absent
    }
    func save(_ bundle: SyncSecretBundle, slot: SyncSecretSlot) throws { values[slot] = bundle }
    func remove(slot: SyncSecretSlot) { values.removeValue(forKey: slot) }
}

private struct ForcedBoundaryFailure: Error {}

private final class TransitionHarness {
    let root: URL
    let vault = SlotVault()
    let files: SyncTransitionFiles
    let journal: SyncAccountTransitionJournal
    let connection: SyncConnectionStateStore
    let outbox: SyncOutbox
    let oldSecrets = try! SyncSecretBundle(accountMasterKey: Data(repeating: 1, count: 32), deviceToken: Data(repeating: 2, count: 32))
    let newSecrets = try! SyncSecretBundle(accountMasterKey: Data(repeating: 3, count: 32), deviceToken: Data(repeating: 4, count: 32))
    let oldConnection: SyncConnectionConfiguration
    let newConnection: SyncConnectionConfiguration
    let conversationURL: URL

    init(enabled: Bool = false, pending: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-transition-coordinator-\(UUID().uuidString)")
        let sync = root.appendingPathComponent("sync")
        files = SyncTransitionFiles(directoryURL: sync)
        journal = SyncAccountTransitionJournal(fileURL: sync.appendingPathComponent("transition.json"))
        connection = SyncConnectionStateStore(fileURL: sync.appendingPathComponent("connection.json"))
        outbox = SyncOutbox(fileURL: sync.appendingPathComponent("outbox.plist"))
        conversationURL = root.appendingPathComponent("conversation-sentinel.bin")
        oldConnection = try SyncConnectionConfiguration(
            baseURL: URL(string: "https://sync.invalid")!,
            accountID: "AAAAAAAA-0000-4000-8000-00000000000A",
            deviceID: "AAAAAAAA-0000-4000-8000-00000000000D",
            enabled: enabled,
            changesCursor: "old-cursor"
        )
        newConnection = try SyncConnectionConfiguration(
            baseURL: URL(string: "https://sync.invalid")!,
            accountID: "BBBBBBBB-0000-4000-8000-00000000000B",
            deviceID: "BBBBBBBB-0000-4000-8000-00000000000D",
            enabled: false,
            changesCursor: nil
        )
        try connection.save(oldConnection)
        try files.writeActive(Data("old-replica".utf8), role: .replica)
        try files.writeActive(Data("old-cursor".utf8), role: .cursor)
        try Data("LOCAL-CONVERSATION-UNCHANGED".utf8).write(to: conversationURL)
        try vault.save(oldSecrets, slot: .active)
        if pending {
            try outbox.enqueue(
                operationID: "CCCCCCCC-0000-4000-8000-00000000000C",
                rawBody: Data("{\"opaque\":true}".utf8)
            )
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var candidate: SyncTransitionCandidate {
        SyncTransitionCandidate(
            connection: newConnection,
            secrets: newSecrets,
            replicaData: Data("new-replica".utf8),
            cursorData: Data("new-cursor".utf8)
        )
    }

    func coordinator(failAt: SyncCommitBoundary? = nil) -> SyncAccountTransitionCoordinator {
        SyncAccountTransitionCoordinator(
            vault: vault,
            connectionStore: connection,
            files: files,
            journal: journal,
            outbox: outbox,
            nowMilliseconds: { 1_777_777_777_000 },
            afterBoundary: { boundary in if boundary == failAt { throw ForcedBoundaryFailure() } }
        )
    }
}

@main
struct SyncAccountTransitionCoordinatorTests {
    static func main() throws {
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures += 1; print("FAIL \(message)") }
        }

        do {
            let h = try TransitionHarness(enabled: true)
            do { try h.coordinator().prepare(candidate: h.candidate); check(false, "enabled sync blocks transition") }
            catch { check(error as? SyncAccountTransitionError == .syncEnabled, "enabled sync blocks transition") }
        }
        do {
            let h = try TransitionHarness(pending: true)
            do { try h.coordinator().prepare(candidate: h.candidate); check(false, "pending outbox blocks transition") }
            catch { check(error as? SyncAccountTransitionError == .outboxPending, "pending outbox blocks transition") }
        }

        for boundary in SyncCommitBoundary.allCases {
            let h = try TransitionHarness()
            let beforeConversation = try Data(contentsOf: h.conversationURL)
            let coordinator = h.coordinator(failAt: boundary)
            try coordinator.prepare(candidate: h.candidate)
            coordinator.markBootstrapVerified()
            do { try coordinator.commit(); check(false, "\(boundary) injects a commit failure") }
            catch { check(true, "\(boundary) injects a commit failure") }
            try coordinator.recoverIfNeeded()

            let loaded = h.connection.load()
            let activeSecrets = h.vault.load(slot: .active)
            let oldComplete = loaded == .available(h.oldConnection) && activeSecrets == .available(h.oldSecrets)
            let newComplete = loaded == .available(h.newConnection) && activeSecrets == .available(h.newSecrets)
            check(oldComplete != newComplete, "\(boundary) recovers exactly one complete account")
            check(!h.files.hasTransientFiles, "\(boundary) removes transient files")
            check(h.vault.load(slot: .staging) == .absent, "\(boundary) removes staging secret")
            check(h.vault.load(slot: .rollback) == .absent, "\(boundary) removes rollback secret")
            let afterConversation = try Data(contentsOf: h.conversationURL)
            check(afterConversation == beforeConversation, "\(boundary) preserves local conversation bytes")
        }

        do {
            let h = try TransitionHarness()
            let coordinator = h.coordinator()
            try coordinator.prepare(candidate: h.candidate)
            coordinator.markBootstrapVerified()
            try coordinator.commit()
            check(h.connection.load() == .available(h.newConnection), "successful commit activates candidate connection")
            check(h.vault.load(slot: .active) == .available(h.newSecrets), "successful commit activates candidate secrets")
            check(coordinator.state == .completed, "successful commit completes")
        }

        do {
            let h = try TransitionHarness()
            let before = try Data(contentsOf: h.conversationURL)
            try h.coordinator().unlink()
            check(h.connection.load() == .absent, "unlink removes sync connection")
            check(h.vault.load(slot: .active) == .absent, "unlink removes active secrets")
            let after = try Data(contentsOf: h.conversationURL)
            check(after == before, "unlink preserves local conversation bytes")
        }

        if failures > 0 { exit(1) }
        print("Sync account transition coordinator tests passed")
    }
}
