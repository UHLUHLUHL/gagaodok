import Foundation

private final class TransitionModelService: SyncAccountTransitionServicing {
    var availabilityValue: SyncTransitionAvailability
    var unlinked = 0
    init(_ availability: SyncTransitionAvailability) { availabilityValue = availability }
    func availability() -> SyncTransitionAvailability { availabilityValue }
    func unlink() throws { unlinked += 1 }
}

@main
struct SyncAccountTransitionModelTests {
    static func main() {
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures += 1; print("FAIL \(message)") }
        }

        let readyService = TransitionModelService(.ready)
        let ready = SyncAccountTransitionModel(service: readyService)
        ready.refresh()
        check(ready.actions.canRequestJoin, "ready account can request join")
        check(ready.actions.canRequestUnlink, "ready account can request unlink")
        check(!ready.actions.canStartJoin, "join cannot start before confirmation")
        ready.requestJoin()
        check(ready.state == .confirmingJoin, "join requires confirmation")
        ready.confirmJoin()
        check(ready.state == .joining, "confirmed join exposes pairing surface")
        check(ready.actions.canStartJoin, "confirmed join can start")

        for blocked in [SyncTransitionAvailability.syncEnabled, .outboxPending] {
            let model = SyncAccountTransitionModel(service: TransitionModelService(blocked))
            model.refresh()
            check(model.state == .blocked, "unsafe account is blocked")
            check(!model.actions.canRequestJoin && !model.actions.canRequestUnlink, "blocked account exposes no mutation")
        }

        let unlinkService = TransitionModelService(.ready)
        let unlink = SyncAccountTransitionModel(service: unlinkService)
        unlink.refresh()
        unlink.requestUnlink()
        check(unlinkService.unlinked == 0, "request alone never unlinks")
        unlink.confirmUnlink()
        check(unlinkService.unlinked == 1, "confirmation unlinks once")
        check(unlink.state == .unlinked, "successful unlink is visible")

        if failures > 0 { exit(1) }
        print("Sync account transition model tests passed (12)")
    }
}
