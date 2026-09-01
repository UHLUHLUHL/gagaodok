import CryptoKit
import Foundation

/// Builds a display projection from the opaque sync replica. A malformed row
/// rejects its whole room family; it is never silently dropped into a partial
/// conversation that looks complete.
public struct SyncRemoteRoomAssembler {
    private static let spaces = Set(["MAC_SPACE", "PHONE_SPACE", "TABLET_SPACE"])
    private let accountID: String
    private let registeredSpaceID: String
    private let masterKey: Data

    public init(accountID: String, registeredSpaceID: String, masterKey: Data) {
        self.accountID = accountID
        self.registeredSpaceID = registeredSpaceID
        self.masterKey = masterKey
    }

    public func assemble(_ entries: [SyncReplicaEntry]) -> [SyncRemoteRoomSnapshot] {
        guard Self.spaces.contains(registeredSpaceID), masterKey.count == 32 else { return [] }
        // 예전에는 여기서 room·turn·bubble만 통과시켰다. 나머지 6종은 분기에 닿기
        // 전에 걸러져 조용히 버려졌고, "지원하지 않음" 표시조차 뜨지 않았다.
        let (pools, poolsHadUnknown) = SyncCanonicalRoomSnapshotBuilder.pools(entries)
        var families: [String: [SyncReplicaEntry]] = [:]
        var strayUnknown = poolsHadUnknown
        for entry in entries {
            if SyncCanonicalRoomSnapshotBuilder.poolTypes.contains(entry.entityType) { continue }
            guard SyncCanonicalRoomSnapshotBuilder.roomScopedTypes.contains(entry.entityType) else {
                strayUnknown = true; continue
            }
            guard let identity = object(entry.identityJSON),
                  let rawRoom = identity["room_id"] as? String,
                  let room = canonicalUUID(rawRoom)
            else { strayUnknown = true; continue }
            families[room, default: []].append(entry)
        }
        let builder = SyncCanonicalRoomSnapshotBuilder()
        return families.keys.sorted().compactMap { roomID in
            let entries = families[roomID] ?? []
            guard let snapshot = assembleFamily(entries, roomID: roomID, pools: pools) else { return nil }
            // 한 가족의 결손은 그 가족만 막는다. 다른 방으로 번지지 않는다.
            let gaps = builder.gaps(
                roomEntries: entries, pools: pools, poolsHadUnknown: strayUnknown)
            guard !gaps.isEmpty else { return snapshot }
            return SyncRemoteRoomSnapshot(
                handle: snapshot.handle, title: snapshot.title,
                writerSpaces: snapshot.writerSpaces, messages: snapshot.messages,
                contentHash: snapshot.contentHash,
                continuationCapability: snapshot.continuationCapability,
                unsupportedReason: gaps.map(\.rawValue).joined(separator: ","))
        }
    }

    private struct RoomRow {
        let space: String
        let origin: String
        let projection: [String: Any]
        let extensions: [[String: Any]]
    }

    private struct TurnKey: Hashable {
        let space: String
        let turn: String
    }

    private struct BubbleRow {
        let space: String
        let turn: String
        let message: String
        let order: UInt64
        let timestamp: String
        let timestampDate: Date
        let projection: [String: Any]
        let tombstoned: Bool
        let attachmentID: String?
    }

    private func assembleFamily(
        _ entries: [SyncReplicaEntry], roomID: String, pools: SyncRoomFamilyPools
    ) -> SyncRemoteRoomSnapshot? {
        var rooms: [RoomRow] = []
        var turns: [TurnKey: Bool] = [:]
        var bubbles: [BubbleRow] = []

        for entry in entries {
            guard let identity = object(entry.identityJSON),
                  let projection = object(entry.projectionJSON)
            else { return nil }
            switch entry.entityType {
            case "room":
                guard Set(identity.keys) == ["space_id", "room_id"],
                      let space = identity["space_id"] as? String,
                      let origin = projection["origin_space_id"] as? String,
                      Self.spaces.contains(space), Self.spaces.contains(origin),
                      canonicalUUID(identity["room_id"] as? String) == roomID,
                      projection["title"] is String
                else { return nil }
                let extensions = projection["extensions"] as? [[String: Any]] ?? []
                rooms.append(RoomRow(space: space, origin: origin, projection: projection, extensions: extensions))
            case "turn":
                guard Set(identity.keys) == ["space_id", "room_id", "worldline_id", "turn_id"],
                      identity["worldline_id"] is NSNull,
                      let space = identity["space_id"] as? String, Self.spaces.contains(space),
                      canonicalUUID(identity["room_id"] as? String) == roomID,
                      let turn = canonicalUUID(identity["turn_id"] as? String),
                      let tombstoned = projection["is_tombstoned"] as? Bool,
                      turns.updateValue(tombstoned, forKey: TurnKey(space: space, turn: turn)) == nil
                else { return nil }
            case "bubble":
                guard Set(identity.keys) == ["space_id", "room_id", "worldline_id", "turn_id", "message_id"],
                      identity["worldline_id"] is NSNull,
                      let space = identity["space_id"] as? String, Self.spaces.contains(space),
                      canonicalUUID(identity["room_id"] as? String) == roomID,
                      let turn = canonicalUUID(identity["turn_id"] as? String),
                      let message = canonicalUUID(identity["message_id"] as? String),
                      let order = unsigned(projection["bubble_order"]),
                      let timestamp = projection["timestamp"] as? String,
                      let timestampDate = Self.parseTimestamp(timestamp),
                      let tombstoned = projection["is_tombstoned"] as? Bool
                else { return nil }
                bubbles.append(BubbleRow(
                    space: space, turn: turn, message: message, order: order,
                    timestamp: timestamp, timestampDate: timestampDate,
                    projection: projection, tombstoned: tombstoned,
                    attachmentID: (projection["attachment_ref_attachment_id"] as? String)?.uppercased()
                ))
            case "group_state", "worldline", "checkpoint":
                // 렌더링에는 쓰지 않는다. 완결성 판정은 builder가 따로 한다.
                break
            default:
                return nil
            }
        }

        guard !rooms.isEmpty else { return nil }
        let origins = Set(rooms.map(\.origin))
        guard origins.count == 1, let origin = origins.first, origin != registeredSpaceID,
              rooms.filter({ $0.space == origin }).count == 1,
              rooms.allSatisfy({ Self.origin(origin, allows: $0.space) })
        else { return nil }
        let writerSpaces = Set(rooms.map(\.space))
        guard turns.keys.allSatisfy({ writerSpaces.contains($0.space) }),
              bubbles.allSatisfy({ writerSpaces.contains($0.space) })
        else { return nil }

        guard let originRoom = rooms.first(where: { $0.space == origin }),
              let title = open(
                originRoom.projection["title"], space: origin, room: roomID,
                entityType: "room", entityID: roomID, field: "title", order: nil
              )
        else { return nil }

        var messages: [SyncRemoteBubble] = []
        var seenMessages: Set<String> = []
        for bubble in bubbles {
            guard let parentTombstoned = turns[TurnKey(space: bubble.space, turn: bubble.turn)] else {
                return nil
            }
            guard seenMessages.insert("\(bubble.space):\(bubble.message)").inserted else { return nil }
            if parentTombstoned || bubble.tombstoned { continue }
            guard let sender = open(
                    bubble.projection["sender"], space: bubble.space, room: roomID,
                    entityType: "bubble", entityID: bubble.message, field: "sender", order: bubble.order
                  ),
                  let kind = open(
                    bubble.projection["kind"], space: bubble.space, room: roomID,
                    entityType: "bubble", entityID: bubble.message, field: "kind", order: bubble.order
                  ),
                  let text = open(
                    bubble.projection["text"], space: bubble.space, room: roomID,
                    entityType: "bubble", entityID: bubble.message, field: "text", order: bubble.order
                  )
            else { return nil }
            let speaker = optionalOpen(
                bubble.projection["speaker_ref"], space: bubble.space, room: roomID,
                entityType: "bubble", entityID: bubble.message, field: "speaker_ref", order: bubble.order
            )
            let reactions = optionalOpen(
                bubble.projection["reactions"], space: bubble.space, room: roomID,
                entityType: "bubble", entityID: bubble.message, field: "reactions", order: bubble.order
            )
            if speaker.failed || reactions.failed { return nil }
            messages.append(SyncRemoteBubble(
                writerSpaceID: bubble.space,
                turnID: UUID(uuidString: bubble.turn)!, messageID: UUID(uuidString: bubble.message)!,
                bubbleOrder: bubble.order, timestamp: bubble.timestamp,
                sender: sender, kind: kind, text: text,
                speakerRef: speaker.value, reactions: reactions.value,
                attachmentID: bubble.attachmentID,
                attachmentState: bubble.attachmentID.flatMap { pools.attachmentStates[$0] }
            ))
        }

        let sortDates = Dictionary(uniqueKeysWithValues: bubbles.map { ("\($0.space):\($0.message)", $0.timestampDate) })
        messages.sort {
            let left = sortDates["\($0.writerSpaceID):\($0.messageID.uuidString.uppercased())"]!
            let right = sortDates["\($1.writerSpaceID):\($1.messageID.uuidString.uppercased())"]!
            if left != right { return left < right }
            if $0.writerSpaceID != $1.writerSpaceID { return $0.writerSpaceID < $1.writerSpaceID }
            return $0.bubbleOrder < $1.bubbleOrder
        }
        let capabilities = Set(rooms.compactMap { continuationCapability($0, roomID: roomID) })
        guard capabilities.count <= 1 else { return nil }
        return SyncRemoteRoomSnapshot(
            handle: SyncRoomHandle(originSpaceID: origin, roomID: UUID(uuidString: roomID)!),
            title: title,
            writerSpaces: writerSpaces.sorted(), messages: messages,
            contentHash: Self.contentHash(roomID: roomID, messages: messages),
            continuationCapability: capabilities.first
        )
    }

    private func continuationCapability(_ room: RoomRow, roomID: String) -> SyncRemoteContinuationCapability? {
        let candidates = room.extensions.filter { $0["key"] as? String == "gagaodok.room.continuation_capability" }
        guard candidates.count <= 1, let value = candidates.first?["value"] as? String,
              let decoded = open(value, space: room.space, room: roomID, entityType: "room", entityID: roomID, field: "extensions.gagaodok.room.continuation_capability", order: nil)
        else { return candidates.isEmpty ? nil : .unsupported }
        return SyncRemoteContinuationCapability(rawValue: decoded) ?? .unsupported
    }

    private func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func canonicalUUID(_ value: Any?) -> String? {
        guard let value = value as? String, let uuid = UUID(uuidString: value) else { return nil }
        let canonical = uuid.uuidString.uppercased()
        return value == canonical ? canonical : nil
    }

    private func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_991,
              number.doubleValue.rounded() == number.doubleValue
        else { return nil }
        return number.uint64Value
    }

    private func open(
        _ value: Any?, space: String, room: String, entityType: String,
        entityID: String, field: String, order: UInt64?
    ) -> String? {
        guard let encoded = value as? String,
              let envelope = Data(base64Encoded: encoded),
              envelope.base64EncodedString() == encoded,
              let keys = try? SyncE2EE.deriveScopeKeys(
                accountMasterKey: masterKey,
                scope: SyncE2EE.Scope(accountID: accountID, spaceID: space, roomID: room, worldlineID: nil)
              ),
              let opened = try? SyncE2EE.open(
                envelope: envelope, key: keys.fieldAEADKey,
                context: SyncE2EE.AADContext(
                    scope: keysScope(space: space, room: room), entityType: entityType,
                    entityID: entityID, fieldPath: field, bubbleOrder: order, recoveryVersion: nil
                )
              ),
              let text = String(data: opened, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }

    private func keysScope(space: String, room: String) -> SyncE2EE.Scope {
        SyncE2EE.Scope(accountID: accountID, spaceID: space, roomID: room, worldlineID: nil)
    }

    private func optionalOpen(
        _ value: Any?, space: String, room: String, entityType: String,
        entityID: String, field: String, order: UInt64?
    ) -> (value: String?, failed: Bool) {
        if value == nil || value is NSNull { return (nil, false) }
        guard let opened = open(
            value, space: space, room: room, entityType: entityType,
            entityID: entityID, field: field, order: order
        ) else { return (nil, true) }
        return (opened, false)
    }

    private static func origin(_ origin: String, allows writer: String) -> Bool {
        switch origin {
        case "PHONE_SPACE": return writer == "PHONE_SPACE"
        case "MAC_SPACE": return writer == "MAC_SPACE" || writer == "PHONE_SPACE"
        case "TABLET_SPACE": return spaces.contains(writer)
        default: return false
        }
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func contentHash(roomID: String, messages: [SyncRemoteBubble]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(roomID.utf8))
        for message in messages {
            hasher.update(data: Data(message.writerSpaceID.utf8))
            hasher.update(data: Data(message.messageID.uuidString.uppercased().utf8))
            hasher.update(data: withUnsafeBytes(of: message.bubbleOrder.bigEndian) { Data($0) })
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
