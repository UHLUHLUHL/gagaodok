import Foundation

/// Pull coordinator tests.
///
/// The transport is a double and the only thing written is the opaque replica
/// and the coordinator's own progress file. No conversation storage is opened
/// and no projection is decrypted.

private struct Failure: Error { let what: String }

private func check(_ condition: Bool, _ what: String) throws {
    if !condition { throw Failure(what: what) }
}

// MARK: - Doubles

private final class ScriptedTransport: SyncHTTPTransport, @unchecked Sendable {
    /// Responses keyed in the order they will be requested.
    var responses: [(status: Int, body: String)] = []
    private(set) var paths: [String] = []
    private var index = 0

    func send(_ request: URLRequest) async throws -> SyncHTTPResponse {
        paths.append((request.url?.path ?? "") + "?" + (request.url?.query ?? ""))
        guard index < responses.count else { throw Failure(what: "no scripted response left") }
        let scripted = responses[index]
        index += 1
        return SyncHTTPResponse(statusCode: scripted.status, body: Data(scripted.body.utf8))
    }
}

// MARK: - Fixtures

/// A bootstrap envelope. Synthetic identifiers and opaque projections only.
private func bootstrapBody(watermark: Int, hasMore: Bool, cursor: String?, roomSuffix: String) -> String {
    let next = cursor.map { "\"\($0)\"" } ?? "null"
    return """
    {"protocol_version":1,"request_id":"AAAAAAAA-0000-4000-8000-00000000000A","result":{
    "snapshot_high_watermark_seq":\(watermark),"has_more":\(hasMore),"next_cursor":\(next),
    "items":[{"entity_type":"room","identity":{"space_id":"MAC_SPACE","room_id":"10000000-0000-4000-8000-0000000000\(roomSuffix)"},
    "projection":{"space_id":"MAC_SPACE","room_id":"10000000-0000-4000-8000-0000000000\(roomSuffix)","title":"AQE=","revision":0}}]}}
    """
}

private func changesBody(scanned: Int, watermark: Int, hasMore: Bool, revision: Int) -> String {
    """
    {"protocol_version":1,"request_id":"AAAAAAAA-0000-4000-8000-00000000000B","result":{
    "scanned_through_seq":\(scanned),"account_high_watermark_seq":\(watermark),"has_more":\(hasMore),
    "changes":[{"change_seq":\(scanned),"entity_type":"room","change_kind":"upsert","revision":\(revision),
    "identity":{"space_id":"MAC_SPACE","room_id":"10000000-0000-4000-8000-0000000000A1"},
    "projection":{"space_id":"MAC_SPACE","room_id":"10000000-0000-4000-8000-0000000000A1","title":"AQE=","revision":\(revision)}}]}}
    """
}

private struct Harness {
    let directory: URL
    let transport: ScriptedTransport
    let replica: SyncReplicaStore
    let coordinator: SyncPullCoordinator
}

private func makeHarness() throws -> Harness {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gagaodok-pull-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let transport = ScriptedTransport()
    let client = try SyncWorkerClient(
        baseURL: URL(string: "https://synthetic.invalid")!,
        deviceToken: Data((0..<32).map(UInt8.init)),
        transport: transport
    )
    let replica = SyncReplicaStore(fileURL: directory.appendingPathComponent("replica.plist"))
    let coordinator = SyncPullCoordinator(
        client: client,
        replica: replica,
        stateURL: directory.appendingPathComponent("pull.json")
    )
    return Harness(directory: directory, transport: transport, replica: replica, coordinator: coordinator)
}

// MARK: - Tests

private func testBootstrapPagesThenHandsOverAtTheWatermark() async throws {
    let harness = try makeHarness()
    harness.transport.responses = [
        (200, bootstrapBody(watermark: 12, hasMore: true, cursor: "CURSOR-1", roomSuffix: "A1")),
        (200, bootstrapBody(watermark: 12, hasMore: false, cursor: nil, roomSuffix: "A2")),
    ]

    let first = try await harness.coordinator.advanceBootstrap()
    try check(first.hasMore, "the first page reports more")
    try check(first.bootstrapCursor == "CURSOR-1", "the next cursor is kept")
    try check(first.bootstrapComplete == false, "one page is not the whole snapshot")
    try check(first.changesCursor == nil, "changes does not start mid-bootstrap")

    let second = try await harness.coordinator.advanceBootstrap()
    try check(second.bootstrapComplete, "the last page completes bootstrap")
    try check(second.bootstrapCursor == nil, "a finished walk keeps no cursor")
    // The handover: the account cursor begins exactly at the snapshot ceiling.
    try check(second.changesCursor == 12, "changes starts at the snapshot watermark")

    try check(harness.transport.paths.count == 2, "one request per page")
    try check(harness.transport.paths[1].contains("cursor=CURSOR-1"), "the second page uses the cursor")
    try check(try harness.replica.snapshot().count == 2, "both pages reached the replica")
}

private func testChangesRefusedBeforeBootstrapFinishes() async throws {
    let harness = try makeHarness()
    do {
        _ = try await harness.coordinator.advanceChanges()
        throw Failure(what: "changes must not run before bootstrap finishes")
    } catch SyncPullError.bootstrapIncomplete {
        // Starting the cursor without a snapshot would leave the replica with
        // whatever happened to change recently and nothing else.
    }
    try check(harness.transport.paths.isEmpty, "nothing is fetched")
}

private func testChangesPageIsIdempotent() async throws {
    let harness = try makeHarness()
    harness.transport.responses = [
        (200, bootstrapBody(watermark: 5, hasMore: false, cursor: nil, roomSuffix: "A1")),
        (200, changesBody(scanned: 7, watermark: 7, hasMore: false, revision: 3)),
        (200, changesBody(scanned: 7, watermark: 7, hasMore: false, revision: 3)),
    ]
    try await harness.coordinator.advanceBootstrap()

    let once = try await harness.coordinator.advanceChanges()
    try check(once.changesCursor == 7, "the cursor advances to the scanned sequence")
    let after = try harness.replica.snapshot()

    // The same page again, as a device that crashed mid-apply would send.
    try await harness.coordinator.advanceChanges()
    try check(try harness.replica.snapshot() == after, "re-applying a page changes nothing")
}

private func testRefusedPageDoesNotAdvanceTheCursor() async throws {
    let harness = try makeHarness()
    harness.transport.responses = [
        (200, bootstrapBody(watermark: 5, hasMore: false, cursor: nil, roomSuffix: "A1")),
        // An entity type this build does not know.
        (200, """
        {"protocol_version":1,"request_id":"AAAAAAAA-0000-4000-8000-00000000000C","result":{
        "scanned_through_seq":9,"account_high_watermark_seq":9,"has_more":false,
        "changes":[{"change_seq":9,"entity_type":"unknown_entity","change_kind":"upsert","revision":0,
        "identity":{"space_id":"MAC_SPACE"},"projection":{"space_id":"MAC_SPACE"}}]}}
        """),
        (200, changesBody(scanned: 9, watermark: 9, hasMore: false, revision: 1)),
    ]
    try await harness.coordinator.advanceBootstrap()
    let before = try harness.replica.snapshot()

    do {
        _ = try await harness.coordinator.advanceChanges()
        throw Failure(what: "an unknown entity must reject the whole page")
    } catch is SyncReplicaStoreError {
        // Whole-page rejection, not partial application: applying the half a
        // build understands would leave a replica no one can reason about.
    }
    try check(try harness.replica.snapshot() == before, "a refused page writes nothing")
    let stalled = await harness.coordinator.progress()
    try check(stalled.changesCursor == 5, "a refused page does not advance the cursor")

    // The retry fetches the same position again rather than skipping it.
    let recovered = try await harness.coordinator.advanceChanges()
    try check(recovered.changesCursor == 9, "the retry advances once it is understood")
    try check(harness.transport.paths[1] == harness.transport.paths[2], "the same position is refetched")
}

private func testMalformedEnvelopesAreRefusedWhole() async throws {
    let bodies: [String] = [
        // A protocol version this build does not implement.
        """
        {"protocol_version":2,"request_id":"A","result":{"snapshot_high_watermark_seq":1,"has_more":false,"next_cursor":null,"items":[]}}
        """,
        // An unexpected top-level key.
        """
        {"protocol_version":1,"request_id":"A","result":{"snapshot_high_watermark_seq":1,"has_more":false,"next_cursor":null,"items":[]},"extra":1}
        """,
        // An unexpected result key.
        """
        {"protocol_version":1,"request_id":"A","result":{"snapshot_high_watermark_seq":1,"has_more":false,"next_cursor":null,"items":[],"extra":1}}
        """,
        // has_more with no cursor to continue from.
        """
        {"protocol_version":1,"request_id":"A","result":{"snapshot_high_watermark_seq":1,"has_more":true,"next_cursor":null,"items":[]}}
        """,
        // A finished page that still hands back a cursor.
        """
        {"protocol_version":1,"request_id":"A","result":{"snapshot_high_watermark_seq":1,"has_more":false,"next_cursor":"C","items":[]}}
        """,
    ]
    for body in bodies {
        let harness = try makeHarness()
        harness.transport.responses = [(200, body)]
        do {
            _ = try await harness.coordinator.advanceBootstrap()
            throw Failure(what: "a malformed envelope must be refused")
        } catch SyncPullError.malformedEnvelope {
        }
        let progress = await harness.coordinator.progress()
        try check(progress.bootstrapComplete == false, "a refused envelope completes nothing")
        try check(progress.snapshotWatermark == nil, "a refused envelope records no watermark")
    }
}

private func testSnapshotMustNotMoveBetweenPages() async throws {
    let harness = try makeHarness()
    harness.transport.responses = [
        (200, bootstrapBody(watermark: 12, hasMore: true, cursor: "CURSOR-1", roomSuffix: "A1")),
        // A different snapshot: this page belongs to some other walk.
        (200, bootstrapBody(watermark: 99, hasMore: false, cursor: nil, roomSuffix: "A2")),
    ]
    try await harness.coordinator.advanceBootstrap()
    do {
        _ = try await harness.coordinator.advanceBootstrap()
        throw Failure(what: "a moved snapshot must be refused")
    } catch SyncPullError.malformedEnvelope {
    }
    let progress = await harness.coordinator.progress()
    try check(progress.bootstrapComplete == false, "the walk does not complete on a moved snapshot")
    try check(progress.snapshotWatermark == 12, "the original watermark stands")
}

private func testHttpFailureLeavesProgressAlone() async throws {
    let harness = try makeHarness()
    harness.transport.responses = [(503, "{}")]
    do {
        _ = try await harness.coordinator.advanceBootstrap()
        throw Failure(what: "a 503 must not report progress")
    } catch SyncPullError.httpStatus(let status) {
        try check(status == 503, "the status is carried")
    }
    let progress = await harness.coordinator.progress()
    try check(progress.snapshotWatermark == nil, "nothing was recorded")
    try check(try harness.replica.snapshot().isEmpty, "nothing was applied")
}

@main
enum SyncPullCoordinatorTests {
    static func main() async throws {
        try await testBootstrapPagesThenHandsOverAtTheWatermark()
        try await testChangesRefusedBeforeBootstrapFinishes()
        try await testChangesPageIsIdempotent()
        try await testRefusedPageDoesNotAdvanceTheCursor()
        try await testMalformedEnvelopesAreRefusedWhole()
        try await testSnapshotMustNotMoveBetweenPages()
        try await testHttpFailureLeavesProgressAlone()
        print("SyncPullCoordinatorTests: 7 passed")
    }
}
