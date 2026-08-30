import Foundation

@main
struct SyncAccountTransitionStoreTests {
    static func main() throws {
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures += 1; print("FAIL \(message)") }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-transition-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let accounts = Set(SyncSecretSlot.allCases.flatMap {
            let pair = SyncSecretStore.keychainAccounts(for: $0)
            return [pair.master, pair.token]
        })
        check(accounts.count == 6, "three secret slots use six distinct Keychain accounts")

        let journal = SyncAccountTransitionJournal(fileURL: root.appendingPathComponent("transition.json"))
        let record = SyncAccountTransitionRecord(
            stage: .staged,
            oldAccountID: "AAAAAAAA-0000-4000-8000-00000000000A",
            newAccountID: "BBBBBBBB-0000-4000-8000-00000000000B",
            createdAtMilliseconds: 1_777_777_777_000
        )
        try journal.save(record)
        let loadedRecord = try journal.load()
        check(loadedRecord == record, "journal round-trips its closed non-secret shape")

        let journalBytes = try Data(contentsOf: root.appendingPathComponent("transition.json"))
        let journalText = String(decoding: journalBytes, as: UTF8.self)
        check(!journalText.contains("token"), "journal does not contain token fields")
        check(!journalText.contains("master"), "journal does not contain master-key fields")

        try Data("{\"version\":1,\"stage\":\"staged\",\"old_account_id\":\"AAAAAAAA-0000-4000-8000-00000000000A\",\"new_account_id\":\"BBBBBBBB-0000-4000-8000-00000000000B\",\"created_at_ms\":1,\"token\":\"forbidden\"}".utf8)
            .write(to: root.appendingPathComponent("transition.json"), options: .atomic)
        do {
            _ = try journal.load()
            check(false, "journal rejects unknown secret-bearing keys")
        } catch { check(true, "journal rejects unknown secret-bearing keys") }

        let files = SyncTransitionFiles(directoryURL: root.appendingPathComponent("files"))
        let active = Data("old-connection".utf8)
        let candidate = Data("new-connection".utf8)
        try files.writeActive(active, role: .connection)
        try files.stage(candidate, role: .connection)
        try files.prepareRollback()
        try files.promote()
        let promoted = try files.readActive(role: .connection)
        check(promoted == candidate, "promote activates staged bytes")
        try files.restore()
        let restored = try files.readActive(role: .connection)
        check(restored == active, "restore recovers exact old bytes")
        try files.discardTransient()
        check(!files.hasTransientFiles, "cleanup removes staging and rollback files")

        if failures > 0 { exit(1) }
        print("Sync account transition store tests passed (10)")
    }
}
