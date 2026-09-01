import Foundation

public enum SyncRemoteContinuationCapability: String, Codable, Equatable {
    case chatbot
    case unsupported
}

public struct SyncRoomHandle: Codable, Hashable {
    public let originSpaceID: String
    public let roomID: UUID

    public init(originSpaceID: String, roomID: UUID) {
        self.originSpaceID = originSpaceID
        self.roomID = roomID
    }

    enum CodingKeys: String, CodingKey {
        case originSpaceID = "origin_space_id"
        case roomID = "room_id"
    }
}

public struct SyncRemoteBubble: Codable, Equatable {
    public let writerSpaceID: String
    public let turnID: UUID
    public let messageID: UUID
    public let bubbleOrder: UInt64
    public let timestamp: String
    public let sender: String
    public let kind: String
    public let text: String
    public let speakerRef: String?
    public let reactions: String?
    /// 첨부 참조. 없으면 nil이다.
    public let attachmentID: String?
    /// 첨부의 서버 상태. `SyncAttachmentDisplayState`가 이것으로 화면 상태를 정한다.
    public let attachmentState: String?

    public init(
        writerSpaceID: String,
        turnID: UUID,
        messageID: UUID,
        bubbleOrder: UInt64,
        timestamp: String,
        sender: String,
        kind: String,
        text: String,
        speakerRef: String? = nil,
        reactions: String? = nil,
        attachmentID: String? = nil,
        attachmentState: String? = nil
    ) {
        self.writerSpaceID = writerSpaceID
        self.turnID = turnID
        self.messageID = messageID
        self.bubbleOrder = bubbleOrder
        self.timestamp = timestamp
        self.sender = sender
        self.kind = kind
        self.text = text
        self.speakerRef = speakerRef
        self.reactions = reactions
        self.attachmentID = attachmentID
        self.attachmentState = attachmentState
    }

    enum CodingKeys: String, CodingKey {
        case writerSpaceID = "writer_space_id"
        case turnID = "turn_id"
        case messageID = "message_id"
        case bubbleOrder = "bubble_order"
        case timestamp, sender, kind, text
        case speakerRef = "speaker_ref"
        case reactions
        case attachmentID = "attachment_id"
        case attachmentState = "attachment_state"
    }
}

public struct SyncRemoteRoomSnapshot: Codable, Equatable {
    public let handle: SyncRoomHandle
    public let title: String
    public let writerSpaces: [String]
    public let messages: [SyncRemoteBubble]
    public let contentHash: String
    /// Missing on legacy projections: those rooms remain read-only.
    public let continuationCapability: SyncRemoteContinuationCapability?
    /// 비어 있지 않으면 이어쓰기가 막힌다. 옛 projection에는 없다.
    public let unsupportedReason: String?

    public init(
        handle: SyncRoomHandle,
        title: String,
        writerSpaces: [String],
        messages: [SyncRemoteBubble],
        contentHash: String,
        continuationCapability: SyncRemoteContinuationCapability? = nil,
        unsupportedReason: String? = nil
    ) {
        self.handle = handle
        self.title = title
        self.writerSpaces = writerSpaces
        self.messages = messages
        self.contentHash = contentHash
        self.continuationCapability = continuationCapability
        self.unsupportedReason = unsupportedReason
    }

    enum CodingKeys: String, CodingKey {
        case handle, title, messages, continuationCapability, unsupportedReason
        case writerSpaces = "writer_spaces"
        case contentHash = "content_hash"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        handle = try values.decode(SyncRoomHandle.self, forKey: .handle)
        title = try values.decode(String.self, forKey: .title)
        writerSpaces = try values.decode([String].self, forKey: .writerSpaces)
        messages = try values.decode([SyncRemoteBubble].self, forKey: .messages)
        contentHash = try values.decode(String.self, forKey: .contentHash)
        continuationCapability = try values.decodeIfPresent(SyncRemoteContinuationCapability.self, forKey: .continuationCapability)
        unsupportedReason = try values.decodeIfPresent(String.self, forKey: .unsupportedReason)
    }
}
