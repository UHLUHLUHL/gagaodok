import Foundation

/// Recovery rotation tests.
///
/// No Keychain item, no network and no conversation file. The account master
/// key, the entropy and the word list are all synthetic fixtures.

private struct Failure: Error { let what: String }

private func check(_ condition: Bool, _ what: String) throws {
    if !condition { throw Failure(what: what) }
}

// MARK: - Doubles

private final class StubTransport: SyncHTTPTransport {
    var status = 201
    var thrown: Error?
    private(set) var bodies: [Data] = []
    private(set) var paths: [String] = []
    private(set) var authorizations: [String] = []

    func send(_ request: URLRequest) async throws -> SyncHTTPResponse {
        if let thrown { throw thrown }
        bodies.append(request.httpBody ?? Data())
        paths.append(request.url?.path ?? "")
        authorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        return SyncHTTPResponse(
            statusCode: status,
            body: Data(#"{"protocol_version":1,"result":{"status":"created"}}"#.utf8)
        )
    }
}

// MARK: - Fixtures

/// 2048 distinct lowercase words — the codec cares about shape, not meaning.
private func syntheticWords() -> [String] {
    (0..<2_048).map { index in
        var unique = "w"
        var counter = index
        repeat {
            unique.append(Character(UnicodeScalar(UInt8(97 + counter % 26))))
            counter /= 26
        } while counter > 0
        return unique
    }
}

private let ACCOUNT = "A0000000-0000-4000-8000-000000000001"
private let WORDS = syntheticWords()
private let MASTER_KEY = Data((0..<32).map { UInt8(($0 * 3 + 11) & 0xff) })
private let DEVICE_TOKEN = Data((0..<32).map { UInt8(($0 * 5 + 29) & 0xff) })

private func secrets() -> SyncSecretLoadResult {
    .available(try! SyncSecretBundle(accountMasterKey: MASTER_KEY, deviceToken: DEVICE_TOKEN))
}

/// Deterministic bytes so a run is reproducible; varied by length so the
/// entropy and the nonce are not the same pattern.
private func fixedRandom(_ seed: UInt8) -> (Int) -> Data {
    { count in Data((0..<count).map { UInt8((Int(seed) + $0 * 7 + count) & 0xff) }) }
}

@MainActor
private func makeCoordinator(
    transport: StubTransport,
    load: @escaping () -> SyncSecretLoadResult = secrets
) throws -> SyncRecoveryRotationCoordinator {
    let client = try SyncWorkerClient(
        baseURL: URL(string: "https://synthetic.invalid")!,
        deviceToken: DEVICE_TOKEN,
        transport: transport
    )
    return SyncRecoveryRotationCoordinator(
        accountID: ACCOUNT,
        client: client,
        words: WORDS,
        loadSecrets: load,
        randomBytes: fixedRandom(3)
    )
}

// MARK: - Tests

@MainActor
private func testIssueSendsNoSecretAndShowsPhrase() async throws {
    let transport = StubTransport()
    let coordinator = try makeCoordinator(transport: transport)
    await coordinator.issue(nextVersion: 2)

    guard case .awaitingConfirmation(let phrase, let version) = coordinator.stage else {
        throw Failure(what: "issue did not reach awaitingConfirmation")
    }
    try check(version == 2, "version is the one requested")
    try check(phrase.split(separator: " ").count == 12, "phrase is twelve words")
    try check(transport.paths == ["/v1/recovery/rotate"], "posted to the rotate path")
    try check(
        transport.authorizations.allSatisfy { $0.hasPrefix("Device gdt1_") },
        "the device token authenticates the rotation"
    )

    let body = try JSONSerialization.jsonObject(with: transport.bodies[0]) as! [String: Any]
    try check(
        Set(body.keys) == [
            "protocol_version", "recovery_version", "recovery_lookup",
            "recovery_auth_verifier", "wrapped_master_key",
        ],
        "body carries exactly the contract's keys"
    )
    try check(body["recovery_version"] as? Int == 2, "body states the next version")

    // The two things that must never travel.
    let raw = String(decoding: transport.bodies[0], as: UTF8.self)
    try check(!raw.contains(MASTER_KEY.base64EncodedString()), "master key does not travel")
    let entropy = fixedRandom(3)(16)
    try check(!raw.contains(entropy.base64EncodedString()), "entropy does not travel")
    for word in phrase.split(separator: " ") {
        try check(!raw.contains(word), "no phrase word travels")
    }
}

@MainActor
private func testConfirmAcceptsOnlyAPhraseThatRecoversTheMasterKey() async throws {
    let transport = StubTransport()
    let coordinator = try makeCoordinator(transport: transport)
    await coordinator.issue(nextVersion: 2)
    guard case .awaitingConfirmation(let phrase, _) = coordinator.stage else {
        throw Failure(what: "issue did not reach awaitingConfirmation")
    }

    // A wrong phrase is refused even though it is a valid mnemonic.
    let other = try SyncRecoveryMnemonic.encode(
        entropy: Data((0..<16).map { UInt8(($0 * 13 + 1) & 0xff) }),
        words: WORDS
    )
    try check(!coordinator.confirm(typedPhrase: other), "a different valid phrase is refused")
    try check(coordinator.stage == .failed(.phraseMismatch), "refusal is a mismatch, not a crash")

    // The rotation still stands, so the user may simply type again.
    coordinator.retryConfirmation()
    guard case .awaitingConfirmation = coordinator.stage else {
        throw Failure(what: "retry did not return to confirmation")
    }

    // Case and spacing are forgiven; the words are not.
    let sloppy = "  " + phrase.uppercased().replacingOccurrences(of: " ", with: "   ") + "\n"
    try check(coordinator.confirm(typedPhrase: sloppy), "normalised phrase is accepted")
    try check(coordinator.stage == .confirmed(version: 2), "confirmation records the version")
}

@MainActor
private func testConfirmationCannotBeReplayedOrFaked() async throws {
    let transport = StubTransport()
    let coordinator = try makeCoordinator(transport: transport)

    // Nothing issued yet: there is nothing a confirmation could prove.
    try check(!coordinator.confirm(typedPhrase: "whatever"), "confirm before issue is refused")
    try check(coordinator.stage == .failed(.nothingToConfirm), "refusal names the missing rotation")

    await coordinator.issue(nextVersion: 2)
    guard case .awaitingConfirmation(let phrase, _) = coordinator.stage else {
        throw Failure(what: "issue did not reach awaitingConfirmation")
    }
    try check(coordinator.confirm(typedPhrase: phrase), "first confirmation succeeds")
    // The pending rotation is consumed, so the same words cannot be replayed
    // into a second confirmation.
    try check(!coordinator.confirm(typedPhrase: phrase), "a confirmed rotation cannot be confirmed twice")
}

@MainActor
private func testRejectionLeavesNoPhraseOnScreen() async throws {
    let transport = StubTransport()
    transport.status = 409
    let coordinator = try makeCoordinator(transport: transport)
    await coordinator.issue(nextVersion: 2)
    try check(coordinator.stage == .failed(.rejected(409)), "a conflict surfaces as a rejection")
    // Critical: a phrase the server never accepted must not be shown, or the
    // user writes down words that recover nothing.
    try check(!coordinator.confirm(typedPhrase: "anything"), "a rejected rotation has nothing to confirm")

    let broken = StubTransport()
    broken.thrown = URLError(.notConnectedToInternet)
    let offline = try makeCoordinator(transport: broken)
    await offline.issue(nextVersion: 2)
    try check(offline.stage == .failed(.transport), "a transport failure is not a rotation")
}

@MainActor
private func testRefusesWithoutSecretsOrBelowVersionTwo() async throws {
    let transport = StubTransport()
    let coordinator = try makeCoordinator(transport: transport, load: { .absent })
    await coordinator.issue(nextVersion: 2)
    try check(coordinator.stage == .failed(.secretsUnavailable), "no master key means no rotation")
    try check(transport.bodies.isEmpty, "nothing was sent")

    // Version 1 belongs to enrollment; a rotation must supersede something.
    let second = try makeCoordinator(transport: transport)
    await second.issue(nextVersion: 1)
    guard case .failed = second.stage else { throw Failure(what: "version 1 was not refused") }
    try check(transport.bodies.isEmpty, "a refused version sends nothing")
}

// MARK: - Runner

@main
struct Runner {
    static func main() async {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("issue sends no secret and shows a phrase", testIssueSendsNoSecretAndShowsPhrase),
            ("confirm accepts only a recovering phrase", testConfirmAcceptsOnlyAPhraseThatRecoversTheMasterKey),
            ("confirmation cannot be replayed", testConfirmationCannotBeReplayedOrFaked),
            ("a rejected rotation shows no phrase", testRejectionLeavesNoPhraseOnScreen),
            ("refuses without secrets or below version two", testRefusesWithoutSecretsOrBelowVersionTwo),
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
        print("\(tests.count) recovery rotation tests passed")
    }
}
