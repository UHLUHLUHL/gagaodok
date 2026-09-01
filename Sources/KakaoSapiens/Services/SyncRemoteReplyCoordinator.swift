import Foundation

/// Keeps a continuation durable before any network drain. Runtime scheduling
/// later owns delivery; this coordinator never sends in the background.
@MainActor public final class SyncRemoteReplyCoordinator {
    private let builder: SyncRemoteReplyBuilder, journal: SyncRemoteReplyJournal, outbox: SyncOutbox
    public init(builder: SyncRemoteReplyBuilder, journal: SyncRemoteReplyJournal, outbox: SyncOutbox) { self.builder = builder; self.journal = journal; self.outbox = outbox }
    public func prepare(room: SyncRemoteRoomSnapshot, writerSpaceID: String, userText: String, selectedModel: AIModel, response: String) throws -> SyncRemoteReplyPlan {
        let plan = try builder.prepareReply(room: room, writerSpaceID: writerSpaceID, userText: userText, assistantText: response, selectedGeminiModel: selectedModel)
        let replyID = UUID().uuidString.uppercased()
        try journal.prepare(replyID: replyID, handle: room.handle, writerSpaceID: writerSpaceID, userText: userText, operations: plan.operations)
        for operation in plan.operations { _ = try outbox.enqueue(operationID: operation.operationID, rawBody: operation.rawBody) }
        return plan
    }
}
