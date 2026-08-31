import Combine
import Foundation

public enum SyncShadowUploadStage: Equatable {
    case idle
    case running
    case finished(SyncShadowUploadReport)
    case failed(SyncShadowUploadError)
}

/// The screen's view of one shadow pass.
///
/// The designated room is fixed at construction rather than chosen in the UI.
/// A picker over every room is one misclick away from copying a conversation
/// nobody agreed to copy, and this phase is explicitly one room only.
@MainActor
public final class SyncShadowUploadModel: ObservableObject {
    @Published public private(set) var stage: SyncShadowUploadStage = .idle

    private let coordinator: SyncShadowUploadCoordinator
    private let roomID: UUID
    private let storageDirectory: URL

    public init(coordinator: SyncShadowUploadCoordinator, roomID: UUID, storageDirectory: URL) {
        self.coordinator = coordinator
        self.roomID = roomID
        self.storageDirectory = storageDirectory
    }

    public var canRun: Bool {
        switch stage {
        case .idle, .failed: return true
        case .running, .finished: return false
        }
    }

    public func run() async {
        guard canRun else { return }
        stage = .running
        do {
            stage = .finished(try await coordinator.run(roomID: roomID, storageDirectory: storageDirectory))
        } catch let error as SyncShadowUploadError {
            stage = .failed(error)
        } catch {
            stage = .failed(.transport)
        }
    }
}
