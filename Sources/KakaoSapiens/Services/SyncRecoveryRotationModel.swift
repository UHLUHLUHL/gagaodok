import Combine
import Foundation

/// The screen's view of a rotation.
///
/// A thin observable wrapper: every decision stays in the coordinator, and the
/// only thing added here is `typedPhrase`, which the card binds a text field to
/// and which is cleared the moment it is no longer needed.
@MainActor
public final class SyncRecoveryRotationModel: ObservableObject {
    @Published public private(set) var stage: SyncRecoveryRotationStage = .idle
    @Published public var typedPhrase: String = ""
    @Published public private(set) var isWorking = false

    private let coordinator: SyncRecoveryRotationCoordinator

    public init(coordinator: SyncRecoveryRotationCoordinator) {
        self.coordinator = coordinator
    }

    public var canIssue: Bool {
        switch stage {
        case .idle, .failed: return !isWorking
        case .awaitingConfirmation, .confirmed: return false
        }
    }

    /// The next version to claim. The Worker refuses anything that is not one
    /// past its current record, so a wrong guess is a conflict rather than an
    /// overwrite.
    public func issue(nextVersion: UInt32) async {
        guard canIssue else { return }
        isWorking = true
        await coordinator.issue(nextVersion: nextVersion)
        stage = coordinator.stage
        isWorking = false
    }

    public func confirm() {
        guard case .awaitingConfirmation = stage else { return }
        _ = coordinator.confirm(typedPhrase: typedPhrase)
        stage = coordinator.stage
        // Whether it matched or not, the typed words do not stay in memory.
        typedPhrase = ""
    }

    public func retryConfirmation() {
        coordinator.retryConfirmation()
        stage = coordinator.stage
        typedPhrase = ""
    }
}
