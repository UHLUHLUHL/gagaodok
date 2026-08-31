import Foundation

/// Cross-device contract, reverse direction: rows the Android writer actually
/// produced, opened here.
///
/// The fixture is emitted by the Kotlin writer's own unit test. The forward
/// fixture was once hand-assembled and encoded a wrong guess about the wire —
/// both sides then agreed with each other while the real devices decrypted
/// nothing — so this one is replayed, never described.
///
/// The change feed is reconstructed from that fixture's operations using the
/// Worker's own wire rules, which the Worker suite pins against a live
/// projection. Synthetic account, synthetic room, invented lines.

private struct Failure: Error { let what: String }

private func check(_ condition: Bool, _ what: String) throws {
    if !condition { throw Failure(what: what) }
}

private struct Fixture {
    let accountID: String
    let spaceID: String
    let roomID: String
    let masterKey: Data
    let expectedTurns: Int
    let expectedBubbles: Int
    let expectedHash: String
    let operations: [[String: Any]]
}

private func loadFixture() throws -> Fixture {
    // Resolved from this file, so the suite does not depend on the working
    // directory it happens to be run from.
    let path = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("android/app/src/test/resources/kotlin-shadow-operations.json")
    guard
        let data = try? Data(contentsOf: path),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let expected = root["expected"] as? [String: Any],
        let operations = root["operations"] as? [[String: Any]],
        let key = (root["master_key_base64"] as? String).flatMap({ Data(base64Encoded: $0) })
    else {
        throw Failure(what: "the Kotlin fixture is missing or malformed at \(path.path)")
    }
    return Fixture(
        accountID: root["account_id"] as! String,
        spaceID: root["space_id"] as! String,
        roomID: root["room_id"] as! String,
        masterKey: key,
        expectedTurns: expected["turn_count"] as! Int,
        expectedBubbles: expected["bubble_count"] as! Int,
        expectedHash: expected["content_hash"] as! String,
        operations: operations
    )
}

/// Answers `/v1/sync/changes` from the fixture's operations, using the wire
/// rules the Worker suite pins: identity carries a nullable `worldline_id`, and
/// a projected field drops the `_enc` suffix its D1 column has.
private final class ChangeFeedTransport: SyncHTTPTransport {
    private let rows: [[String: Any]]
    var dropBubbles = 0

    init(operations: [[String: Any]]) {
        var built: [[String: Any]] = []
        for (index, operation) in operations.enumerated() {
            guard let entity = operation["entity_type"] as? String,
                  let target = operation["target"] as? [String: Any] else { continue }
            var identity: [String: Any] = [
                "space_id": target["space_id"] ?? "",
                "room_id": target["room_id"] ?? "",
                "worldline_id": NSNull(),
            ]
            var projection: [String: Any] = [:]
            switch entity {
            case "turn":
                identity["turn_id"] = target["turn_id"] ?? ""
            case "bubble":
                identity["turn_id"] = target["turn_id"] ?? ""
                identity["message_id"] = target["message_id"] ?? ""
                projection["bubble_order"] = operation["bubble_order"] ?? 0
                for (field, value) in (operation["set"] as? [String: String]) ?? [:] {
                    projection[field] = value
                }
            default:
                continue
            }
            built.append([
                "change_seq": index + 1,
                "entity_type": entity,
                "change_kind": "create",
                "identity": identity,
                "projection": projection,
            ])
        }
        rows = built
    }

    func send(_ request: URLRequest) async throws -> SyncHTTPResponse {
        var remaining = dropBubbles
        let visible = rows.filter { row in
            guard row["entity_type"] as? String == "bubble", remaining > 0 else { return true }
            remaining -= 1
            return false
        }
        let body: [String: Any] = [
            "protocol_version": 1,
            "result": [
                "changes": visible,
                "has_more": false,
                "scanned_through_seq": visible.count,
                "account_high_watermark_seq": visible.count,
            ],
        ]
        return SyncHTTPResponse(
            statusCode: 200,
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }
}

@MainActor
private func makeReader(
    _ fixture: Fixture,
    transport: SyncHTTPTransport,
    accountID: String? = nil,
    masterKey: Data? = nil
) throws -> SyncShadowReader {
    let client = try SyncWorkerClient(
        baseURL: URL(string: "https://synthetic.invalid")!,
        deviceToken: Data((0..<32).map { UInt8(($0 * 5 + 29) & 0xff) }),
        transport: transport
    )
    let key = masterKey ?? fixture.masterKey
    return SyncShadowReader(
        accountID: accountID ?? fixture.accountID,
        client: client,
        loadSecrets: {
            .available(
                try! SyncSecretBundle(
                    accountMasterKey: key,
                    deviceToken: Data((0..<32).map { UInt8(($0 * 5 + 29) & 0xff) })
                )
            )
        }
    )
}

// MARK: - Tests

@MainActor
private func testOpensEveryBubbleThePhoneWrote() async throws {
    let fixture = try loadFixture()
    let reader = try makeReader(fixture, transport: ChangeFeedTransport(operations: fixture.operations))
    let result = try await reader.read(roomID: UUID(uuidString: fixture.roomID)!)

    try check(result.bubbleCount == fixture.expectedBubbles, "every bubble arrived")
    try check(result.turnCount == fixture.expectedTurns, "every turn arrived")
    // The row is owned by the phone's space, and this reader is not the phone.
    try check(result.spaceID == fixture.spaceID, "the row keeps its writing space")
    try check(result.allDecrypted, "a bubble the phone wrote did not open here")
    // Computed independently on each side from identity and order.
    try check(result.contentHash == fixture.expectedHash, "the two devices agree on the digest")
    try check(result.diagnostic.hasSuffix("opened"), "no failure was reported")
}

@MainActor
private func testRefusesUnderTheWrongAccountOrKey() async throws {
    let fixture = try loadFixture()

    let stranger = try makeReader(
        fixture,
        transport: ChangeFeedTransport(operations: fixture.operations),
        accountID: "A0000000-0000-4000-8000-0000000000FF"
    )
    let wrongAccount = try await stranger.read(roomID: UUID(uuidString: fixture.roomID)!)
    // Identity and order do not depend on the key, so the digest still matches.
    // Only reading fails — which is exactly how this failure looks in the wild.
    try check(wrongAccount.contentHash == fixture.expectedHash, "the digest is key-independent")
    try check(wrongAccount.decryptedCount == 0, "another account cannot open these rows")

    let wrongKey = try makeReader(
        fixture,
        transport: ChangeFeedTransport(operations: fixture.operations),
        masterKey: Data((0..<32).map { UInt8(($0 * 11 + 3) & 0xff) })
    )
    let result = try await wrongKey.read(roomID: UUID(uuidString: fixture.roomID)!)
    try check(result.decryptedCount == 0, "another key cannot open these rows")
    try check(result.diagnostic.contains("fail=open"), "the reason names the failed open")
}

@MainActor
private func testNoticesARowThatNeverArrived() async throws {
    let fixture = try loadFixture()
    let transport = ChangeFeedTransport(operations: fixture.operations)
    transport.dropBubbles = 1
    let result = try await makeReader(fixture, transport: transport)
        .read(roomID: UUID(uuidString: fixture.roomID)!)

    try check(result.bubbleCount == fixture.expectedBubbles - 1, "one bubble is missing")
    // A missing row changes the digest, so the two sides disagree rather than
    // both reporting a comfortable success.
    try check(result.contentHash != fixture.expectedHash, "the digest catches the gap")
}

@MainActor
private func testReportsAnAbsentRoom() async throws {
    let fixture = try loadFixture()
    let reader = try makeReader(fixture, transport: ChangeFeedTransport(operations: fixture.operations))
    do {
        _ = try await reader.read(roomID: UUID(uuidString: "C0000000-0000-4000-8000-0000000000FF")!)
        throw Failure(what: "a room that is not there was reported as read")
    } catch SyncShadowReadError.roomAbsent {}
}

@MainActor
private func testRefusesWithoutSecrets() async throws {
    let fixture = try loadFixture()
    let client = try SyncWorkerClient(
        baseURL: URL(string: "https://synthetic.invalid")!,
        deviceToken: Data((0..<32).map { UInt8(($0 * 5 + 29) & 0xff) }),
        transport: ChangeFeedTransport(operations: fixture.operations)
    )
    let reader = SyncShadowReader(
        accountID: fixture.accountID, client: client, loadSecrets: { .absent }
    )
    do {
        _ = try await reader.read(roomID: UUID(uuidString: fixture.roomID)!)
        throw Failure(what: "read without an account key")
    } catch SyncShadowReadError.secretsUnavailable {}
}

// MARK: - Runner

@main
struct Runner {
    static func main() async {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("opens every bubble the phone wrote", testOpensEveryBubbleThePhoneWrote),
            ("refuses under the wrong account or key", testRefusesUnderTheWrongAccountOrKey),
            ("notices a row that never arrived", testNoticesARowThatNeverArrived),
            ("reports an absent room", testReportsAnAbsentRoom),
            ("refuses without secrets", testRefusesWithoutSecrets),
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
        print("\(tests.count) shadow reader tests passed")
    }
}
