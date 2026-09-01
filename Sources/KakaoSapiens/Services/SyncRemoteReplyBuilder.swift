import Foundation

public struct SyncRemoteReplyPlan {
    public let handle: SyncRoomHandle
    public let writerSpaceID: String
    public let turnID: UUID
    public let userMessageID: UUID
    public let aiMessageID: UUID
    public let operations: [SyncRemoteReplyOperation]
}
public enum SyncRemoteReplyBuilderError: Error { case unsupportedRoom, unsupportedModel, invalidText, encryption }

/// Produces only Worker operations. Cache and affection remain device-local by
/// construction because this type has neither field nor input for either.
public final class SyncRemoteReplyBuilder {
    private let accountID: String, deviceID: String, masterKey: Data
    private let now: () -> Date
    public init(accountID: String, deviceID: String, masterKey: Data, now: @escaping () -> Date = Date.init) { self.accountID = accountID; self.deviceID = deviceID; self.masterKey = masterKey; self.now = now }

    public func prepareReply(room: SyncRemoteRoomSnapshot, writerSpaceID: String, userText: String, assistantText: String, selectedGeminiModel: AIModel) throws -> SyncRemoteReplyPlan {
        guard room.continuationCapability == .chatbot else { throw SyncRemoteReplyBuilderError.unsupportedRoom }
        guard selectedGeminiModel == .gemini37Flash else { throw SyncRemoteReplyBuilderError.unsupportedModel }
        guard !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !assistantText.isEmpty else { throw SyncRemoteReplyBuilderError.invalidText }
        let roomID = room.handle.roomID.uuidString.uppercased(), turn = UUID(), user = UUID(), ai = UUID()
        let scope = SyncE2EE.Scope(accountID: accountID, spaceID: writerSpaceID, roomID: roomID, worldlineID: nil)
        guard let keys = try? SyncE2EE.deriveScopeKeys(accountMasterKey: masterKey, scope: scope) else { throw SyncRemoteReplyBuilderError.encryption }
        var operations: [SyncRemoteReplyOperation] = []
        if !room.writerSpaces.contains(writerSpaceID) { operations.append(try body(["op":"create_room","entity_type":"room","target":["space_id":writerSpaceID,"room_id":roomID,"worldline_id":NSNull()],"metadata_set":["origin_space_id":room.handle.originSpaceID],"set":["title":try seal(room.title, scope, keys, "room", roomID, "title", nil),"extensions.gagaodok.room.continuation_capability":try seal("chatbot", scope, keys, "room", roomID, "extensions.gagaodok.room.continuation_capability", nil)] ])) }
        operations.append(try body(["op":"create_turn","entity_type":"turn","target":["space_id":writerSpaceID,"room_id":roomID,"worldline_id":NSNull(),"turn_id":turn.uuidString.uppercased()],"metadata_set":["created_by_device_id":deviceID,"created_at":timestamp()],"set":[:] ]))
        operations.append(try bubble(roomID, writerSpaceID, turn, user, 1, "나", userText, scope, keys))
        operations.append(try bubble(roomID, writerSpaceID, turn, ai, 2, "사피엔스", assistantText, scope, keys))
        return SyncRemoteReplyPlan(handle: room.handle, writerSpaceID: writerSpaceID, turnID: turn, userMessageID: user, aiMessageID: ai, operations: operations)
    }
    private func bubble(_ room: String, _ space: String, _ turn: UUID, _ id: UUID, _ order: UInt64, _ sender: String, _ text: String, _ scope: SyncE2EE.Scope, _ keys: SyncE2EE.ScopeKeys) throws -> SyncRemoteReplyOperation { let message = id.uuidString.uppercased(); return try body(["op":"create_bubble","entity_type":"bubble","target":["space_id":space,"room_id":room,"worldline_id":NSNull(),"turn_id":turn.uuidString.uppercased(),"message_id":message],"bubble_order":order,"metadata_set":["timestamp":timestamp()],"set":["sender":try seal(sender,scope,keys,"bubble",message,"sender",order),"kind":try seal("speech",scope,keys,"bubble",message,"kind",order),"text":try seal(text,scope,keys,"bubble",message,"text",order)]]) }
    private func seal(_ text: String, _ scope: SyncE2EE.Scope, _ keys: SyncE2EE.ScopeKeys, _ type: String, _ id: String, _ field: String, _ order: UInt64?) throws -> String { var generator = SystemRandomNumberGenerator(); let nonce = Data((0..<12).map { _ in UInt8.random(in: .min ... .max, using: &generator) }); guard let sealed = try? SyncE2EE.seal(plaintext: Data(text.utf8), key: keys.fieldAEADKey, nonce: nonce, context: .init(scope: scope, entityType: type, entityID: id, fieldPath: field, bubbleOrder: order, recoveryVersion: nil)) else { throw SyncRemoteReplyBuilderError.encryption }; return sealed.base64EncodedString() }
    private func body(_ values: [String:Any]) throws -> SyncRemoteReplyOperation { let id = UUID().uuidString.uppercased(); var json:[String:Any] = ["protocol_version":1,"operation_id":id,"device_id":deviceID,"metadata_clear":[],"clear":[],"created_at":timestamp()]; values.forEach { json[$0.key] = $0.value }; guard let raw = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { throw SyncRemoteReplyBuilderError.encryption }; return .init(operationID:id,rawBody:raw) }
    private func timestamp() -> String { let f = ISO8601DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 0); f.formatOptions = [.withInternetDateTime]; return f.string(from: now()) }
}
