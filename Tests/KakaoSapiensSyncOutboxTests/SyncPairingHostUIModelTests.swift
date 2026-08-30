import CoreGraphics
import Foundation

private final class HostServiceDouble: SyncPairingHostServicing, @unchecked Sendable {
    var opened = 0
    var polled = 0
    var approved = 0
    var candidates: [SyncPairingCandidate] = []

    func openSession(accountID: String, baseURL: URL) async throws -> SyncPairingPayload {
        opened += 1
        return try SyncPairingPayload(
            baseURL: baseURL,
            accountID: accountID,
            sessionID: "33333333-3333-4333-8333-333333333333",
            pairingSecret: Data(repeating: 7, count: 32)
        )
    }

    func pollCandidates() async throws -> [SyncPairingCandidate] {
        polled += 1
        return candidates
    }

    func approve(_ candidate: SyncPairingCandidate, sasConfirmed: Bool) async throws {
        guard sasConfirmed else { throw SyncPairingError.shortAuthenticationStringNotConfirmed }
        approved += 1
    }
}

@main
struct SyncPairingHostUIModelTests {
    @MainActor static func main() async {
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures += 1
                print("FAIL \(message)")
            }
        }

        let service = HostServiceDouble()
        let model = SyncPairingHostUIModel(service: service)
        check(model.state == .idle, "host starts idle")
        check(model.qrText == nil, "idle has no QR")
        check(service.opened == 0, "constructing the model sends no request")

        await model.openSession(
            accountID: "AAAAAAAA-0000-4000-8000-00000000000A",
            baseURL: URL(string: "https://pairing.invalid")!
        )
        check(service.opened == 1, "opening makes one session")
        check(model.state == .sessionReady, "opened session is ready")
        check(model.qrText?.isEmpty == false, "opened session exposes QR text")
        check(model.actions.canPoll, "ready session can poll")
        check(!model.actions.canApprove, "ready session cannot approve")

        await model.poll()
        check(service.polled == 1, "poll calls service once")
        check(model.state == .waitingClaim, "empty poll waits")

        let candidate = SyncPairingCandidate(
            claimID: "44444444-4444-4444-8444-444444444444",
            claimLookup: Data(repeating: 1, count: 32),
            shortAuthenticationString: "842588",
            deviceID: "BBBBBBBB-0000-4000-8000-00000000000B",
            spaceID: "PHONE_SPACE",
            platform: "android_phone",
            claimSecret: Data(repeating: 2, count: 32)
        )
        service.candidates = [candidate]
        await model.poll()
        check(model.state == .verifySAS("842588"), "candidate exposes exact SAS")
        check(model.actions.canApprove, "SAS state can approve")

        await model.approve(confirmed: false)
        check(service.approved == 0, "unconfirmed SAS never approves")
        check(model.state == .verifySAS("842588"), "refusal preserves SAS state")

        await model.approve(confirmed: true)
        check(service.approved == 1, "confirmed SAS approves once")
        check(model.state == .completed, "approval completes host")
        check(model.qrText == nil, "completion clears QR text")

        check(SyncPairingQRCodeRenderer.cgImage(from: "") == nil, "empty QR is refused")
        let image = SyncPairingQRCodeRenderer.cgImage(from: "R0RQMQ")
        check(image != nil && image!.width > 0 && image!.height > 0, "fixture text renders a bitmap")

        let disabled = try! SyncConnectionConfiguration(
            baseURL: URL(string: "https://pairing.invalid")!,
            accountID: "AAAAAAAA-0000-4000-8000-00000000000A",
            deviceID: "BBBBBBBB-0000-4000-8000-00000000000B",
            enabled: false,
            changesCursor: nil
        )
        let enabled = try! SyncConnectionConfiguration(
            baseURL: disabled.baseURL,
            accountID: disabled.accountID,
            deviceID: disabled.deviceID,
            enabled: true,
            changesCursor: nil
        )
        check(!SyncPairingHostAvailability.canHost(connection: nil), "absent connection cannot host")
        check(SyncPairingHostAvailability.canHost(connection: disabled), "sync-off connection can host")
        check(!SyncPairingHostAvailability.canHost(connection: enabled), "enabled connection cannot host in synthetic UI")

        if failures > 0 { exit(1) }
        print("SyncPairingHostUIModelTests: 21 passed")
    }
}
