import Foundation

/// Shadow upload tests.
///
/// The "local storage" is a synthetic directory written by this file, the
/// transport is a double, and no real room file or network is touched.

private struct Failure: Error { let what: String }

private func check(_ condition: Bool, _ what: String) throws {
    if !condition { throw Failure(what: what) }
}

private let ACCOUNT = "A0000000-0000-4000-8000-000000000001"
private let DEVICE = "B0000000-0000-4000-8000-000000000001"
private let MASTER_KEY = Data((0..<32).map { UInt8(($0 * 3 + 11) & 0xff) })
private let TOKEN = Data((0..<32).map { UInt8(($0 * 5 + 29) & 0xff) })
private let ROOM = UUID(uuidString: "C0000000-0000-4000-8000-00000000000A")!

private func secrets() -> SyncSecretLoadResult {
    .available(try! SyncSecretBundle(accountMasterKey: MASTER_KEY, deviceToken: TOKEN))
}

/// Accepts every upload, then answers `/v1/sync/changes` from what it accepted.
private final class ProjectingTransport: SyncHTTPTransport {
    private(set) var uploads: [[String: Any]] = []
    var dropBubbles = 0
    var uploadStatus = 200

    func send(_ request: URLRequest) async throws -> SyncHTTPResponse {
        let path = request.url?.path ?? ""
        if path == "/v1/sync/operations" {
            if uploadStatus != 200 { return SyncHTTPResponse(statusCode: uploadStatus, body: Data("{}".utf8)) }
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                uploads.append(json)
            }
            return SyncHTTPResponse(statusCode: 200, body: Data(#"{"result":{"status":"applied"}}"#.utf8))
        }
        // The change feed, built from what was accepted — minus any rows this
        // run is pretending the server never stored.
        var changes: [[String: Any]] = []
        var droppedRemaining = dropBubbles
        for (index, upload) in uploads.enumerated() {
            let entity = upload["entity_type"] as? String ?? ""
            if entity == "bubble", droppedRemaining > 0 { droppedRemaining -= 1; continue }
            guard let target = upload["target"] as? [String: Any] else { continue }
            var identity: [String: Any] = ["room_id": target["room_id"] ?? ""]
            if let turn = target["turn_id"] { identity["turn_id"] = turn }
            if let message = target["message_id"] { identity["message_id"] = message }
            changes.append([
                "change_seq": index + 1,
                "entity_type": entity,
                "change_kind": "create",
                "identity": identity,
                "projection": [:],
            ])
        }
        let body: [String: Any] = [
            "protocol_version": 1,
            "result": ["changes": changes, "has_more": false,
                       "scanned_through_seq": changes.count,
                       "account_high_watermark_seq": changes.count],
        ]
        return SyncHTTPResponse(
            statusCode: 200,
            body: try! JSONSerialization.data(withJSONObject: body)
        )
    }
}

private func writeStorage(
    bubbleCount: Int,
    turnsOf: (Int) -> Int,
    withAttachmentAt: Set<Int> = [],
    malformedAt: Set<Int> = []
) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gagaodok-shadow-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let rooms: [[String: Any]] = [[
        "id": ROOM.uuidString, "title": "테스트2",
        "createdAt": 1_800_000_000.0, "isPinned": false, "unreadCount": 0,
        "lastMessageText": "마지막", "lastMessageTime": 1_800_000_000.0,
    ]]
    try JSONSerialization.data(withJSONObject: rooms)
        .write(to: directory.appendingPathComponent("rooms_list.json"))

    var messages: [[String: Any]] = []
    for index in 0..<bubbleCount {
        if malformedAt.contains(index) {
            // A row with no id at all: the importer must leave it behind
            // rather than invent one.
            messages.append(["sender": "user", "text": "깨진 행"])
            continue
        }
        var message: [String: Any] = [
            "id": String(format: "E0000000-0000-4000-8000-%012X", index + 1),
            "sender": index % 2 == 0 ? "user" : "sapiens",
            "text": "합성 발화 \(index)",
            "timestamp": 1_800_000_000.0 + Double(index),
            "turnId": String(format: "D0000000-0000-4000-8000-%012X", turnsOf(index)),
            "isUnread": false,
        ]
        if withAttachmentAt.contains(index) {
            message["attachment"] = ["id": UUID().uuidString, "type": "image",
                                     "fileName": "a.jpg", "fileSize": 10,
                                     "fileExtension": "jpg", "dataBase64": "AA==",
                                     "mimeType": "image/jpeg"]
        }
        messages.append(message)
    }
    try JSONSerialization.data(withJSONObject: messages)
        .write(to: directory.appendingPathComponent("room_\(ROOM.uuidString)_messages.json"))
    return directory
}

@MainActor
private func makeCoordinator(
    transport: SyncHTTPTransport,
    outboxDirectory: URL
) throws -> SyncShadowUploadCoordinator {
    let client = try SyncWorkerClient(
        baseURL: URL(string: "https://synthetic.invalid")!,
        deviceToken: TOKEN,
        transport: transport
    )
    return SyncShadowUploadCoordinator(
        directory: outboxDirectory,
        accountID: ACCOUNT,
        deviceID: DEVICE,
        client: client,
        outbox: SyncOutbox(fileURL: outboxDirectory.appendingPathComponent("outbox.plist")),
        loadSecrets: secrets
    )
}

private func scratch() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gagaodok-shadow-out-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

// MARK: - Tests

@MainActor
private func testCopiesRoomAndReportsAMatch() async throws {
    let storage = try writeStorage(bubbleCount: 6, turnsOf: { $0 / 2 })
    let out = try scratch()
    defer { try? FileManager.default.removeItem(at: storage); try? FileManager.default.removeItem(at: out) }

    let transport = ProjectingTransport()
    let report = try await makeCoordinator(transport: transport, outboxDirectory: out)
        .run(roomID: ROOM, storageDirectory: storage)

    try check(report.localBubbleCount == 6, "six bubbles read")
    try check(report.localTurnCount == 3, "three turns grouped")
    try check(report.uploadedOperations == 10, "one room, three turns, six bubbles")
    try check(report.remoteBubbleCount == 6, "the projection has every bubble")
    try check(report.remoteTurnCount == 3, "the projection has every turn")
    try check(report.matches, "local and remote agree")
    try check(report.skippedAttachments == 0, "nothing was skipped")
}

@MainActor
private func testDetectsARowTheServerDidNotKeep() async throws {
    let storage = try writeStorage(bubbleCount: 4, turnsOf: { $0 / 2 })
    let out = try scratch()
    defer { try? FileManager.default.removeItem(at: storage); try? FileManager.default.removeItem(at: out) }

    let transport = ProjectingTransport()
    transport.dropBubbles = 1
    let report = try await makeCoordinator(transport: transport, outboxDirectory: out)
        .run(roomID: ROOM, storageDirectory: storage)

    // The uploads all returned "applied". Only re-reading the projection
    // catches this, which is exactly why the comparison is not built from the
    // upload responses.
    try check(report.localBubbleCount == 4, "four bubbles locally")
    try check(report.remoteBubbleCount == 3, "one did not come back")
    try check(!report.matches, "the mismatch is reported, not smoothed over")
}

@MainActor
private func testReportsSkippedAttachmentsRatherThanHidingThem() async throws {
    let storage = try writeStorage(bubbleCount: 4, turnsOf: { _ in 0 }, withAttachmentAt: [1, 3])
    let out = try scratch()
    defer { try? FileManager.default.removeItem(at: storage); try? FileManager.default.removeItem(at: out) }

    let report = try await makeCoordinator(transport: ProjectingTransport(), outboxDirectory: out)
        .run(roomID: ROOM, storageDirectory: storage)

    // The counts match because the text was copied. Without this number, a
    // matching report would read as "everything arrived".
    try check(report.matches, "text counts still agree")
    try check(report.skippedAttachments == 2, "the two dropped images are named")
}

@MainActor
private func testLeavesUnreadableRowsBehindAndDoesNotTouchTheOriginal() async throws {
    let storage = try writeStorage(bubbleCount: 5, turnsOf: { $0 / 2 }, malformedAt: [2])
    let out = try scratch()
    defer { try? FileManager.default.removeItem(at: storage); try? FileManager.default.removeItem(at: out) }

    let messagesURL = storage.appendingPathComponent("room_\(ROOM.uuidString)_messages.json")
    let before = try Data(contentsOf: messagesURL)
    let beforeModified = try FileManager.default
        .attributesOfItem(atPath: messagesURL.path)[.modificationDate] as? Date

    let report = try await makeCoordinator(transport: ProjectingTransport(), outboxDirectory: out)
        .run(roomID: ROOM, storageDirectory: storage)
    try check(report.localBubbleCount == 4, "the malformed row was left behind")

    let after = try Data(contentsOf: messagesURL)
    let afterModified = try FileManager.default
        .attributesOfItem(atPath: messagesURL.path)[.modificationDate] as? Date
    try check(after == before, "the original message file is byte-for-byte unchanged")
    try check(beforeModified == afterModified, "the original was not even rewritten identically")
}

@MainActor
private func testRefusesWithoutSecretsOrRoom() async throws {
    let storage = try writeStorage(bubbleCount: 2, turnsOf: { _ in 0 })
    let out = try scratch()
    defer { try? FileManager.default.removeItem(at: storage); try? FileManager.default.removeItem(at: out) }

    let client = try SyncWorkerClient(
        baseURL: URL(string: "https://synthetic.invalid")!,
        deviceToken: TOKEN,
        transport: ProjectingTransport()
    )
    let noSecrets = SyncShadowUploadCoordinator(
        directory: out, accountID: ACCOUNT, deviceID: DEVICE, client: client,
        outbox: SyncOutbox(fileURL: out.appendingPathComponent("a.plist")),
        loadSecrets: { .absent }
    )
    do {
        _ = try await noSecrets.run(roomID: ROOM, storageDirectory: storage)
        throw Failure(what: "ran without secrets")
    } catch SyncShadowUploadError.secretsUnavailable {}

    let missing = UUID(uuidString: "C0000000-0000-4000-8000-0000000000FF")!
    do {
        _ = try await makeCoordinator(transport: ProjectingTransport(), outboxDirectory: out)
            .run(roomID: missing, storageDirectory: storage)
        throw Failure(what: "ran for a room that is not there")
    } catch SyncShadowUploadError.roomNotFound {} catch SyncShadowUploadError.unreadableStorage {}
}

@MainActor
private func testAFailedUploadKeepsTheJournal() async throws {
    let storage = try writeStorage(bubbleCount: 3, turnsOf: { _ in 0 })
    let out = try scratch()
    defer { try? FileManager.default.removeItem(at: storage); try? FileManager.default.removeItem(at: out) }

    let transport = ProjectingTransport()
    transport.uploadStatus = 503
    let outbox = SyncOutbox(fileURL: out.appendingPathComponent("outbox.plist"))
    let client = try SyncWorkerClient(
        baseURL: URL(string: "https://synthetic.invalid")!,
        deviceToken: TOKEN, transport: transport
    )
    let coordinator = SyncShadowUploadCoordinator(
        directory: out, accountID: ACCOUNT, deviceID: DEVICE,
        client: client, outbox: outbox, loadSecrets: secrets
    )
    do {
        _ = try await coordinator.run(roomID: ROOM, storageDirectory: storage)
        throw Failure(what: "a 503 was treated as success")
    } catch SyncShadowUploadError.uploadFailed(503) {}

    // Every operation is still queued, so the pass resumes instead of being
    // rebuilt from a conversation that may have moved on since.
    try check(try outbox.pending().count == 5, "the journal kept all five operations")
}

// MARK: - Runner

@main
struct Runner {
    static func main() async {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("copies a room and reports a match", testCopiesRoomAndReportsAMatch),
            ("detects a row the server did not keep", testDetectsARowTheServerDidNotKeep),
            ("reports skipped attachments", testReportsSkippedAttachmentsRatherThanHidingThem),
            ("leaves unreadable rows and the original alone", testLeavesUnreadableRowsBehindAndDoesNotTouchTheOriginal),
            ("refuses without secrets or room", testRefusesWithoutSecretsOrRoom),
            ("a failed upload keeps the journal", testAFailedUploadKeepsTheJournal),
        ]
        for (name, test) in tests {
            do {
                try await test()
                print("ok - \(name)")
            } catch {
                print("FAIL - \(name): \(error)")
                exit(1)
            }
        }
        print("\(tests.count) shadow upload tests passed")
    }
}
