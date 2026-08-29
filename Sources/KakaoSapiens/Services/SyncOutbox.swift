import Foundation

public struct SyncOutboxEntry: Equatable {
    public let operationID: String
    public let rawBody: Data
}

public enum SyncOutboxError: Error {
    case invalidOperationID
    case invalidBody
    case replayMismatch
    case corruptStore
}

/// Atomic local journal of the exact HTTP bytes used for sync operations.
/// Retrying returns the original bytes; it never decodes and reserializes JSON.
public final class SyncOutbox: @unchecked Sendable {
    private struct Stored: Codable {
        let version: Int
        var nextOrder: UInt64
        var entries: [Entry]
    }
    private struct Entry: Codable {
        let order: UInt64
        let operationID: String
        let rawBody: Data
    }

    private static let identifier = try! NSRegularExpression(
        pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"
    )
    private static let maximumBodyBytes = 1_048_576
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) { self.fileURL = fileURL }

    @discardableResult
    public func enqueue(operationID: String, rawBody: Data) throws -> Bool {
        let range = NSRange(operationID.startIndex..<operationID.endIndex, in: operationID)
        guard Self.identifier.firstMatch(in: operationID, range: range) != nil else {
            throw SyncOutboxError.invalidOperationID
        }
        guard !rawBody.isEmpty, rawBody.count <= Self.maximumBodyBytes else { throw SyncOutboxError.invalidBody }
        return try locked {
            var store = try load()
            if let existing = store.entries.first(where: { $0.operationID == operationID }) {
                guard existing.rawBody == rawBody else { throw SyncOutboxError.replayMismatch }
                return false
            }
            store.entries.append(Entry(order: store.nextOrder, operationID: operationID, rawBody: rawBody))
            store.nextOrder += 1
            try persist(store)
            return true
        }
    }

    public func pending() throws -> [SyncOutboxEntry] {
        try locked {
            try load().entries.sorted { $0.order < $1.order }.map {
                SyncOutboxEntry(operationID: $0.operationID, rawBody: $0.rawBody)
            }
        }
    }

    @discardableResult
    public func acknowledge(operationID: String) throws -> Bool {
        try locked {
            var store = try load()
            let oldCount = store.entries.count
            store.entries.removeAll { $0.operationID == operationID }
            guard store.entries.count != oldCount else { return false }
            try persist(store)
            return true
        }
    }

    private func load() throws -> Stored {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Stored(version: 1, nextOrder: 1, entries: [])
        }
        do {
            let stored = try PropertyListDecoder().decode(Stored.self, from: Data(contentsOf: fileURL))
            guard stored.version == 1 else { throw SyncOutboxError.corruptStore }
            return stored
        } catch let error as SyncOutboxError { throw error }
        catch { throw SyncOutboxError.corruptStore }
    }

    private func persist(_ store: Stored) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListEncoder().encode(store)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func locked<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try work()
    }
}
