import Combine
import Foundation

public enum SyncShadowReadStage: Equatable {
    case idle
    case running
    case finished(SyncShadowReadResult)
    case failed(SyncShadowReadError)
}

/// The screen's view of reading a room another device owns.
///
/// The room is identified by the id the writing device reported, typed in
/// rather than discovered: this device has no local copy of that room, so there
/// is nothing here to pick from a list.
@MainActor
public final class SyncShadowReadModel: ObservableObject {
    @Published public private(set) var stage: SyncShadowReadStage = .idle
    @Published public var roomIDText: String = ""

    private let reader: SyncShadowReader

    public init(reader: SyncShadowReader) { self.reader = reader }

    public var canRun: Bool {
        switch stage {
        case .running: return false
        default: return UUID(uuidString: roomIDText.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }
    }

    public func run() async {
        guard
            let roomID = UUID(uuidString: roomIDText.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        stage = .running
        do {
            stage = .finished(try await reader.read(roomID: roomID))
        } catch let error as SyncShadowReadError {
            stage = .failed(error)
        } catch {
            stage = .failed(.transport)
        }
    }
}
