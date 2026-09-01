import Foundation

public enum SyncRoomExposurePolicy {
    /// Product decisions 3 and 5. Own-space rooms remain in the existing local
    /// list, so they are deliberately false here.
    public static func isVisible(originSpaceID: String, viewerSpaceID: String) -> Bool {
        switch (originSpaceID, viewerSpaceID) {
        case ("MAC_SPACE", "PHONE_SPACE"),
             ("TABLET_SPACE", "MAC_SPACE"),
             ("TABLET_SPACE", "PHONE_SPACE"):
            return true
        default:
            return false
        }
    }
}

/// A read-only boundary used by the UI. It can list and open the dedicated
/// remote repository, but has no reference to ChatRoomManager or local files.
public struct SyncRemoteRoomCatalog {
    private let repository: SyncRemoteRoomRepository
    private let viewerSpaceID: String

    public init(repository: SyncRemoteRoomRepository, viewerSpaceID: String) {
        self.repository = repository
        self.viewerSpaceID = viewerSpaceID
    }

    public func refresh() throws -> [SyncRemoteRoomSnapshot] {
        try repository.list()
            .filter {
                SyncRoomExposurePolicy.isVisible(
                    originSpaceID: $0.handle.originSpaceID,
                    viewerSpaceID: viewerSpaceID
                )
            }
            .sorted {
                let left = $0.messages.last?.timestamp ?? ""
                let right = $1.messages.last?.timestamp ?? ""
                if left != right { return left > right }
                return $0.handle.roomID.uuidString < $1.handle.roomID.uuidString
            }
    }

    public func open(_ handle: SyncRoomHandle) throws -> SyncRemoteRoomSnapshot? {
        guard SyncRoomExposurePolicy.isVisible(
            originSpaceID: handle.originSpaceID,
            viewerSpaceID: viewerSpaceID
        ) else { return nil }
        return try repository.load(handle)
    }
}
