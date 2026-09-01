import Foundation

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
        reactions: String? = nil
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
    }

    enum CodingKeys: String, CodingKey {
        case writerSpaceID = "writer_space_id"
        case turnID = "turn_id"
        case messageID = "message_id"
        case bubbleOrder = "bubble_order"
        case timestamp, sender, kind, text
        case speakerRef = "speaker_ref"
        case reactions
    }
}

public struct SyncRemoteRoomSnapshot: Codable, Equatable {
    public let handle: SyncRoomHandle
    public let title: String
    public let writerSpaces: [String]
    public let messages: [SyncRemoteBubble]
    public let contentHash: String

    public init(
        handle: SyncRoomHandle,
        title: String,
        writerSpaces: [String],
        messages: [SyncRemoteBubble],
        contentHash: String
    ) {
        self.handle = handle
        self.title = title
        self.writerSpaces = writerSpaces
        self.messages = messages
        self.contentHash = contentHash
    }

    enum CodingKeys: String, CodingKey {
        case handle, title, messages
        case writerSpaces = "writer_spaces"
        case contentHash = "content_hash"
    }
}
