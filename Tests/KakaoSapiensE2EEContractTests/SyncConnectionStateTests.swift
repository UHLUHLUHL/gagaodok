import Foundation

@main
enum SyncConnectionStateTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("state.json")
        let store = SyncConnectionStateStore(fileURL: stateURL)
        precondition(store.load() == .absent)

        let config = try SyncConnectionConfiguration(
            baseURL: URL(string: "https://sync.example.test")!,
            accountID: "10000000-0000-4000-8000-000000000001",
            deviceID: "20000000-0000-4000-8000-000000000002",
            enabled: false,
            changesCursor: nil
        )
        try store.save(config)
        precondition(store.load() == .available(config))
        precondition(config.enabled == false)

        try Data("not-json".utf8).write(to: stateURL)
        precondition(store.load() == .relinkRequired)

        do {
            _ = try SyncConnectionConfiguration(
                baseURL: URL(string: "http://sync.example.test")!,
                accountID: config.accountID,
                deviceID: config.deviceID,
                enabled: true,
                changesCursor: nil
            )
            preconditionFailure("HTTP must be rejected")
        } catch SyncConnectionStateError.invalidConfiguration {}

        let journalURL = root.appendingPathComponent("enrollment.bin")
        let journal = SyncEnrollmentJournal(fileURL: journalURL)
        let body = Data("{\"account_id\":\"SYNTHETIC\"}".utf8)
        try journal.stage(enrollmentID: config.deviceID, rawBody: body)
        let pending = try journal.pending()
        precondition(pending?.rawBody == body)
        try journal.stage(enrollmentID: config.deviceID, rawBody: body)
        do {
            try journal.stage(enrollmentID: config.deviceID, rawBody: Data("different".utf8))
            preconditionFailure("replay mismatch must be rejected")
        } catch SyncConnectionStateError.replayMismatch {}
        try journal.acknowledge(enrollmentID: config.deviceID)
        let acknowledged = try journal.pending()
        precondition(acknowledged == nil)
        print("Sync connection state tests passed")
    }
}
