import Foundation

public enum SyncRemoteRoomRepositoryError: Error {
    case invalidHandle
    case corruptSnapshot
}

/// Owns only `sync/remote/rooms`; no local conversation URL or ChatStore can
/// be passed to it. Each family is replaced atomically as one property list.
public final class SyncRemoteRoomRepository: @unchecked Sendable {
    private static let spaces = Set(["MAC_SPACE", "PHONE_SPACE", "TABLET_SPACE"])
    private let rootDirectory: URL
    private let lock = NSLock()

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public func replace(_ snapshot: SyncRemoteRoomSnapshot) throws {
        try locked {
            let target = try fileURL(snapshot.handle)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try PropertyListEncoder().encode(snapshot)
            try data.write(to: target, options: [.atomic, .completeFileProtection])
        }
    }

    public func load(_ handle: SyncRoomHandle) throws -> SyncRemoteRoomSnapshot? {
        try locked {
            let target = try fileURL(handle)
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
            do {
                let snapshot = try PropertyListDecoder().decode(
                    SyncRemoteRoomSnapshot.self, from: Data(contentsOf: target)
                )
                guard snapshot.handle == handle else { throw SyncRemoteRoomRepositoryError.corruptSnapshot }
                return snapshot
            } catch let error as SyncRemoteRoomRepositoryError {
                throw error
            } catch {
                throw SyncRemoteRoomRepositoryError.corruptSnapshot
            }
        }
    }

    public func list() throws -> [SyncRemoteRoomSnapshot] {
        try locked {
            let base = rootDirectory.appendingPathComponent("sync/remote/rooms", isDirectory: true)
            guard FileManager.default.fileExists(atPath: base.path) else { return [] }
            let files = try FileManager.default.subpathsOfDirectory(atPath: base.path)
                .filter { $0.hasSuffix(".plist") }.sorted()
            return try files.map { path in
                do {
                    return try PropertyListDecoder().decode(
                        SyncRemoteRoomSnapshot.self,
                        from: Data(contentsOf: base.appendingPathComponent(path))
                    )
                } catch {
                    throw SyncRemoteRoomRepositoryError.corruptSnapshot
                }
            }
        }
    }

    private func fileURL(_ handle: SyncRoomHandle) throws -> URL {
        guard Self.spaces.contains(handle.originSpaceID) else {
            throw SyncRemoteRoomRepositoryError.invalidHandle
        }
        let room = handle.roomID.uuidString.uppercased()
        return rootDirectory
            .appendingPathComponent("sync/remote/rooms", isDirectory: true)
            .appendingPathComponent(handle.originSpaceID, isDirectory: true)
            .appendingPathComponent("\(room).plist", isDirectory: false)
    }

    private func locked<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try work()
    }
}
