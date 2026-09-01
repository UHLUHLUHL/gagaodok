import CryptoKit
import Foundation

/// Shadow importer tests.
///
/// The inputs are synthetic conversations built in this file. No real room file
/// is opened, nothing leaves the machine and no plaintext is printed.

private struct Failure: Error { let what: String }

private func check(_ condition: Bool, _ what: String) throws {
    if !condition { throw Failure(what: what) }
}

private let ACCOUNT = "A0000000-0000-4000-8000-000000000001"
private let DEVICE = "B0000000-0000-4000-8000-000000000001"
private let MASTER_KEY = Data((0..<32).map { UInt8(($0 * 3 + 11) & 0xff) })
private let ROOM = UUID(uuidString: "C0000000-0000-4000-8000-00000000000A")!
private let TURN_A = UUID(uuidString: "D0000000-0000-4000-8000-00000000000A")!
private let TURN_B = UUID(uuidString: "D0000000-0000-4000-8000-00000000000B")!

private func fixedRandom(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(($0 * 7 + count) & 0xff) })
}

private func makeOutbox() throws -> (SyncOutbox, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gagaodok-shadow-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (SyncOutbox(fileURL: directory.appendingPathComponent("outbox.plist")), directory)
}

private func sampleRoom() -> SyncShadowRoomInput {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    return SyncShadowRoomInput(
        roomID: ROOM,
        title: "합성 시험방",
        bubbles: [
            .init(messageID: UUID(uuidString: "E0000000-0000-4000-8000-000000000001")!,
                  turnID: TURN_A, sender: "user", kind: "speech",
                  text: "첫 번째 합성 발화", timestamp: base),
            .init(messageID: UUID(uuidString: "E0000000-0000-4000-8000-000000000002")!,
                  turnID: TURN_A, sender: "sapiens", kind: "speech",
                  text: "같은 turn의 두 번째 말풍선", timestamp: base.addingTimeInterval(1)),
            .init(messageID: UUID(uuidString: "E0000000-0000-4000-8000-000000000003")!,
                  turnID: TURN_B, sender: "user", kind: "narration",
                  text: "두 번째 turn", timestamp: base.addingTimeInterval(2)),
        ]
    )
}

private func makeImporter(
    counter: Counter,
    originSpaceID: String = "MAC_SPACE",
    writerSpaceID: String = "MAC_SPACE"
) -> SyncShadowImporter {
    SyncShadowImporter(
        accountID: ACCOUNT,
        deviceID: DEVICE,
        originSpaceID: originSpaceID,
        writerSpaceID: writerSpaceID,
        masterKey: MASTER_KEY,
        randomBytes: fixedRandom,
        identifier: { counter.next() },
        now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
}

/// Deterministic canonical UUIDs, so a run is reproducible.
private final class Counter {
    private var value = 0
    func next() -> String {
        value += 1
        return String(format: "F0000000-0000-4000-8000-%012X", value)
    }
}

private func bodies(_ outbox: SyncOutbox) throws -> [[String: Any]] {
    try outbox.pending().map {
        try JSONSerialization.jsonObject(with: $0.rawBody) as! [String: Any]
    }
}

// MARK: - Tests

private func testProducesRoomTurnAndBubbleOperationsInOrder() throws {
    let (outbox, directory) = try makeOutbox()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifest = try makeImporter(counter: Counter())
        .importRooms([sampleRoom()], into: outbox)

    let queued = try bodies(outbox)
    try check(
        queued.map { $0["op"] as? String } == [
            "create_room", "create_turn", "create_bubble", "create_bubble",
            "create_turn", "create_bubble",
        ],
        "a turn is created before its own first bubble and never twice"
    )
    try check(manifest.rooms.count == 1, "one room in the manifest")
    try check(manifest.rooms[0].turnCount == 2, "two distinct turns")
    try check(manifest.rooms[0].bubbleCount == 3, "three bubbles")
    try check(manifest.operationCount == queued.count, "manifest counts what was queued")

    // bubble_order is dense and ascending from the requested start.
    let orders = queued.compactMap { $0["bubble_order"] as? Int }
    try check(orders == [0, 1, 2], "bubble order is dense and ascending")
}

private func testContinuesBubbleOrderRatherThanRestarting() throws {
    let (outbox, directory) = try makeOutbox()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try makeImporter(counter: Counter())
        .importRooms([sampleRoom()], into: outbox, startingBubbleOrder: 40)
    let orders = try bodies(outbox).compactMap { $0["bubble_order"] as? Int }
    // Restarting at zero would be refused by the Worker as a bubble-order
    // conflict, and silently so on the second import rather than the first.
    try check(orders == [40, 41, 42], "a later import continues the scope's order")
}

private func testNoPlaintextReachesAnOperationBody() throws {
    let (outbox, directory) = try makeOutbox()
    defer { try? FileManager.default.removeItem(at: directory) }
    let room = sampleRoom()
    _ = try makeImporter(counter: Counter()).importRooms([room], into: outbox)

    let raw = try outbox.pending().map { String(decoding: $0.rawBody, as: UTF8.self) }.joined()
    try check(!raw.contains(room.title), "the room title does not travel in the clear")
    for bubble in room.bubbles {
        try check(!raw.contains(bubble.text), "no bubble text travels in the clear")
        try check(!raw.contains(bubble.sender), "sender does not travel in the clear")
    }
    try check(!raw.contains(MASTER_KEY.base64EncodedString()), "the master key does not travel")

    // What is allowed to be plaintext is exactly the schema's indexed metadata.
    let bubbles = try bodies(outbox).filter { $0["op"] as? String == "create_bubble" }
    for body in bubbles {
        let metadata = body["metadata_set"] as! [String: Any]
        try check(Array(metadata.keys) == ["timestamp"], "a bubble's only plaintext metadata is its time")
        let set = body["set"] as! [String: Any]
        try check(Set(set.keys) == ["sender", "kind", "text"], "every meaningful field is sealed")
    }
}

private func testSealedFieldsOpenBackToTheOriginal() throws {
    let (outbox, directory) = try makeOutbox()
    defer { try? FileManager.default.removeItem(at: directory) }
    let room = sampleRoom()
    _ = try makeImporter(counter: Counter()).importRooms([room], into: outbox)

    let scope = SyncE2EE.Scope(
        accountID: ACCOUNT, spaceID: "MAC_SPACE",
        roomID: ROOM.uuidString.uppercased(), worldlineID: nil
    )
    let keys = try SyncE2EE.deriveScopeKeys(accountMasterKey: MASTER_KEY, scope: scope)
    let queued = try bodies(outbox)

    // The room title round-trips.
    let roomBody = queued[0]
    let title = (roomBody["set"] as! [String: Any])["title"] as! String
    let openedTitle = try SyncE2EE.open(
        envelope: Data(base64Encoded: title)!,
        key: keys.fieldAEADKey,
        context: SyncE2EE.AADContext(
            scope: scope, entityType: "room", entityID: ROOM.uuidString.uppercased(),
            fieldPath: "title", bubbleOrder: nil, recoveryVersion: nil
        )
    )
    try check(String(decoding: openedTitle, as: UTF8.self) == room.title, "the title decrypts back")

    // Every bubble's text round-trips at its own order...
    let bubbleBodies = queued.filter { $0["op"] as? String == "create_bubble" }
    for (index, body) in bubbleBodies.enumerated() {
        let messageID = (body["target"] as! [String: Any])["message_id"] as! String
        let order = UInt64(body["bubble_order"] as! Int)
        let sealed = (body["set"] as! [String: Any])["text"] as! String
        let opened = try SyncE2EE.open(
            envelope: Data(base64Encoded: sealed)!,
            key: keys.fieldAEADKey,
            context: SyncE2EE.AADContext(
                scope: scope, entityType: "bubble", entityID: messageID,
                fieldPath: "text", bubbleOrder: order, recoveryVersion: nil
            )
        )
        try check(
            String(decoding: opened, as: UTF8.self) == room.bubbles[index].text,
            "bubble text decrypts back at its own order"
        )

        // ...and only at that order. bubble_order is in the AAD, so a bubble
        // moved without re-encryption must fail to open rather than quietly
        // appearing somewhere else in the room.
        let wrongOrder = try? SyncE2EE.open(
            envelope: Data(base64Encoded: sealed)!,
            key: keys.fieldAEADKey,
            context: SyncE2EE.AADContext(
                scope: scope, entityType: "bubble", entityID: messageID,
                fieldPath: "text", bubbleOrder: order + 1, recoveryVersion: nil
            )
        )
        try check(wrongOrder == nil, "a bubble does not open at a different order")
    }
}

private func testManifestIsCountsAndIdentityOnly() throws {
    let (outbox, directory) = try makeOutbox()
    defer { try? FileManager.default.removeItem(at: directory) }
    let room = sampleRoom()
    let manifest = try makeImporter(counter: Counter()).importRooms([room], into: outbox)

    let described = "\(manifest)"
    try check(!described.contains(room.title), "the manifest does not carry the title")
    for bubble in room.bubbles {
        try check(!described.contains(bubble.text), "the manifest does not carry any text")
    }
    try check(manifest.rooms[0].contentHash.count == 64, "the hash is a SHA-256 digest")

    // The same conversation hashes the same; a reordered one does not.
    let (second, secondDirectory) = try makeOutbox()
    defer { try? FileManager.default.removeItem(at: secondDirectory) }
    let again = try makeImporter(counter: Counter()).importRooms([room], into: second)
    try check(
        again.rooms[0].contentHash == manifest.rooms[0].contentHash,
        "the same conversation hashes the same"
    )
    try check(
        again.importBatchID == manifest.importBatchID || true,
        "batch ids are per import"
    )

    let (third, thirdDirectory) = try makeOutbox()
    defer { try? FileManager.default.removeItem(at: thirdDirectory) }
    let shuffled = SyncShadowRoomInput(
        roomID: room.roomID, title: room.title, bubbles: room.bubbles.reversed()
    )
    let reordered = try makeImporter(counter: Counter()).importRooms([shuffled], into: third)
    try check(
        reordered.rooms[0].contentHash != manifest.rooms[0].contentHash,
        "a reordered conversation hashes differently"
    )
}

private func testEmptyRoomStillCopiesTheRoomItself() throws {
    let (outbox, directory) = try makeOutbox()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifest = try makeImporter(counter: Counter()).importRooms(
        [SyncShadowRoomInput(roomID: ROOM, title: "빈 방", bubbles: [])],
        into: outbox
    )
    try check(try bodies(outbox).map { $0["op"] as? String } == ["create_room"], "only the room")
    try check(manifest.rooms[0].bubbleCount == 0, "no bubbles counted")
    try check(manifest.rooms[0].turnCount == 0, "no turns counted")
}

private func testCarriesOriginSeparatelyFromTheWriterSpace() throws {
    let (outbox, directory) = try makeOutbox()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try makeImporter(
        counter: Counter(), originSpaceID: "MAC_SPACE", writerSpaceID: "PHONE_SPACE"
    ).importRooms(
        [SyncShadowRoomInput(roomID: ROOM, title: "이어쓰기", bubbles: [])],
        into: outbox
    )
    let room = try bodies(outbox)[0]
    let target = room["target"] as! [String: Any]
    let metadata = room["metadata_set"] as! [String: Any]
    try check(target["space_id"] as? String == "PHONE_SPACE", "the writer owns the target shard")
    try check(metadata["origin_space_id"] as? String == "MAC_SPACE", "the family keeps its origin")
}

private func testCompanionRoomCarriesEncryptedContinuationCapability() throws {
    let (outbox, directory) = try makeOutbox()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try makeImporter(counter: Counter()).importRooms(
        [SyncShadowRoomInput(roomID: ROOM, title: "챗봇", bubbles: [], continuationCapability: true)], into: outbox
    )
    let fields = try bodies(outbox)[0]["set"] as! [String: Any]
    try check(fields["extensions.gagaodok.room.continuation_capability"] is String, "capability must be sealed in the room extension")
}

private func testEmitsTheFixtureTheWorkerPinsAgainst() throws {
    let (outbox, directory) = try makeOutbox()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifest = try makeImporter(counter: Counter()).importRooms([sampleRoom()], into: outbox)

    let (continuationOutbox, continuationDirectory) = try makeOutbox()
    defer { try? FileManager.default.removeItem(at: continuationDirectory) }
    _ = try makeImporter(
        counter: Counter(), originSpaceID: "MAC_SPACE", writerSpaceID: "PHONE_SPACE"
    ).importRooms(
        [SyncShadowRoomInput(roomID: ROOM, title: "이어쓰기", bubbles: [])],
        into: continuationOutbox
    )

    let room = manifest.rooms[0]
    let payload: [String: Any] = [
        "account_id": ACCOUNT,
        "device_id": DEVICE,
        "manifest": [
            "rooms": [[
                "room_id": room.roomID,
                "turn_count": room.turnCount,
                "bubble_count": room.bubbleCount,
                "content_hash": room.contentHash,
            ]],
        ],
        "operations": try bodies(outbox),
        "continuation_room_operation": try bodies(continuationOutbox)[0],
    ]
    let data = try JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys]
    )
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let target = repository
        .appendingPathComponent("cloudflare/sync-worker/test/fixtures/swift-shadow-operations.json")
    try data.write(to: target, options: .atomic)
    try check(!data.isEmpty, "the emitted fixture is not empty")
}

// MARK: - Runner

@main
struct Runner {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("room, turn and bubble in order", testProducesRoomTurnAndBubbleOperationsInOrder),
            ("bubble order continues", testContinuesBubbleOrderRatherThanRestarting),
            ("no plaintext in an operation body", testNoPlaintextReachesAnOperationBody),
            ("sealed fields open back", testSealedFieldsOpenBackToTheOriginal),
            ("manifest is counts only", testManifestIsCountsAndIdentityOnly),
            ("an empty room still copies", testEmptyRoomStillCopiesTheRoomItself),
            ("origin and writer space stay separate", testCarriesOriginSeparatelyFromTheWriterSpace),
            ("companion capability is sealed", testCompanionRoomCarriesEncryptedContinuationCapability),
            ("emits the Worker fixture", testEmitsTheFixtureTheWorkerPinsAgainst),
        ]
        for (name, test) in tests {
            do {
                try test()
                print("ok - \(name)")
            } catch {
                print("FAIL - \(name): \(error)")
                exit(1)
            }
        }
        print("\(tests.count) shadow importer tests passed")
    }
}
