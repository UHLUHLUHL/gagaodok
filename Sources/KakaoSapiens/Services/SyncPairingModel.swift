import Foundation

/// The states a pairing screen can be in, on each side.
///
/// The states live here rather than in a view for the same reason the
/// onboarding states do: a view that decides for itself when to show a button
/// can offer an action the state machine considers unsafe. Approving without a
/// confirmed SAS is exactly such an action.
public enum SyncPairingHostState: Equatable {
    case idle
    /// A session exists and the payload is on screen.
    case sessionReady
    case waitingClaim
    /// A device is waiting and the six digits are shown for comparison.
    case verifySAS(String)
    case approving
    case completed
    case expired
    case error(SyncPairingError)
}

public enum SyncPairingJoinerState: Equatable {
    case idle
    /// A payload has been read. Nothing has been sent.
    case qrAccepted
    case submitting
    case verifySAS(String)
    case waitingApproval
    case redeeming
    /// Joined, and deliberately not synchronising.
    case linkedSyncOff
    case error(SyncPairingError)
}

/// What each side may offer right now. Derived from the state, never decided
/// in a view.
public struct SyncPairingActions: Equatable {
    public var canOpenSession = false
    public var canPoll = false
    public var canApprove = false
    public var canAcceptPayload = false
    public var canSubmit = false
    public var canRedeem = false

    public static func forHost(_ state: SyncPairingHostState) -> SyncPairingActions {
        var actions = SyncPairingActions()
        switch state {
        case .idle, .expired, .error: actions.canOpenSession = true
        case .sessionReady, .waitingClaim: actions.canPoll = true
        // Approving is offered only once digits are on screen to compare, and
        // the coordinator still refuses without an explicit confirmation.
        case .verifySAS: actions.canApprove = true
        case .approving, .completed: break
        }
        return actions
    }

    public static func forJoiner(_ state: SyncPairingJoinerState) -> SyncPairingActions {
        var actions = SyncPairingActions()
        switch state {
        case .idle, .error: actions.canAcceptPayload = true
        case .qrAccepted: actions.canSubmit = true
        // Redeeming before the host approves would be a guess; the joiner waits
        // for the human comparison on both screens first.
        case .verifySAS, .waitingApproval: actions.canRedeem = true
        case .submitting, .redeeming, .linkedSyncOff: break
        }
        return actions
    }
}
