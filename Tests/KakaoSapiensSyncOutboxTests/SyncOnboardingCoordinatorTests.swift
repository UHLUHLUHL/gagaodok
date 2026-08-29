import Foundation

/// Onboarding coordinator tests.
///
/// Every dependency is a double: no Keychain item is read or written, no
/// request leaves the machine, and no real conversation storage is opened. The
/// fixtures are synthetic identifiers and a synthetic word list.

private struct Failure: Error { let what: String }

private func check(_ condition: Bool, _ what: String) throws {
    if !condition { throw Failure(what: what) }
}

// MARK: - Doubles

private final class MemoryVault: SyncSecretVault {
    var stored: SyncSecretBundle?
    var forced: SyncSecretLoadResult?
    private(set) var saveCount = 0

    func load() -> SyncSecretLoadResult {
        if let forced { return forced }
        return stored.map { .available($0) } ?? .absent
    }

    func save(_ bundle: SyncSecretBundle) throws {
        stored = bundle
        saveCount += 1
    }
}

/// Counts bytes out of a fixed pattern, so a draft is reproducible.
private struct CountingRandom: SyncRandomSource {
    func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(($0 * 7 + count) & 0xff) })
    }
}

private final class StubTransport: SyncHTTPTransport {
    var status = 201
    private(set) var sent: [URLRequest] = []
    private(set) var bodies: [Data] = []

    func send(_ request: URLRequest) async throws -> SyncHTTPResponse {
        sent.append(request)
        bodies.append(request.httpBody ?? Data())
        return SyncHTTPResponse(statusCode: status, body: Data("{}".utf8))
    }
}

// MARK: - Fixtures

private func syntheticWords() -> [String] {
    // 2048 distinct lowercase words. Not BIP-39's list; the codec only requires
    // the shape, and a real wordlist is not needed to test ordering.
    (0..<2_048).map { index -> String in
        var value = index
        var word = ""
        repeat {
            word.append(Character(UnicodeScalar(UInt8(97 + value % 26))))
            value /= 26
        } while value > 0
        return word + "z\(index)".replacingOccurrences(
            of: "[^a-z]",
            with: "",
            options: .regularExpression
        )
    }.enumerated().map { index, word in
        // Guarantee uniqueness without leaving the [a-z] alphabet.
        var unique = word
        var counter = index
        while counter > 0 {
            unique.append(Character(UnicodeScalar(UInt8(97 + counter % 26))))
            counter /= 26
        }
        return unique
    }
}

private let ACCOUNT = "A0000000-0000-4000-8000-000000000001"
private let DEVICE = "80000000-0000-4000-8000-000000000001"
private let ENROLLMENT = "B0000000-0000-4000-8000-0000000000E1"

private struct Harness {
    let directory: URL
    let vault: MemoryVault
    let connection: SyncConnectionStateStore
    let journal: SyncEnrollmentJournal
    let transport: StubTransport
    let coordinator: SyncOnboardingCoordinator
}

private func makeHarness() throws -> Harness {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gagaodok-onboarding-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let vault = MemoryVault()
    let connection = SyncConnectionStateStore(fileURL: directory.appendingPathComponent("connection.json"))
    let journal = SyncEnrollmentJournal(fileURL: directory.appendingPathComponent("enrollment.json"))
    let transport = StubTransport()
    let coordinator = try SyncOnboardingCoordinator(
        baseURL: URL(string: "https://synthetic.invalid")!,
        vault: vault,
        connectionStore: connection,
        journal: journal,
        transport: transport,
        random: CountingRandom(),
        words: syntheticWords()
    )
    return Harness(
        directory: directory,
        vault: vault,
        connection: connection,
        journal: journal,
        transport: transport,
        coordinator: coordinator
    )
}

// MARK: - Tests

private func testFreshInstallIsDisconnected() throws {
    let harness = try makeHarness()
    try check(harness.coordinator.status() == .disconnected, "a fresh install must be disconnected")
}

private func testPrepareSendsAndStoresNothing() throws {
    let harness = try makeHarness()
    let draft = try harness.coordinator.prepare(
        accountID: ACCOUNT, deviceID: DEVICE, enrollmentID: ENROLLMENT,
        spaceID: "MAC_SPACE", platform: "macos"
    )
    try check(!draft.recoveryPhrase.isEmpty, "the draft must carry a phrase to show")
    try check(draft.recoveryPhrase.split(separator: " ").count == 12, "the phrase must be twelve words")
    // Nothing has happened yet but a computation.
    try check(harness.transport.sent.isEmpty, "prepare must not send")
    try check(try harness.journal.pending() == nil, "prepare must not stage")
    try check(harness.vault.stored == nil, "prepare must not store secrets")
    try check(harness.connection.load() == .absent, "prepare must not connect")
}

private func testUnconfirmedPhraseNeverSends() async throws {
    let harness = try makeHarness()
    let draft = try harness.coordinator.prepare(
        accountID: ACCOUNT, deviceID: DEVICE, enrollmentID: ENROLLMENT,
        spaceID: "MAC_SPACE", platform: "macos"
    )
    do {
        _ = try await harness.coordinator.confirm(draft, confirmedPhrase: "not the phrase")
        throw Failure(what: "an unconfirmed phrase must not enroll")
    } catch SyncOnboardingError.phraseNotConfirmed {
        // The user has not written the phrase down, so there is nothing to
        // recover the account with. Enrolling here would strand them.
    }
    try check(harness.transport.sent.isEmpty, "a wrong phrase must not send")
    try check(try harness.journal.pending() == nil, "a wrong phrase must not stage")
    try check(harness.vault.stored == nil, "a wrong phrase must not store secrets")
}

private func testSuccessfulEnrollmentLeavesSyncOff() async throws {
    let harness = try makeHarness()
    let draft = try harness.coordinator.prepare(
        accountID: ACCOUNT, deviceID: DEVICE, enrollmentID: ENROLLMENT,
        spaceID: "MAC_SPACE", platform: "macos"
    )
    let configuration = try await harness.coordinator.confirm(
        draft, confirmedPhrase: draft.recoveryPhrase
    )

    try check(harness.transport.sent.count == 1, "exactly one enrollment request")
    let request = harness.transport.sent[0]
    try check(request.httpMethod == "POST", "enrollment is a POST")
    try check(request.url?.path == "/v1/enrollment/initialize", "enrollment path")
    try check(
        request.value(forHTTPHeaderField: "Authorization") == nil,
        "enrollment creates the device a token would prove, so it carries none"
    )
    try check(harness.transport.bodies[0] == draft.package.rawRequestBody, "the exact staged bytes")

    // Connected, and deliberately not synchronising.
    try check(configuration.enabled == false, "sync must stay off after enrollment")
    try check(configuration.accountID == ACCOUNT, "the configuration names the account")
    try check(configuration.changesCursor == nil, "no cursor has been earned yet")
    try check(harness.vault.saveCount == 1, "secrets stored once, after acceptance")
    try check(harness.coordinator.status() == .connected(configuration), "status reflects the link")
    try check(try harness.journal.pending() == nil, "the journal is acknowledged on success")

    // The phrase never reaches storage.
    let onDisk = try FileManager.default.contentsOfDirectory(atPath: harness.directory.path)
        .map { try String(contentsOf: harness.directory.appendingPathComponent($0), encoding: .utf8) }
        .joined()
    for word in draft.recoveryPhrase.split(separator: " ") {
        try check(!onDisk.contains("\"\(word)\""), "the recovery phrase must never be written down")
    }
}

private func testRefusalKeepsTheExactBytesForRetry() async throws {
    let harness = try makeHarness()
    let draft = try harness.coordinator.prepare(
        accountID: ACCOUNT, deviceID: DEVICE, enrollmentID: ENROLLMENT,
        spaceID: "MAC_SPACE", platform: "macos"
    )
    harness.transport.status = 503
    do {
        _ = try await harness.coordinator.confirm(draft, confirmedPhrase: draft.recoveryPhrase)
        throw Failure(what: "a refused enrollment must not report success")
    } catch SyncOnboardingError.enrollmentRejected(let status) {
        try check(status == 503, "the refusal carries the status")
    }
    try check(harness.vault.stored == nil, "a refused enrollment stores no secrets")
    try check(harness.connection.load() == .absent, "a refused enrollment does not connect")

    let pending = try harness.journal.pending()
    try check(pending?.rawBody == draft.package.rawRequestBody, "the staged bytes survive unchanged")

    // The same bytes again, which is what makes the retry a replay.
    harness.transport.status = 200
    let configuration = try await harness.coordinator.retryPendingEnrollment(
        secrets: draft.package.secrets
    )
    try check(harness.transport.bodies.count == 2, "the retry is a second request")
    try check(harness.transport.bodies[0] == harness.transport.bodies[1], "byte-identical retry")
    try check(configuration.accountID == ACCOUNT, "identity read from the staged body")
    try check(configuration.enabled == false, "a retry does not enable sync either")
    try check(try harness.journal.pending() == nil, "acknowledged only after acceptance")
}

private func testHalfLinkedStateRefusesToGuess() async throws {
    let harness = try makeHarness()
    // Secrets present, endpoint state absent: the device cannot know which
    // account or endpoint those secrets belong to.
    harness.vault.stored = try SyncSecretBundle(
        accountMasterKey: Data(repeating: 1, count: 32),
        deviceToken: Data(repeating: 2, count: 32)
    )
    try check(harness.coordinator.status() == .relinkRequired, "half a link is not a link")
    do {
        _ = try harness.coordinator.prepare(
            accountID: ACCOUNT, deviceID: DEVICE, enrollmentID: ENROLLMENT,
            spaceID: "MAC_SPACE", platform: "macos"
        )
        throw Failure(what: "a half-linked device must not start a new enrollment")
    } catch SyncOnboardingError.relinkRequired {
    }
}

private func testAlreadyConnectedRefusesASecondEnrollment() async throws {
    let harness = try makeHarness()
    let draft = try harness.coordinator.prepare(
        accountID: ACCOUNT, deviceID: DEVICE, enrollmentID: ENROLLMENT,
        spaceID: "MAC_SPACE", platform: "macos"
    )
    _ = try await harness.coordinator.confirm(draft, confirmedPhrase: draft.recoveryPhrase)
    do {
        _ = try harness.coordinator.prepare(
            accountID: ACCOUNT, deviceID: DEVICE, enrollmentID: ENROLLMENT,
            spaceID: "MAC_SPACE", platform: "macos"
        )
        throw Failure(what: "a connected device must not enroll again")
    } catch SyncOnboardingError.alreadyConnected {
    }
}

@main
enum SyncOnboardingCoordinatorTests {
    static func main() async throws {
        try testFreshInstallIsDisconnected()
        try testPrepareSendsAndStoresNothing()
        try await testUnconfirmedPhraseNeverSends()
        try await testSuccessfulEnrollmentLeavesSyncOff()
        try await testRefusalKeepsTheExactBytesForRetry()
        try await testHalfLinkedStateRefusesToGuess()
        try await testAlreadyConnectedRefusesASecondEnrollment()
        print("SyncOnboardingCoordinatorTests: 7 passed")
    }
}
