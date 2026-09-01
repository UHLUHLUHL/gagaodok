import Foundation

public enum SyncRemoteReplyStage: String, Codable, CaseIterable {
    case prepared, roomReady, turnCreated, userBubbleCreated, aiBubbleCreated, complete

    fileprivate var rank: Int { Self.allCases.firstIndex(of: self)! }
}

public struct SyncRemoteReplyOperation: Codable, Equatable {
    public let operationID: String
    public let rawBody: Data

    public init(operationID: String, rawBody: Data) {
        self.operationID = operationID
        self.rawBody = rawBody
    }
}

public struct SyncRemoteReplyJournalEntry: Codable, Equatable {
    public let replyID: String
    public let handle: SyncRoomHandle
    public let writerSpaceID: String
    public let userText: String
    public var stage: SyncRemoteReplyStage
    public var operations: [SyncRemoteReplyOperation]
    fileprivate var acknowledgedOperationIDs: Set<String>
    fileprivate var observedOperationIDs: Set<String>
}

public enum SyncRemoteReplyJournalError: Error {
    case invalidReply
    case invalidOperation
    case duplicateOperation
    case missingReply
    case stageRegression
    case conflictRebuild
    case corruptStore
}

/// Durable local record for a remote-room reply.  It preserves exact encrypted
/// operation bytes, so a restart can replay rather than reconstruct a request.
public final class SyncRemoteReplyJournal: @unchecked Sendable {
    private struct Store: Codable { var version: Int; var entries: [SyncRemoteReplyJournalEntry] }
    private static let identifier = try! NSRegularExpression(pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")
    private static let maximumBodyBytes = 1_048_576
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func prepare(replyID: String, handle: SyncRoomHandle, writerSpaceID: String, userText: String, operations: [SyncRemoteReplyOperation]) throws {
        guard valid(replyID), !writerSpaceID.isEmpty, !userText.isEmpty, !operations.isEmpty else { throw SyncRemoteReplyJournalError.invalidReply }
        try validate(operations)
        try locked {
            var store = try load()
            let entry = SyncRemoteReplyJournalEntry(replyID: replyID, handle: handle, writerSpaceID: writerSpaceID, userText: userText, stage: .prepared, operations: operations, acknowledgedOperationIDs: [], observedOperationIDs: [])
            if let existing = store.entries.first(where: { $0.replyID == replyID }) {
                guard existing == entry else { throw SyncRemoteReplyJournalError.invalidReply }
                return
            }
            store.entries.append(entry)
            try persist(store)
        }
    }

    public func entry(_ replyID: String) -> SyncRemoteReplyJournalEntry? {
        try? locked { try load().entries.first { $0.replyID == replyID } }
    }

    public func advance(replyID: String, to stage: SyncRemoteReplyStage) throws {
        try change(replyID) { entry in
            guard stage.rank >= entry.stage.rank else { throw SyncRemoteReplyJournalError.stageRegression }
            entry.stage = stage
        }
    }

    public func acknowledge(replyID: String, operationID: String) throws {
        try change(replyID) { entry in
            guard entry.operations.contains(where: { $0.operationID == operationID }) else { throw SyncRemoteReplyJournalError.invalidOperation }
            entry.acknowledgedOperationIDs.insert(operationID)
        }
    }

    public func observeProjection(replyID: String, operationID: String) throws {
        try locked {
            var store = try load()
            guard let index = store.entries.firstIndex(where: { $0.replyID == replyID }) else { throw SyncRemoteReplyJournalError.missingReply }
            guard store.entries[index].operations.contains(where: { $0.operationID == operationID }) else { throw SyncRemoteReplyJournalError.invalidOperation }
            store.entries[index].observedOperationIDs.insert(operationID)
            let entry = store.entries[index]
            if entry.stage == .complete && Set(entry.operations.map(\.operationID)).isSubset(of: entry.observedOperationIDs) {
                store.entries.remove(at: index)
            }
            try persist(store)
        }
    }

    public func rebuildForBubbleOrderConflict(replyID: String, userBubbleAcknowledged: Bool, replacementUser: SyncRemoteReplyOperation?, replacementAI: SyncRemoteReplyOperation) throws {
        try validate([replacementAI] + (replacementUser.map { [$0] } ?? []))
        try change(replyID) { entry in
            guard entry.operations.count >= 2 else { throw SyncRemoteReplyJournalError.conflictRebuild }
            if userBubbleAcknowledged {
                guard replacementUser == nil else { throw SyncRemoteReplyJournalError.conflictRebuild }
                entry.operations[entry.operations.count - 1] = replacementAI
            } else {
                guard let replacementUser else { throw SyncRemoteReplyJournalError.conflictRebuild }
                entry.operations.removeLast(2)
                entry.operations += [replacementUser, replacementAI]
            }
            try validate(entry.operations)
            entry.acknowledgedOperationIDs.formIntersection(Set(entry.operations.map(\.operationID)))
            entry.observedOperationIDs.formIntersection(Set(entry.operations.map(\.operationID)))
        }
    }

    private func change(_ replyID: String, _ mutate: (inout SyncRemoteReplyJournalEntry) throws -> Void) throws {
        try locked {
            var store = try load()
            guard let index = store.entries.firstIndex(where: { $0.replyID == replyID }) else { throw SyncRemoteReplyJournalError.missingReply }
            try mutate(&store.entries[index])
            try persist(store)
        }
    }

    private func validate(_ operations: [SyncRemoteReplyOperation]) throws {
        var ids = Set<String>()
        for operation in operations {
            guard valid(operation.operationID), !operation.rawBody.isEmpty, operation.rawBody.count <= Self.maximumBodyBytes else { throw SyncRemoteReplyJournalError.invalidOperation }
            guard ids.insert(operation.operationID).inserted else { throw SyncRemoteReplyJournalError.duplicateOperation }
        }
    }

    private func valid(_ value: String) -> Bool {
        Self.identifier.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) != nil
    }

    private func load() throws -> Store {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Store(version: 1, entries: []) }
        do {
            let store = try PropertyListDecoder().decode(Store.self, from: Data(contentsOf: fileURL))
            guard store.version == 1 else { throw SyncRemoteReplyJournalError.corruptStore }
            return store
        } catch let error as SyncRemoteReplyJournalError { throw error }
        catch { throw SyncRemoteReplyJournalError.corruptStore }
    }

    private func persist(_ store: Store) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListEncoder().encode(store).write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func locked<T>(_ work: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try work() }
}
