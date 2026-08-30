import Foundation

public enum SyncTransitionAvailability {
    case ready
    case syncEnabled
    case outboxPending
    case noActiveAccount
    case recoveryRequired
}

public protocol SyncAccountTransitionServicing {
    func availability() -> SyncTransitionAvailability
    func unlink() throws
}

public enum SyncAccountTransitionUIState: Equatable {
    case idle
    case ready
    case blocked
    case confirmingJoin
    case joining
    case confirmingUnlink
    case unlinking
    case unlinked
    case error
}

public struct SyncAccountTransitionActions: Equatable {
    public var canRequestJoin = false
    public var canConfirmJoin = false
    public var canStartJoin = false
    public var canRequestUnlink = false
    public var canConfirmUnlink = false
    public var canDismiss = false
}

@MainActor
public final class SyncAccountTransitionModel: ObservableObject {
    @Published public private(set) var state: SyncAccountTransitionUIState = .idle
    private let service: SyncAccountTransitionServicing

    public init(service: SyncAccountTransitionServicing) { self.service = service }

    public var actions: SyncAccountTransitionActions {
        switch state {
        case .ready:
            return SyncAccountTransitionActions(canRequestJoin: true, canRequestUnlink: true)
        case .confirmingJoin:
            return SyncAccountTransitionActions(canConfirmJoin: true, canDismiss: true)
        case .joining:
            return SyncAccountTransitionActions(canStartJoin: true, canDismiss: true)
        case .confirmingUnlink:
            return SyncAccountTransitionActions(canConfirmUnlink: true, canDismiss: true)
        case .error:
            return SyncAccountTransitionActions(canDismiss: true)
        default:
            return SyncAccountTransitionActions()
        }
    }

    public func refresh() {
        state = service.availability() == .ready ? .ready : .blocked
    }

    public func requestJoin() {
        if actions.canRequestJoin { state = .confirmingJoin }
    }

    public func confirmJoin() {
        if actions.canConfirmJoin { state = .joining }
    }

    public func requestUnlink() {
        if actions.canRequestUnlink { state = .confirmingUnlink }
    }

    public func confirmUnlink() {
        guard actions.canConfirmUnlink else { return }
        state = .unlinking
        do { try service.unlink(); state = .unlinked }
        catch { state = .error }
    }

    public func dismiss() {
        if actions.canDismiss { refresh() }
    }
}
