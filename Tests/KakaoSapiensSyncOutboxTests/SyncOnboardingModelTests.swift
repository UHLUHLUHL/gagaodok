import Foundation

/// Synthetic onboarding screen state model tests.
///
/// Every dependency is a double. No Keychain entry is touched, no request
/// leaves the machine, and the only files written are the coordinator's own.
/// A conversation fixture sits beside them and is checked byte for byte
/// afterwards, because "the screen does not touch real data" is the claim this
/// whole surface rests on.

private struct Failure: Error { let what: String }

private func check(_ condition: Bool, _ what: String) throws {
    if !condition { throw Failure(what: what) }
}

// MARK: - Doubles

private final class MemoryVault: SyncSecretVault {
    var stored: SyncSecretBundle?
    private(set) var saveCount = 0
    func load() -> SyncSecretLoadResult { stored.map { .available($0) } ?? .absent }
    func save(_ bundle: SyncSecretBundle) throws { stored = bundle; saveCount += 1 }
}

private struct CountingRandom: SyncRandomSource {
    func bytes(_ count: Int) -> Data { Data((0..<count).map { UInt8(($0 * 7 + count) & 0xff) }) }
}

private final class ScriptedTransport: SyncHTTPTransport, @unchecked Sendable {
    var responses: [(status: Int, body: String)] = []
    private(set) var sent: [URLRequest] = []
    private(set) var bodies: [Data] = []
    private var index = 0

    func send(_ request: URLRequest) async throws -> SyncHTTPResponse {
        sent.append(request)
        bodies.append(request.httpBody ?? Data())
        guard index < responses.count else { throw Failure(what: "no scripted response left") }
        let scripted = responses[index]
        index += 1
        return SyncHTTPResponse(statusCode: scripted.status, body: Data(scripted.body.utf8))
    }
}

// MARK: - Fixtures

private let ACCOUNT = "A0000000-0000-4000-8000-000000000001"
private let DEVICE = "80000000-0000-4000-8000-000000000001"
private let ENROLLMENT = "B0000000-0000-4000-8000-0000000000E1"
private let ROOM = "10000000-0000-4000-8000-0000000000A1"

/// A stand-in for an existing conversation file. Never referenced by the model.
private let CONVERSATION_FIXTURE = #"{"rooms":[{"id":"local-room","messages":["안녕"]}]}"#

private func bootstrapBody(watermark: Int, hasMore: Bool, cursor: String?) -> String {
    let next = cursor.map { "\"\($0)\"" } ?? "null"
    return """
    {"protocol_version":1,"request_id":"AAAAAAAA-0000-4000-8000-00000000000A","result":{
    "snapshot_high_watermark_seq":\(watermark),"has_more":\(hasMore),"next_cursor":\(next),
    "items":[{"entity_type":"room","identity":{"space_id":"MAC_SPACE","room_id":"\(ROOM)"},
    "projection":{"space_id":"MAC_SPACE","room_id":"\(ROOM)","title":"AQE=","revision":0}}]}}
    """
}

private func syntheticWords() -> [String] {
    (0..<2_048).map { index in
        var unique = "w"
        var counter = index
        repeat {
            unique.append(Character(UnicodeScalar(UInt8(97 + counter % 26))))
            counter /= 26
        } while counter > 0
        return unique + String(repeating: "z", count: index % 3 + 1) + "q\(index)"
            .replacingOccurrences(of: "[^a-z]", with: "", options: .regularExpression)
    }.enumerated().map { index, word in
        var unique = word
        var counter = index
        while counter > 0 {
            unique.append(Character(UnicodeScalar(UInt8(97 + counter % 26))))
            counter /= 26
        }
        return unique
    }
}

@MainActor
private struct Harness {
    let directory: URL
    let conversation: URL
    let vault: MemoryVault
    let enrollTransport: ScriptedTransport
    let pullTransport: ScriptedTransport
    let replica: SyncReplicaStore
    let model: SyncOnboardingModel
}

@MainActor
private func makeHarness() throws -> Harness {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gagaodok-sync-ui-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // A conversation file living alongside the sync state, so "untouched" is
    // an observation rather than an assumption.
    let conversation = directory.appendingPathComponent("conversations.json")
    try Data(CONVERSATION_FIXTURE.utf8).write(to: conversation)

    let vault = MemoryVault()
    let enrollTransport = ScriptedTransport()
    let pullTransport = ScriptedTransport()
    let onboarding = try SyncOnboardingCoordinator(
        baseURL: URL(string: "https://synthetic.invalid")!,
        vault: vault,
        connectionStore: SyncConnectionStateStore(fileURL: directory.appendingPathComponent("connection.json")),
        journal: SyncEnrollmentJournal(fileURL: directory.appendingPathComponent("enrollment.json")),
        transport: enrollTransport,
        random: CountingRandom(),
        words: syntheticWords()
    )
    let replica = SyncReplicaStore(fileURL: directory.appendingPathComponent("replica.plist"))
    let pull = SyncPullCoordinator(
        client: try SyncWorkerClient(
            baseURL: URL(string: "https://synthetic.invalid")!,
            deviceToken: Data((0..<32).map(UInt8.init)),
            transport: pullTransport
        ),
        replica: replica,
        stateURL: directory.appendingPathComponent("pull.json")
    )
    let model = SyncOnboardingModel(
        onboarding: onboarding,
        pull: pull,
        replica: replica,
        spaceID: "MAC_SPACE",
        platform: "macos",
        identity: { (ACCOUNT, DEVICE, ENROLLMENT) }
    )
    return Harness(
        directory: directory,
        conversation: conversation,
        vault: vault,
        enrollTransport: enrollTransport,
        pullTransport: pullTransport,
        replica: replica,
        model: model
    )
}

@MainActor
private func assertConversationUntouched(_ harness: Harness, _ what: String) throws {
    let bytes = try Data(contentsOf: harness.conversation)
    try check(bytes == Data(CONVERSATION_FIXTURE.utf8), "\(what): the conversation fixture changed")
}

// MARK: - Tests

@MainActor
private func testOpeningTheScreenDoesNothing() async throws {
    let harness = try makeHarness()
    await harness.model.refresh()
    try check(harness.model.state == .disconnected, "a fresh screen is disconnected")
    // Appearing is not consent. Nothing was sent, stored or written.
    try check(harness.enrollTransport.sent.isEmpty, "refresh must not send")
    try check(harness.pullTransport.sent.isEmpty, "refresh must not pull")
    try check(harness.vault.stored == nil, "refresh must not store secrets")
    try check(harness.model.recoveryPhrase == nil, "refresh must not produce a phrase")
    try check(harness.model.actions.canBeginConnection, "the only offer is to start")
    try check(!harness.model.actions.canConfirmPhrase, "there is nothing to confirm yet")
    try assertConversationUntouched(harness, "refresh")
}

@MainActor
private func testPhraseMustBeConfirmedBeforeAnythingIsSent() async throws {
    let harness = try makeHarness()
    await harness.model.beginConnection()

    try check(harness.model.state == .awaitingPhraseConfirmation, "the phrase is waiting")
    try check(harness.model.recoveryPhrase?.split(separator: " ").count == 12, "twelve words are shown")
    // The phrase is on screen and still nothing has left the device.
    try check(harness.enrollTransport.sent.isEmpty, "showing the phrase must not send")
    try check(harness.vault.stored == nil, "showing the phrase must not store secrets")
    try check(!harness.model.actions.canBeginConnection, "starting again is not offered")
    try assertConversationUntouched(harness, "prepare")
}

@MainActor
private func testConfirmingSendsAndLeavesSyncOff() async throws {
    let harness = try makeHarness()
    harness.enrollTransport.responses = [(201, "{}")]
    await harness.model.beginConnection()
    await harness.model.confirmPhraseSaved()

    try check(harness.model.state == .connectedSyncOff, "connected, and not synchronising")
    try check(harness.enrollTransport.sent.count == 1, "exactly one enrollment request")
    try check(harness.vault.saveCount == 1, "secrets stored once, after acceptance")
    // The phrase is gone from memory the moment it is no longer needed.
    try check(harness.model.recoveryPhrase == nil, "the phrase is cleared after confirmation")
    try check(harness.model.actions.canAdvanceBootstrap, "the snapshot may now be walked")
    try assertConversationUntouched(harness, "enrollment")
}

@MainActor
private func testRefusedEnrollmentOffersOnlyTheStagedRetry() async throws {
    let harness = try makeHarness()
    harness.enrollTransport.responses = [(503, "{}"), (200, "{}")]
    await harness.model.beginConnection()
    await harness.model.confirmPhraseSaved()

    try check(
        harness.model.state == .retryableError(.enrollmentRefusedRetryPending),
        "a refusal is retryable"
    )
    try check(harness.vault.stored == nil, "a refused enrollment stores no secrets")
    try check(harness.model.recoveryPhrase == nil, "the phrase is not left on screen")
    // Starting over would build a second enrollment for the same account.
    try check(!harness.model.actions.canBeginConnection, "starting over is not offered")
    try check(harness.model.actions.canRetryEnrollment, "the staged retry is offered")

    await harness.model.retryEnrollment()
    try check(harness.model.state == .connectedSyncOff, "the retry connects")
    try check(harness.enrollTransport.bodies.count == 2, "the retry is a second request")
    try check(
        harness.enrollTransport.bodies[0] == harness.enrollTransport.bodies[1],
        "the retry sends byte-identical bytes"
    )
    try assertConversationUntouched(harness, "retry")
}

@MainActor
private func testBootstrapWritesOnlyTheShadowReplica() async throws {
    let harness = try makeHarness()
    harness.enrollTransport.responses = [(201, "{}")]
    harness.pullTransport.responses = [
        (200, bootstrapBody(watermark: 4, hasMore: true, cursor: "CURSOR-1")),
        (200, bootstrapBody(watermark: 4, hasMore: false, cursor: nil)),
    ]
    await harness.model.beginConnection()
    await harness.model.confirmPhraseSaved()

    await harness.model.advanceBootstrap()
    guard case .bootstrapping = harness.model.state else {
        throw Failure(what: "a partial walk reports bootstrapping")
    }
    await harness.model.advanceBootstrap()
    guard case .replicaReady(let entries) = harness.model.state else {
        throw Failure(what: "a finished walk reports the replica")
    }
    try check(entries == 1, "the replica holds the snapshot")
    try check(try harness.replica.snapshot().count == 1, "the store agrees")
    try check(!harness.model.actions.canAdvanceBootstrap, "a finished walk offers no more pages")
    try assertConversationUntouched(harness, "bootstrap")
}

@MainActor
private func testRefusedPageIsRetryableAndDoesNotAdvance() async throws {
    let harness = try makeHarness()
    harness.enrollTransport.responses = [(201, "{}")]
    harness.pullTransport.responses = [
        // An envelope this build does not understand.
        (200, #"{"protocol_version":9,"request_id":"A","result":{}}"#),
        (200, bootstrapBody(watermark: 4, hasMore: false, cursor: nil)),
    ]
    await harness.model.beginConnection()
    await harness.model.confirmPhraseSaved()

    await harness.model.advanceBootstrap()
    try check(harness.model.state == .retryableError(.bootstrapFailed), "a bad page is retryable")
    try check(try harness.replica.snapshot().isEmpty, "a refused page writes nothing")
    try check(harness.model.actions.canAdvanceBootstrap, "the same page may be fetched again")

    await harness.model.advanceBootstrap()
    guard case .replicaReady = harness.model.state else {
        throw Failure(what: "the retry completes the walk")
    }
    try assertConversationUntouched(harness, "refused page")
}

@MainActor
private func testReapplyingAPageChangesNothing() async throws {
    let harness = try makeHarness()
    harness.enrollTransport.responses = [(201, "{}")]
    harness.pullTransport.responses = [
        (200, bootstrapBody(watermark: 4, hasMore: true, cursor: "CURSOR-1")),
        (200, bootstrapBody(watermark: 4, hasMore: true, cursor: "CURSOR-2")),
    ]
    await harness.model.beginConnection()
    await harness.model.confirmPhraseSaved()
    await harness.model.advanceBootstrap()
    let after = try harness.replica.snapshot()
    // The same identity again, as a device that crashed mid-apply would see.
    await harness.model.advanceBootstrap()
    try check(try harness.replica.snapshot() == after, "re-applying a page changes nothing")
}

@MainActor
private func testHalfLinkedDeviceSaysSoAndGeneratesNothing() async throws {
    let harness = try makeHarness()
    // Secrets without endpoint state: the device cannot know which account
    // they belong to, and must not invent a replacement.
    harness.vault.stored = try SyncSecretBundle(
        accountMasterKey: Data(repeating: 1, count: 32),
        deviceToken: Data(repeating: 2, count: 32)
    )
    await harness.model.refresh()
    try check(harness.model.state == .relinkRequired, "a half link is reported")
    try check(!harness.model.actions.canBeginConnection, "no new key is offered")
    try check(!harness.model.actions.canAdvanceBootstrap, "nothing is pulled")

    await harness.model.beginConnection()
    try check(harness.model.state == .relinkRequired, "starting is refused")
    try check(harness.enrollTransport.sent.isEmpty, "nothing was sent")
    try check(harness.model.recoveryPhrase == nil, "no phrase was generated")
}

@MainActor
private func testDisconnectIsAConfirmationOnly() async throws {
    let harness = try makeHarness()
    harness.enrollTransport.responses = [(201, "{}")]
    await harness.model.beginConnection()
    await harness.model.confirmPhraseSaved()

    harness.model.requestDisconnect()
    try check(harness.model.disconnectConfirmationVisible, "the confirmation is shown")
    // Nothing is removed in this build: the secrets and the link are still there.
    try check(harness.vault.stored != nil, "the confirmation deletes no secret")
    try check(harness.model.state == .connectedSyncOff, "the link is unchanged")
    harness.model.dismissDisconnect()
    try check(!harness.model.disconnectConfirmationVisible, "the confirmation closes")
}

@MainActor
private func testNothingSensitiveIsDescribable() async throws {
    let harness = try makeHarness()
    harness.enrollTransport.responses = [(503, "{}")]
    await harness.model.beginConnection()
    let phrase = harness.model.recoveryPhrase ?? ""
    await harness.model.confirmPhraseSaved()

    // Whatever a screen or a log could render from the state must not carry
    // the phrase, the endpoint, a token or ciphertext.
    let describable = "\(harness.model.state) \(harness.model.actions)"
    for word in phrase.split(separator: " ") {
        try check(!describable.contains(word), "the state must not carry the phrase")
    }
    for secret in ["synthetic.invalid", "gdt1_", "AQE=", "https://"] {
        try check(!describable.contains(secret), "the state must not carry \(secret)")
    }
}

@main
enum SyncOnboardingModelTests {
    @MainActor
    static func main() async throws {
        try await testOpeningTheScreenDoesNothing()
        try await testPhraseMustBeConfirmedBeforeAnythingIsSent()
        try await testConfirmingSendsAndLeavesSyncOff()
        try await testRefusedEnrollmentOffersOnlyTheStagedRetry()
        try await testBootstrapWritesOnlyTheShadowReplica()
        try await testRefusedPageIsRetryableAndDoesNotAdvance()
        try await testReapplyingAPageChangesNothing()
        try await testHalfLinkedDeviceSaysSoAndGeneratesNothing()
        try await testDisconnectIsAConfirmationOnly()
        try await testNothingSensitiveIsDescribable()
        print("SyncOnboardingModelTests: 10 passed")
    }
}
