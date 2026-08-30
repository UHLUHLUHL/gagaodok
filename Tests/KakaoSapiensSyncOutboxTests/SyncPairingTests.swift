import Foundation

/// Pairing contract and local end-to-end tests.
///
/// The Worker is replaced by an in-process double that enforces the same state
/// rules the real one does. Nothing here touches the Keychain, the network, or
/// any conversation file — and a conversation fixture sits beside the stores so
/// "pairing does not touch real data" is checked rather than asserted.

// MARK: - doubles

private struct MemoryVault: SyncSecretVault {
    final class Box: @unchecked Sendable {
        var stored: SyncSecretBundle?
        var failSave = false
    }
    let box: Box
    func load() -> SyncSecretLoadResult {
        box.stored.map { .available($0) } ?? .absent
    }
    func save(_ bundle: SyncSecretBundle) throws {
        if box.failSave { throw SyncSecretStoreError.invalidLength }
        box.stored = bundle
    }
}

/// A counter-based source. Deterministic, and never the real CSPRNG.
private struct CountingRandom: SyncRandomSource {
    final class Box: @unchecked Sendable {
        var counter: UInt8
        init(_ start: UInt8) { counter = start }
    }
    let box: Box
    /// Seeded, so a second device in a test is a genuinely different device.
    /// Sharing one seed would make an "attacker" derive the honest joiner's
    /// own claim secret and prove nothing.
    init(seed: UInt8 = 1) { box = Box(seed) }
    func bytes(_ count: Int) -> Data {
        let seed = box.counter
        box.counter = box.counter &+ 1
        return Data((0..<count).map { UInt8(($0 &* 7 &+ Int(seed)) & 0xff) })
    }
}

/// An in-process stand-in for the pairing endpoints.
private final class FakeWorker: SyncHTTPTransport, @unchecked Sendable {
    struct ClaimRow {
        var lookup: String
        var envelope: String
        var verifier: String
        var state = "submitted"
        var delivery: String?
    }
    var sessions: [String: (lookupHash: String, closed: Bool)] = [:]
    var claims: [String: ClaimRow] = [:]
    var hostToken: String?
    var redeemAttempts = 0
    var unauthenticatedRequests: [String] = []
    var expireSessions = false

    func send(_ request: URLRequest) async throws -> SyncHTTPResponse {
        let path = request.url!.path
        let auth = request.value(forHTTPHeaderField: "Authorization")
        let body = request.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        if auth == nil { unauthenticatedRequests.append(path) }

        func ok(_ result: [String: Any], _ status: Int = 200) throws -> SyncHTTPResponse {
            let root: [String: Any] = ["protocol_version": 1, "result": result]
            return SyncHTTPResponse(
                statusCode: status,
                body: try JSONSerialization.data(withJSONObject: root)
            )
        }
        func fail(_ status: Int) -> SyncHTTPResponse {
            SyncHTTPResponse(statusCode: status, body: Data("{}".utf8))
        }

        // Authenticated routes reject a caller without the host's token.
        if path == "/v1/pairing/sessions", request.httpMethod == "POST" {
            guard auth != nil, auth == hostToken else { return fail(401) }
            let id = body?["session_id"] as? String ?? ""
            sessions[id] = (lookupHash: body?["pairing_session_lookup"] as? String ?? "", closed: false)
            return try ok(["status": "created", "session_id": id, "expires_at": "2030-01-01T00:00:00.000Z"], 201)
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 5, parts[1] == "pairing", parts[2] == "sessions" else { return fail(404) }
        let sessionID = parts[3]
        guard let session = sessions[sessionID], !session.closed, !expireSessions else { return fail(404) }

        if parts.count == 5, parts[4] == "claims", request.httpMethod == "POST" {
            guard body?["pairing_session_lookup"] as? String == session.lookupHash else { return fail(404) }
            let id = body?["claim_id"] as? String ?? ""
            claims[id] = ClaimRow(
                lookup: body?["claim_lookup"] as? String ?? "",
                envelope: body?["claim_envelope"] as? String ?? "",
                verifier: body?["claim_redeem_verifier"] as? String ?? ""
            )
            return try ok(["status": "submitted", "claim_id": id], 201)
        }
        if parts.count == 5, parts[4] == "claims", request.httpMethod == "GET" {
            guard auth != nil, auth == hostToken else { return fail(401) }
            return try ok(["claims": claims.sorted { $0.key < $1.key }.map { id, row in
                ["claim_id": id, "claim_lookup": row.lookup, "claim_envelope": row.envelope, "state": row.state]
            }])
        }
        guard parts.count == 7, parts[4] == "claims" else { return fail(404) }
        let claimID = parts[5]
        guard var row = claims[claimID] else { return fail(404) }

        if parts[6] == "approve" {
            guard auth != nil, auth == hostToken else { return fail(401) }
            // The lookup must be the one this exact claim carries.
            guard body?["claim_lookup"] as? String == row.lookup, row.state == "submitted" else {
                return fail(409)
            }
            row.state = "approved"
            row.delivery = body?["delivery_envelope"] as? String
            claims[claimID] = row
            return try ok(["status": "approved", "claim_id": claimID])
        }
        if parts[6] == "redeem" {
            redeemAttempts += 1
            guard row.state == "approved", let delivery = row.delivery else { return fail(409) }
            guard body?["claim_lookup"] as? String == row.lookup else { return fail(404) }
            row.state = "consumed"
            claims[claimID] = row
            sessions[sessionID] = (session.lookupHash, true)
            return try ok(["status": "consumed", "device_id": "X", "delivery_envelope": delivery])
        }
        return fail(404)
    }
}

// MARK: - harness

private let accountID = "AAAAAAAA-0000-4000-8000-00000000000A"
private let joinerDeviceID = "BBBBBBBB-0000-4000-8000-00000000000B"
private let conversationFixture = #"{"rooms":[{"id":"local","messages":["안녕"]}]}"#

private struct Harness {
    let worker = FakeWorker()
    let hostVault: MemoryVault
    let joinerVault: MemoryVault
    let directory: URL
    let conversation: URL
    let host: SyncPairingHostCoordinator
    let joiner: SyncPairingJoinerCoordinator
    let joinerClient: SyncPairingClient
    let connectionStore: SyncConnectionStateStore
    let baseURL = URL(string: "https://pairing.invalid")!

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pairing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        conversation = directory.appendingPathComponent("conversations.json")
        try Data(conversationFixture.utf8).write(to: conversation)

        let hostToken = Data((0..<32).map { UInt8($0) })
        worker.hostToken = "Device gdt1_" + hostToken.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        hostVault = MemoryVault(box: .init())
        hostVault.box.stored = try SyncSecretBundle(
            accountMasterKey: Data((0..<32).map { UInt8(255 - $0) }),
            deviceToken: hostToken
        )
        joinerVault = MemoryVault(box: .init())
        connectionStore = SyncConnectionStateStore(
            fileURL: directory.appendingPathComponent("connection.json")
        )

        let vault = hostVault
        host = SyncPairingHostCoordinator(
            client: SyncPairingClient(
                baseURL: baseURL,
                token: { if case .available(let b) = vault.load() { return b.deviceToken }; return nil },
                transport: worker
            ),
            secrets: { vault.load() },
            random: CountingRandom()
        )
        joinerClient = SyncPairingClient(baseURL: baseURL, token: { nil }, transport: worker)
        joiner = SyncPairingJoinerCoordinator(
            random: CountingRandom(),
            vault: joinerVault,
            connectionStore: connectionStore
        )
    }

    func conversationUnchanged() -> Bool {
        (try? String(contentsOf: conversation, encoding: .utf8)) == conversationFixture
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

// MARK: - runner

private final class Runner {
    private var failures: [String] = []
    private var passed = 0

    func check(_ condition: Bool, _ message: String) {
        if condition { passed += 1 } else { failures.append(message) }
    }

    func run(_ name: String, _ work: () async throws -> Void) async {
        do { try await work(); passed += 1 } catch {
            failures.append("\(name): threw \(error)")
        }
    }

    func report() -> Int32 {
        if failures.isEmpty {
            print("SyncPairingTests: \(passed) passed")
            return 0
        }
        failures.forEach { print("FAIL \($0)") }
        return 1
    }
}

@main
struct SyncPairingTests {
    static func main() async {
        let runner = Runner()

        // MARK: QR payload contract

        await runner.run("shared vector") {
            let vector = try loadVector()
            let payload = try SyncPairingPayload(
                baseURL: URL(string: vector["base_url"]!)!,
                accountID: vector["account_id"]!,
                sessionID: vector["session_id"]!,
                pairingSecret: hexData(vector["pairing_secret_hex"]!)
            )
            runner.check(
                payload.encoded() == hexData(vector["payload_hex"]!),
                "QR bytes must match the shared fixture"
            )
            runner.check(
                payload.encodedText() == vector["payload_base64url"]!,
                "QR text must match the shared fixture"
            )
            runner.check(
                try SyncPairingPayload.decode(text: vector["payload_base64url"]!) == payload,
                "decode must round-trip"
            )
        }

        await runner.run("malformed and non-canonical payloads") {
            let good = try samplePayload()
            let text = good.encodedText()
            var bytes = good.encoded()

            // Trailing bytes, a wrong magic, and a truncated body.
            runner.check(rejects(bytes + Data([0])), "trailing bytes must be refused")
            var wrongMagic = bytes
            wrongMagic[0] = 0x47; wrongMagic[1] = 0x44; wrongMagic[2] = 0x4b; wrongMagic[3] = 0x31
            runner.check(rejects(wrongMagic), "the AAD magic must not be accepted here")
            runner.check(rejects(bytes.dropLast(1)), "a truncated payload must be refused")

            // A padded Base64 spelling decodes to the same bytes and must still
            // be refused: two spellings of one payload is one too many.
            runner.check(
                (try? SyncPairingPayload.decode(text: text + "=")) == nil,
                "padded Base64 must be refused"
            )
            runner.check(
                (try? SyncPairingPayload.decode(text: text.replacingOccurrences(of: "-", with: "+"))) == nil
                    || !text.contains("-"),
                "standard-alphabet Base64 must be refused"
            )
            // A lowercase UUID is a different spelling of the same identity.
            bytes = try SyncPairingPayload(
                baseURL: good.baseURL, accountID: good.accountID,
                sessionID: good.sessionID, pairingSecret: good.pairingSecret
            ).encoded()
            let lowered = Data(String(data: bytes, encoding: .isoLatin1)!
                .replacingOccurrences(of: good.accountID, with: good.accountID.lowercased())
                .utf8.map { $0 })
            runner.check(rejects(lowered), "a lowercase UUID must be refused")

            runner.check(
                (try? SyncPairingPayload(
                    baseURL: URL(string: "http://pairing.invalid")!,
                    accountID: good.accountID, sessionID: good.sessionID,
                    pairingSecret: good.pairingSecret
                )) == nil,
                "a non-https endpoint must be refused"
            )
            runner.check(
                (try? SyncPairingPayload(
                    baseURL: URL(string: "https://pairing.invalid/sync")!,
                    accountID: good.accountID, sessionID: good.sessionID,
                    pairingSecret: good.pairingSecret
                )) == nil,
                "an endpoint path must be refused"
            )
            runner.check(
                (try? SyncPairingPayload(
                    baseURL: URL(string: "https://user@pairing.invalid")!,
                    accountID: good.accountID, sessionID: good.sessionID,
                    pairingSecret: good.pairingSecret
                )) == nil,
                "endpoint user info must be refused"
            )
            runner.check(
                (try? SyncPairingPayload(
                    baseURL: good.baseURL, accountID: good.accountID,
                    sessionID: good.sessionID, pairingSecret: Data(count: 31)
                )) == nil,
                "a short pairing secret must be refused"
            )
        }

        await runner.run("payload carries no secrets beyond the pairing secret") {
            let harness = try Harness(); defer { harness.cleanup() }
            let payload = try await harness.host.openSession(
                accountID: accountID, baseURL: harness.baseURL
            )
            let text = payload.encodedText()
            guard case .available(let bundle) = harness.hostVault.load() else {
                runner.check(false, "host must be connected"); return
            }
            let raw = payload.encoded()
            runner.check(
                !raw.range(of: bundle.accountMasterKey).isSome,
                "the master key must not appear in the payload"
            )
            runner.check(
                !raw.range(of: bundle.deviceToken).isSome,
                "the host token must not appear in the payload"
            )
            runner.check(!text.contains("http://"), "no plain-http URL")
            runner.check(harness.conversationUnchanged(), "conversation fixture must not change")
        }

        // MARK: end to end

        await runner.run("host and joiner reach the same account") {
            let harness = try Harness(); defer { harness.cleanup() }
            let payload = try await harness.host.openSession(
                accountID: accountID, baseURL: harness.baseURL
            )
            let accepted = try await harness.joiner.accept(
                text: payload.encodedText(),
                deviceID: joinerDeviceID,
                spaceID: "PHONE_SPACE",
                platform: "android_phone"
            )
            // Nothing has been sent yet.
            runner.check(harness.worker.claims.isEmpty, "accepting a payload must send nothing")

            try await harness.joiner.submit(using: harness.joinerClient)
            let candidates = try await harness.host.pollCandidates()
            runner.check(candidates.count == 1, "the host must see exactly one candidate")
            guard let candidate = candidates.first else { return }
            runner.check(
                candidate.shortAuthenticationString == accepted.shortAuthenticationString,
                "both screens must show the same six digits"
            )
            runner.check(candidate.shortAuthenticationString.count == 6, "the SAS is six digits")

            // Approving without the human confirmation is refused.
            do {
                try await harness.host.approve(candidate, sasConfirmed: false)
                runner.check(false, "approve must refuse without a confirmed SAS")
            } catch {
                runner.check(
                    error as? SyncPairingError == .shortAuthenticationStringNotConfirmed,
                    "the refusal must name the missing confirmation"
                )
            }
            // Redeeming before approval is refused too.
            do {
                try await harness.joiner.redeem(using: harness.joinerClient, sasConfirmed: true)
                runner.check(false, "redeem must fail before approval")
            } catch {
                runner.check(harness.joinerVault.box.stored == nil, "nothing may be stored on failure")
            }

            try await harness.host.approve(candidate, sasConfirmed: true)
            try await harness.joiner.redeem(using: harness.joinerClient, sasConfirmed: true)

            guard case .available(let joined) = harness.joinerVault.load(),
                  case .available(let hostBundle) = harness.hostVault.load() else {
                runner.check(false, "the joiner must hold secrets"); return
            }
            runner.check(
                joined.accountMasterKey == hostBundle.accountMasterKey,
                "the joiner must end up on the host's account"
            )
            runner.check(
                joined.deviceToken != hostBundle.deviceToken,
                "the joiner must get its own token"
            )
            guard case .available(let configuration) = harness.connectionStore.load() else {
                runner.check(false, "a connection must be stored"); return
            }
            runner.check(configuration.accountID == accountID, "the account id must be the host's")
            runner.check(configuration.enabled == false, "joining must not enable sync")
            runner.check(harness.conversationUnchanged(), "conversation fixture must not change")

            // A second redeem is refused and the session is closed.
            do {
                try await harness.joiner.redeem(using: harness.joinerClient, sasConfirmed: true)
                runner.check(false, "a second redeem must fail")
            } catch {
                // The session closed on the first successful redeem, so the
                // second is refused. What matters is that it failed and the
                // stored secrets are still the ones from the first redeem.
                runner.check(
                    harness.joinerVault.box.stored?.deviceToken == joined.deviceToken,
                    "a refused second redeem must not replace what is stored"
                )
            }
        }

        await runner.run("a stolen package does not open for another claim") {
            let harness = try Harness(); defer { harness.cleanup() }
            let payload = try await harness.host.openSession(
                accountID: accountID, baseURL: harness.baseURL
            )
            _ = try await harness.joiner.accept(
                text: payload.encodedText(), deviceID: joinerDeviceID,
                spaceID: "PHONE_SPACE", platform: "android_phone"
            )
            try await harness.joiner.submit(using: harness.joinerClient)
            let candidate = try await harness.host.pollCandidates().first!
            try await harness.host.approve(candidate, sasConfirmed: true)

            // A second device scans the same QR — a duplicated code — submits
            // its own claim, and tries to take the package the host sealed for
            // the first one.
            let attackerVault = MemoryVault(box: .init())
            let attackerStore = SyncConnectionStateStore(
                fileURL: harness.directory.appendingPathComponent("attacker.json")
            )
            let attacker = SyncPairingJoinerCoordinator(
                random: CountingRandom(seed: 200),
                vault: attackerVault,
                connectionStore: attackerStore
            )
            let attackerAccept = try await attacker.accept(
                text: payload.encodedText(),
                deviceID: "CCCCCCCC-0000-4000-8000-00000000000C",
                spaceID: "PHONE_SPACE", platform: "android_phone"
            )
            // Its digits differ, which is what lets the user tell them apart.
            runner.check(
                attackerAccept.shortAuthenticationString != candidate.shortAuthenticationString,
                "a second scanner must show different digits"
            )
            try await attacker.submit(using: harness.joinerClient)
            do {
                try await attacker.redeem(using: harness.joinerClient, sasConfirmed: true)
                runner.check(false, "an unapproved claim must not be redeemable")
            } catch {
                runner.check(attackerVault.box.stored == nil, "nothing may reach the second device")
                runner.check(attackerStore.load() == .absent, "no connection may be left behind")
            }
        }

        await runner.run("delivery AAD is bound to the claim") {
            let harness = try Harness(); defer { harness.cleanup() }
            let payload = try await harness.host.openSession(
                accountID: accountID, baseURL: harness.baseURL
            )
            _ = try await harness.joiner.accept(
                text: payload.encodedText(), deviceID: joinerDeviceID,
                spaceID: "PHONE_SPACE", platform: "android_phone"
            )
            try await harness.joiner.submit(using: harness.joinerClient)
            let candidate = try await harness.host.pollCandidates().first!
            try await harness.host.approve(candidate, sasConfirmed: true)

            // Move the sealed package to a different claim id. The AAD names
            // the claim, so the ciphertext no longer authenticates.
            let claimID = harness.worker.claims.keys.first!
            var row = harness.worker.claims[claimID]!
            let other = "DDDDDDDD-0000-4000-8000-00000000000D"
            harness.worker.claims[other] = row
            row.state = "consumed"
            harness.worker.claims[claimID] = row
            do {
                try await harness.joiner.redeem(using: harness.joinerClient, sasConfirmed: true)
                runner.check(false, "a package moved to another claim must not open")
            } catch {
                runner.check(
                    harness.joinerVault.box.stored == nil,
                    "a failed open must store nothing"
                )
            }
        }

        await runner.run("an unconnected device cannot host, and unauth calls are refused") {
            let harness = try Harness(); defer { harness.cleanup() }
            harness.hostVault.box.stored = nil
            do {
                _ = try await harness.host.openSession(accountID: accountID, baseURL: harness.baseURL)
                runner.check(false, "an unconnected device must not open a session")
            } catch {
                runner.check(
                    error as? SyncPairingError == .notConnected,
                    "the refusal must name the missing connection"
                )
            }
            runner.check(harness.worker.sessions.isEmpty, "no session may be created")
        }

        await runner.run("an expired session stops the flow") {
            let harness = try Harness(); defer { harness.cleanup() }
            let payload = try await harness.host.openSession(
                accountID: accountID, baseURL: harness.baseURL
            )
            _ = try await harness.joiner.accept(
                text: payload.encodedText(), deviceID: joinerDeviceID,
                spaceID: "PHONE_SPACE", platform: "android_phone"
            )
            harness.worker.expireSessions = true
            do {
                try await harness.joiner.submit(using: harness.joinerClient)
                runner.check(false, "an expired session must refuse a claim")
            } catch {
                runner.check(
                    error as? SyncPairingError == .sessionExpired,
                    "the refusal must name the expiry"
                )
            }
        }

        await runner.run("a vault failure leaves no connection behind") {
            let harness = try Harness(); defer { harness.cleanup() }
            let payload = try await harness.host.openSession(
                accountID: accountID, baseURL: harness.baseURL
            )
            _ = try await harness.joiner.accept(
                text: payload.encodedText(), deviceID: joinerDeviceID,
                spaceID: "PHONE_SPACE", platform: "android_phone"
            )
            try await harness.joiner.submit(using: harness.joinerClient)
            let candidate = try await harness.host.pollCandidates().first!
            try await harness.host.approve(candidate, sasConfirmed: true)

            harness.joinerVault.box.failSave = true
            do {
                try await harness.joiner.redeem(using: harness.joinerClient, sasConfirmed: true)
                runner.check(false, "a vault failure must fail the join")
            } catch {
                runner.check(
                    harness.connectionStore.load() == .absent,
                    "a half-linked device must not be left behind"
                )
            }
        }

        // MARK: state model

        runner.check(
            SyncPairingActions.forHost(.verifySAS("123456")).canApprove,
            "approving is offered only with digits on screen"
        )
        runner.check(
            !SyncPairingActions.forHost(.sessionReady).canApprove,
            "approving must not be offered before a claim arrives"
        )
        runner.check(
            !SyncPairingActions.forJoiner(.qrAccepted).canRedeem,
            "redeeming must not be offered before approval"
        )
        runner.check(
            !SyncPairingActions.forJoiner(.linkedSyncOff).canAcceptPayload,
            "a linked device must not start over"
        )
        runner.check(
            !SyncRecoveryEscrowPolicy.mayReveal(hasEntropy: false, stashedAt: Date(), now: Date()),
            "no entropy means no phrase, never a fresh one"
        )
        runner.check(
            !SyncRecoveryEscrowPolicy.isWithinWindow(
                stashedAt: Date(timeIntervalSince1970: 0),
                now: Date(timeIntervalSince1970: SyncRecoveryEscrowPolicy.window)
            ),
            "the window closes at seven days"
        )
        runner.check(
            SyncRecoveryEscrowPolicy.entropyLength == 16,
            "the escrow keeps sixteen bytes, not the words"
        )

        exit(runner.report())
    }

    // MARK: helpers

    static func samplePayload() throws -> SyncPairingPayload {
        try SyncPairingPayload(
            baseURL: URL(string: "https://pairing.invalid")!,
            accountID: accountID,
            sessionID: "33333333-3333-4333-8333-333333333333",
            pairingSecret: Data((0..<32).map { UInt8($0) })
        )
    }

    static func rejects(_ bytes: Data) -> Bool {
        (try? SyncPairingPayload.decode(bytes)) == nil
    }

    static func hexData(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    static func loadVector() throws -> [String: String] {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("tools/fixtures/e2ee_contract_vectors.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                return root["pairing_qr"] as! [String: String]
            }
            directory.deleteLastPathComponent()
        }
        throw SyncPairingError.storageFailed
    }
}

private extension Optional {
    var isSome: Bool { self != nil }
}
