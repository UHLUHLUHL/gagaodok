import Foundation

@main
enum SyncReplicaStoreTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("real-chat.json")
        let sourceBytes = Data("DO-NOT-TOUCH".utf8)
        try sourceBytes.write(to: source)

        let store = SyncReplicaStore(fileURL: root.appendingPathComponent("shadow.json"))
        let page = Data(#"[{"entity_type":"room","identity":{"space_id":"MAC_SPACE","room_id":"10000000-0000-4000-8000-000000000001"},"projection":{"title":"opaque","extensions":[{"key":"x.y.z","value":"unknown"}]}}]"#.utf8)
        try store.apply(itemsJSON: page)
        let first = try store.snapshot()
        precondition(first.count == 1)
        precondition(String(data: first[0].projectionJSON, encoding: .utf8)!.contains("unknown"))

        let updated = Data(#"[{"entity_type":"room","identity":{"room_id":"10000000-0000-4000-8000-000000000001","space_id":"MAC_SPACE"},"projection":{"title":"new"}}]"#.utf8)
        try store.apply(itemsJSON: updated)
        let second = try store.snapshot()
        precondition(second.count == 1)
        precondition(String(data: second[0].projectionJSON, encoding: .utf8)!.contains("new"))
        let sourceAfter = try Data(contentsOf: source)
        precondition(sourceAfter == sourceBytes)

        do { try store.apply(itemsJSON: Data(#"[{"entity_type":"unknown","identity":{},"projection":{}}]"#.utf8)); preconditionFailure() }
        catch SyncReplicaStoreError.invalidPage {}
        let afterRejection = try store.snapshot()
        precondition(afterRejection.count == 1)
        print("Sync replica store tests passed")
    }
}
