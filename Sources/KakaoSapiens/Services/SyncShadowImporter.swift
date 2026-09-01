import CryptoKit
import Foundation

/// What one import produced, in numbers only.
///
/// Deliberately content-free. This is what gets compared against the remote
/// projection and what a report may show, so a room's title, a bubble's text
/// and every plaintext identifier of the user's own making stay out of it.
public struct SyncShadowManifest: Equatable {
    public struct Room: Equatable {
        public let roomID: String
        public let turnCount: Int
        public let bubbleCount: Int
        /// SHA-256 over the room's canonical bubble identities and order —
        /// never over the text. Two devices agreeing on this agree on what was
        /// copied without either revealing what it says.
        public let contentHash: String
    }

    public let importBatchID: String
    public let rooms: [Room]

    public var operationCount: Int {
        rooms.reduce(0) { $0 + 1 + $1.turnCount + $1.bubbleCount }
    }
}

public enum SyncShadowImportError: Error, Equatable {
    case secretsUnavailable
    case invalidScope
    case encryptionFailed
    case outboxFailed
}

/// One room's plaintext, as read from local storage.
///
/// A plain input struct rather than a reference to the live store: the
/// importer is handed a snapshot and cannot reach back into the app's model,
/// which is what makes "no write-back to the original" a property of the type
/// rather than a promise in a comment.
public struct SyncShadowRoomInput {
    public struct Bubble {
        public let messageID: UUID
        public let turnID: UUID
        public let sender: String
        public let kind: String
        public let text: String
        public let timestamp: Date

        public init(messageID: UUID, turnID: UUID, sender: String, kind: String, text: String, timestamp: Date) {
            self.messageID = messageID
            self.turnID = turnID
            self.sender = sender
            self.kind = kind
            self.text = text
            self.timestamp = timestamp
        }
    }

    public let roomID: UUID
    public let title: String
    public let bubbles: [Bubble]
    public let continuationCapability: Bool

    public init(roomID: UUID, title: String, bubbles: [Bubble], continuationCapability: Bool = false) {
        self.roomID = roomID
        self.title = title
        self.bubbles = bubbles
        self.continuationCapability = continuationCapability
    }
}

/// Local conversation → encrypted canonical operations → durable outbox.
///
/// One direction only. Nothing here opens the app's own message files for
/// writing, and nothing the Worker returns is applied to them: the shadow copy
/// is a projection the conversation screens never consult. That is what makes
/// a failed import cost nothing but a retry.
///
/// Every field that carries meaning is sealed before it reaches an operation
/// body. What stays plaintext is exactly what the canonical schema puts in
/// plaintext metadata — timestamps, the originating device, ordering — because
/// D1 has to index it. Titles, sender, kind and text do not.
public struct SyncShadowImporter {
    private let accountID: String
    private let deviceID: String
    private let originSpaceID: String
    private let writerSpaceID: String
    private let masterKey: Data
    private let randomBytes: (Int) -> Data
    private let identifier: () -> String
    private let now: () -> Date

    public init(
        accountID: String,
        deviceID: String,
        originSpaceID: String? = nil,
        writerSpaceID: String = "MAC_SPACE",
        masterKey: Data,
        randomBytes: @escaping (Int) -> Data = SyncShadowImporter.systemRandom,
        identifier: @escaping () -> String = { UUID().uuidString.uppercased() },
        now: @escaping () -> Date = Date.init
    ) {
        self.accountID = accountID
        self.deviceID = deviceID
        self.originSpaceID = originSpaceID ?? writerSpaceID
        self.writerSpaceID = writerSpaceID
        self.masterKey = masterKey
        self.randomBytes = randomBytes
        self.identifier = identifier
        self.now = now
    }

    public static func systemRandom(_ count: Int) -> Data {
        var bytes = Data(count: count)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return bytes
    }

    /// Convert and enqueue. Returns the manifest describing what was queued.
    ///
    /// `bubbleOrder` continues from wherever the caller left off: the Worker
    /// accepts only the next order for a scope, so a second import into the
    /// same room must not restart at zero.
    @discardableResult
    public func importRooms(
        _ rooms: [SyncShadowRoomInput],
        into outbox: SyncOutbox,
        startingBubbleOrder: UInt64 = 0
    ) throws -> SyncShadowManifest {
        let batchID = identifier()
        var manifestRooms: [SyncShadowManifest.Room] = []
        var bubbleOrder = startingBubbleOrder

        for room in rooms {
            let roomID = room.roomID.uuidString.uppercased()
            let scope = SyncE2EE.Scope(
                accountID: accountID,
                spaceID: writerSpaceID,
                roomID: roomID,
                worldlineID: nil
            )
            guard let keys = try? SyncE2EE.deriveScopeKeys(accountMasterKey: masterKey, scope: scope) else {
                throw SyncShadowImportError.invalidScope
            }

            try enqueue(
                body: roomOperation(roomID: roomID, title: room.title, scope: scope, keys: keys, continuationCapability: room.continuationCapability),
                into: outbox
            )

            // Bubbles arrive in storage order, which is the order they were
            // said. Turns are created the first time one of their bubbles is
            // seen, so a turn never precedes its own first bubble by accident.
            var seenTurns: Set<UUID> = []
            var turnCount = 0
            var hasher = SHA256()
            hasher.update(data: Data(roomID.utf8))

            for bubble in room.bubbles {
                if seenTurns.insert(bubble.turnID).inserted {
                    try enqueue(
                        body: turnOperation(
                            roomID: roomID,
                            turnID: bubble.turnID.uuidString.uppercased(),
                            createdAt: bubble.timestamp,
                            scope: scope,
                            keys: keys
                        ),
                        into: outbox
                    )
                    turnCount += 1
                }
                try enqueue(
                    body: bubbleOperation(
                        roomID: roomID,
                        bubble: bubble,
                        bubbleOrder: bubbleOrder,
                        scope: scope,
                        keys: keys
                    ),
                    into: outbox
                )
                // Identity and order only. Adding the text here would make the
                // manifest a fingerprint of the conversation.
                hasher.update(data: Data(bubble.messageID.uuidString.uppercased().utf8))
                hasher.update(data: withUnsafeBytes(of: bubbleOrder.bigEndian) { Data($0) })
                bubbleOrder += 1
            }

            manifestRooms.append(
                SyncShadowManifest.Room(
                    roomID: roomID,
                    turnCount: turnCount,
                    bubbleCount: room.bubbles.count,
                    contentHash: hasher.finalize().map { String(format: "%02x", $0) }.joined()
                )
            )
        }

        return SyncShadowManifest(importBatchID: batchID, rooms: manifestRooms)
    }

    // MARK: - Operation bodies

    private func roomOperation(
        roomID: String,
        title: String,
        scope: SyncE2EE.Scope,
        keys: SyncE2EE.ScopeKeys,
        continuationCapability: Bool
    ) throws -> Data {
        let sealed = try seal(
            title,
            keys: keys,
            context: SyncE2EE.AADContext(
                scope: scope, entityType: "room", entityID: roomID,
                fieldPath: "title", bubbleOrder: nil, recoveryVersion: nil
            )
        )
        var fields = ["title": sealed]
        if continuationCapability {
            fields["extensions.gagaodok.room.continuation_capability"] = try seal(
                "chatbot", keys: keys,
                context: SyncE2EE.AADContext(scope: scope, entityType: "room", entityID: roomID,
                                               fieldPath: "extensions.gagaodok.room.continuation_capability", bubbleOrder: nil, recoveryVersion: nil)
            )
        }
        return try body([
            "op": "create_room",
            "entity_type": "room",
            "target": ["space_id": writerSpaceID, "room_id": roomID, "worldline_id": NSNull()],
            "metadata_set": ["origin_space_id": originSpaceID],
            "set": fields,
        ])
    }

    private func turnOperation(
        roomID: String,
        turnID: String,
        createdAt: Date,
        scope: SyncE2EE.Scope,
        keys: SyncE2EE.ScopeKeys
    ) throws -> Data {
        return try body([
            "op": "create_turn",
            "entity_type": "turn",
            "target": [
                "space_id": writerSpaceID, "room_id": roomID,
                "worldline_id": NSNull(), "turn_id": turnID,
            ],
            // The device that produced the turn and when. Both are NOT NULL in
            // D1 and neither is derivable from the sealed body.
            "metadata_set": [
                "created_by_device_id": deviceID,
                "created_at": Self.rfc3339(createdAt),
            ],
            "set": [:],
        ])
    }

    private func bubbleOperation(
        roomID: String,
        bubble: SyncShadowRoomInput.Bubble,
        bubbleOrder: UInt64,
        scope: SyncE2EE.Scope,
        keys: SyncE2EE.ScopeKeys
    ) throws -> Data {
        let messageID = bubble.messageID.uuidString.uppercased()
        // `bubble_order` is inside the AAD, so a bubble resealed at a different
        // order will not open. That is deliberate: reordering must be a new
        // encryption, not a cheap metadata edit.
        func context(_ field: String) -> SyncE2EE.AADContext {
            SyncE2EE.AADContext(
                scope: scope, entityType: "bubble", entityID: messageID,
                fieldPath: field, bubbleOrder: bubbleOrder, recoveryVersion: nil
            )
        }
        return try body([
            "op": "create_bubble",
            "entity_type": "bubble",
            "target": [
                "space_id": writerSpaceID, "room_id": roomID, "worldline_id": NSNull(),
                "turn_id": bubble.turnID.uuidString.uppercased(), "message_id": messageID,
            ],
            "bubble_order": bubbleOrder,
            "metadata_set": ["timestamp": Self.rfc3339(bubble.timestamp)],
            "set": [
                "sender": try seal(bubble.sender, keys: keys, context: context("sender")),
                "kind": try seal(bubble.kind, keys: keys, context: context("kind")),
                "text": try seal(bubble.text, keys: keys, context: context("text")),
            ],
        ])
    }

    private func body(_ parts: [String: Any]) throws -> Data {
        var json: [String: Any] = [
            "protocol_version": 1,
            "operation_id": identifier(),
            "device_id": deviceID,
            "metadata_clear": [],
            "clear": [],
            "created_at": Self.rfc3339(now()),
        ]
        for (key, value) in parts { json[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            throw SyncShadowImportError.encryptionFailed
        }
        return data
    }

    private func seal(
        _ text: String,
        keys: SyncE2EE.ScopeKeys,
        context: SyncE2EE.AADContext
    ) throws -> String {
        guard let sealed = try? SyncE2EE.seal(
            plaintext: Data(text.utf8),
            key: keys.fieldAEADKey,
            nonce: randomBytes(12),
            context: context
        ) else {
            throw SyncShadowImportError.encryptionFailed
        }
        return sealed.base64EncodedString()
    }

    private func enqueue(body: Data, into outbox: SyncOutbox) throws {
        guard
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let operationID = json["operation_id"] as? String
        else {
            throw SyncShadowImportError.encryptionFailed
        }
        guard (try? outbox.enqueue(operationID: operationID, rawBody: body)) != nil else {
            throw SyncShadowImportError.outboxFailed
        }
    }

    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
