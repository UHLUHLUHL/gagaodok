import CryptoKit
import Foundation

private struct Failure: Error { let message: String }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message: message) }
}

private let roomID = UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!

private func snapshot(origin: String) -> SyncRemoteRoomSnapshot {
    SyncRemoteRoomSnapshot(
        handle: SyncRoomHandle(originSpaceID: origin, roomID: roomID),
        title: "원격 방",
        writerSpaces: [origin],
        messages: [SyncRemoteBubble(
            writerSpaceID: origin,
            turnID: UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!,
            messageID: UUID(uuidString: "D0000000-0000-4000-8000-000000000001")!,
            bubbleOrder: 0, timestamp: "2026-08-31T00:00:00Z",
            sender: "상대", kind: "text", text: "합성 메시지"
        )],
        contentHash: "synthetic-hash"
    )
}

private func digest(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private func testPinsAllNineExposureCells() throws {
    let spaces = ["MAC_SPACE", "PHONE_SPACE", "TABLET_SPACE"]
    let visible = Set(["MAC_SPACE>PHONE_SPACE", "TABLET_SPACE>MAC_SPACE", "TABLET_SPACE>PHONE_SPACE"])
    for origin in spaces {
        for viewer in spaces {
            try check(
                SyncRoomExposurePolicy.isVisible(originSpaceID: origin, viewerSpaceID: viewer)
                    == visible.contains("\(origin)>\(viewer)"),
                "wrong exposure cell \(origin) -> \(viewer)"
            )
        }
    }
    try check(!SyncRoomExposurePolicy.isVisible(originSpaceID: "UNKNOWN", viewerSpaceID: "PHONE_SPACE"), "unknown origin fails closed")
    try check(!SyncRoomExposurePolicy.isVisible(originSpaceID: "MAC_SPACE", viewerSpaceID: "UNKNOWN"), "unknown viewer fails closed")
}

private func testCatalogRefreshAndOpenNeverTouchLocalConversationFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let list = root.appendingPathComponent("rooms_list.json")
    let messages = root.appendingPathComponent("room_\(roomID.uuidString)_messages.json")
    try Data("LOCAL-LIST".utf8).write(to: list)
    try Data("LOCAL-MESSAGES".utf8).write(to: messages)
    let before = try [digest(list), digest(messages)]

    let repository = SyncRemoteRoomRepository(rootDirectory: root)
    try repository.replace(snapshot(origin: "MAC_SPACE"))
    let catalog = SyncRemoteRoomCatalog(repository: repository, viewerSpaceID: "PHONE_SPACE")
    let visible = try catalog.refresh()
    let opened = try catalog.open(visible[0].handle)
    try check(visible.count == 1, "the policy-visible room is listed")
    try check(opened == visible[0], "opening reads the remote file")

    let after = try [digest(list), digest(messages)]
    try check(after == before, "refresh and open changed a local conversation file")
}

@main
private struct Runner {
    static func main() throws {
        try testPinsAllNineExposureCells()
        print("ok - all nine exposure cells")
        try testCatalogRefreshAndOpenNeverTouchLocalConversationFiles()
        print("ok - remote navigation leaves local files unchanged")
        print("2 room exposure policy tests passed")
    }
}
