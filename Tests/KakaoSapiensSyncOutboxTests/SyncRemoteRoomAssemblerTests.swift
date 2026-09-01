import Foundation

private struct Failure: Error { let message: String }

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message: message) }
}

private let accountID = "A0000000-0000-4000-8000-000000000001"
private let roomID = "B0000000-0000-4000-8000-000000000001"
private let macTurn = "C0000000-0000-4000-8000-000000000001"
private let phoneTurn = "C0000000-0000-4000-8000-000000000002"
private let macMessage = "D0000000-0000-4000-8000-000000000001"
private let phoneMessage = "D0000000-0000-4000-8000-000000000002"
private let masterKey = Data((0..<32).map { UInt8($0 + 1) })

private func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func entry(_ type: String, identity: [String: Any], projection: [String: Any]) throws -> SyncReplicaEntry {
    SyncReplicaEntry(entityType: type, identityJSON: try json(identity), projectionJSON: try json(projection))
}

private func sealed(
    _ plaintext: String,
    space: String,
    entityType: String,
    entityID: String,
    field: String,
    order: UInt64? = nil
) throws -> String {
    let scope = SyncE2EE.Scope(accountID: accountID, spaceID: space, roomID: roomID, worldlineID: nil)
    let keys = try SyncE2EE.deriveScopeKeys(accountMasterKey: masterKey, scope: scope)
    let envelope = try SyncE2EE.seal(
        plaintext: Data(plaintext.utf8),
        key: keys.fieldAEADKey,
        nonce: Data((0..<12).map { UInt8($0 + field.utf8.count) }),
        context: SyncE2EE.AADContext(
            scope: scope, entityType: entityType, entityID: entityID,
            fieldPath: field, bubbleOrder: order, recoveryVersion: nil
        )
    )
    return envelope.base64EncodedString()
}

private func room(space: String, origin: String, title: String = "원격 방") throws -> SyncReplicaEntry {
    try entry(
        "room",
        identity: ["space_id": space, "room_id": roomID],
        projection: [
            "origin_space_id": origin,
            "title": sealed(title, space: space, entityType: "room", entityID: roomID, field: "title"),
        ]
    )
}

private func turn(space: String, id: String, tombstoned: Any = false) throws -> SyncReplicaEntry {
    try entry(
        "turn",
        identity: [
            "space_id": space, "room_id": roomID, "worldline_id": NSNull(), "turn_id": id,
        ],
        projection: ["is_tombstoned": tombstoned]
    )
}

private func bubble(
    space: String,
    turn: String,
    message: String,
    order: UInt64,
    timestamp: String,
    text: String,
    tombstoned: Any = false,
    corruptText: Bool = false
) throws -> SyncReplicaEntry {
    let encrypted = try sealed(text, space: space, entityType: "bubble", entityID: message, field: "text", order: order)
    return try entry(
        "bubble",
        identity: [
            "space_id": space, "room_id": roomID, "worldline_id": NSNull(),
            "turn_id": turn, "message_id": message,
        ],
        projection: [
            "bubble_order": order,
            "timestamp": timestamp,
            "is_tombstoned": tombstoned,
            "sender": sealed("나", space: space, entityType: "bubble", entityID: message, field: "sender", order: order),
            "kind": sealed("text", space: space, entityType: "bubble", entityID: message, field: "kind", order: order),
            "text": corruptText ? "AAAA" : encrypted,
        ]
    )
}

private func validFamily() throws -> [SyncReplicaEntry] {
    [
        try room(space: "MAC_SPACE", origin: "MAC_SPACE"),
        try room(space: "PHONE_SPACE", origin: "MAC_SPACE", title: "이어쓰기 shard"),
        try turn(space: "MAC_SPACE", id: macTurn),
        try bubble(
            space: "MAC_SPACE", turn: macTurn, message: macMessage, order: 0,
            timestamp: "2026-08-31T00:00:01Z", text: "먼저"
        ),
        try turn(space: "PHONE_SPACE", id: phoneTurn),
        try bubble(
            space: "PHONE_SPACE", turn: phoneTurn, message: phoneMessage, order: 0,
            timestamp: "2026-08-31T00:00:02Z", text: "나중"
        ),
    ]
}

private func assembler() -> SyncRemoteRoomAssembler {
    SyncRemoteRoomAssembler(accountID: accountID, registeredSpaceID: "PHONE_SPACE", masterKey: masterKey)
}

private func testUnionsWriterSpacesUnderOneOriginHandle() throws {
    let rooms = assembler().assemble(try validFamily())
    try check(rooms.count == 1, "one origin family should be visible")
    let room = rooms[0]
    try check(room.handle.originSpaceID == "MAC_SPACE", "origin is canonical")
    try check(room.writerSpaces == ["MAC_SPACE", "PHONE_SPACE"], "both writer shards are retained")
    try check(room.title == "원격 방", "the authoritative origin title wins")
    try check(room.messages.map(\.text) == ["먼저", "나중"], "both spaces form one conversation")
    try check(!room.contentHash.isEmpty, "a non-secret comparison hash is produced")
}

private func testRejectsConflictingOriginAndMissingAuthoritativeOrigin() throws {
    var conflicting = try validFamily()
    conflicting[1] = try room(space: "PHONE_SPACE", origin: "TABLET_SPACE")
    try check(assembler().assemble(conflicting).isEmpty, "conflicting origins must reject the family")

    let missingOrigin = try validFamily().filter {
        guard $0.entityType == "room",
              let identity = try? JSONSerialization.jsonObject(with: $0.identityJSON) as? [String: Any]
        else { return true }
        return identity["space_id"] as? String != "MAC_SPACE"
    }
    try check(assembler().assemble(missingOrigin).isEmpty, "a derived shard cannot stand in for the origin")
}

private func testRejectsOrphansAndMalformedTombstoneFields() throws {
    var orphan = try validFamily()
    orphan.removeAll { entry in
        guard entry.entityType == "turn",
              let identity = try? JSONSerialization.jsonObject(with: entry.identityJSON) as? [String: Any]
        else { return false }
        return identity["turn_id"] as? String == macTurn
    }
    try check(assembler().assemble(orphan).isEmpty, "an orphan bubble rejects the family")

    var missing = try validFamily()
    missing[2] = try entry(
        "turn",
        identity: ["space_id": "MAC_SPACE", "room_id": roomID, "worldline_id": NSNull(), "turn_id": macTurn],
        projection: [:]
    )
    try check(assembler().assemble(missing).isEmpty, "missing tombstone state cannot mean alive")
}

private func testExcludesTombstonedTurnsAndBubbles() throws {
    var turnDeleted = try validFamily()
    turnDeleted[2] = try turn(space: "MAC_SPACE", id: macTurn, tombstoned: true)
    let afterTurn = assembler().assemble(turnDeleted)
    try check(afterTurn.single?.messages.map(\.text) == ["나중"], "a deleted turn hides its bubbles")

    var bubbleDeleted = try validFamily()
    bubbleDeleted[3] = try bubble(
        space: "MAC_SPACE", turn: macTurn, message: macMessage, order: 0,
        timestamp: "2026-08-31T00:00:01Z", text: "먼저", tombstoned: true
    )
    let afterBubble = assembler().assemble(bubbleDeleted)
    try check(afterBubble.single?.messages.map(\.text) == ["나중"], "a deleted bubble stays deleted")
}

private func testRejectsDecryptFailureInsteadOfShowingAPartialRoom() throws {
    var rows = try validFamily()
    rows[3] = try bubble(
        space: "MAC_SPACE", turn: macTurn, message: macMessage, order: 0,
        timestamp: "2026-08-31T00:00:01Z", text: "먼저", corruptText: true
    )
    try check(assembler().assemble(rows).isEmpty, "one unreadable field rejects the whole family")
}

private func testSortsByTimestampThenSpaceThenOrder() throws {
    var rows = try validFamily()
    rows[3] = try bubble(
        space: "MAC_SPACE", turn: macTurn, message: macMessage, order: 2,
        timestamp: "2026-08-31T00:00:01Z", text: "mac-2"
    )
    rows[5] = try bubble(
        space: "PHONE_SPACE", turn: phoneTurn, message: phoneMessage, order: 0,
        timestamp: "2026-08-31T00:00:01Z", text: "phone-0"
    )
    rows.append(try bubble(
        space: "MAC_SPACE", turn: macTurn,
        message: "D0000000-0000-4000-8000-000000000003", order: 1,
        timestamp: "2026-08-31T00:00:01Z", text: "mac-1"
    ))
    let messages = assembler().assemble(rows).single?.messages ?? []
    try check(messages.map(\.text) == ["mac-1", "mac-2", "phone-0"], "the cross-space order is stable")
}

private func testRepositoryUsesOnlyItsOwnAtomicFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let localSentinel = root.appendingPathComponent("local-conversation.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("DO-NOT-TOUCH".utf8).write(to: localSentinel)
    let repository = SyncRemoteRoomRepository(rootDirectory: root)
    let snapshot = try checkSingle(assembler().assemble(try validFamily()))
    try repository.replace(snapshot)
    let loaded = try repository.load(snapshot.handle)
    let localBytes = try Data(contentsOf: localSentinel)
    try check(loaded == snapshot, "the snapshot round-trips")
    try check(localBytes == Data("DO-NOT-TOUCH".utf8), "local chat data is untouched")
    let expected = root.appendingPathComponent("sync/remote/rooms/MAC_SPACE/\(roomID).plist")
    try check(FileManager.default.fileExists(atPath: expected.path), "the canonical room path is used")
}

private func checkSingle(_ rooms: [SyncRemoteRoomSnapshot]) throws -> SyncRemoteRoomSnapshot {
    try check(rooms.count == 1, "expected one room")
    return rooms[0]
}

private extension Array {
    var single: Element? { count == 1 ? self[0] : nil }
}

@main
private struct Runner {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("unions writer spaces", testUnionsWriterSpacesUnderOneOriginHandle),
            ("rejects origin conflicts", testRejectsConflictingOriginAndMissingAuthoritativeOrigin),
            ("rejects malformed family", testRejectsOrphansAndMalformedTombstoneFields),
            ("excludes tombstones", testExcludesTombstonedTurnsAndBubbles),
            ("rejects decrypt failure", testRejectsDecryptFailureInsteadOfShowingAPartialRoom),
            ("sorts stably", testSortsByTimestampThenSpaceThenOrder),
            ("persists separately", testRepositoryUsesOnlyItsOwnAtomicFiles),
        ]
        for (name, test) in tests {
            do { try test(); print("ok - \(name)") }
            catch { fputs("not ok - \(name): \(error)\n", stderr); exit(1) }
        }
        print("\(tests.count) remote room assembler tests passed")
    }
}
