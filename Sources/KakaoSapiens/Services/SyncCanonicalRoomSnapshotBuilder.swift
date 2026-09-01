import Foundation

/// 방 가족이 참조하는 것을 실제로 다 갖고 있는지 판정한다.
public enum SyncRoomFamilyGap: String, Equatable, Comparable {
    case unknownEntity = "unknown_entity"
    case missingWorldline = "worldline_missing"
    case missingEngineProfile = "engine_profile_revision_missing"
    case missingPersonaSnapshot = "persona_snapshot_missing"
    case missingCheckpointTurn = "checkpoint_turn_missing"
    case attachmentNotReady = "attachment_not_ready"

    public static func < (lhs: SyncRoomFamilyGap, rhs: SyncRoomFamilyGap) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 계정 단위 pool. 방에 속하지 않고 여러 방이 함께 참조한다.
public struct SyncRoomFamilyPools {
    /// `(space_id, engine_profile_id, profile_revision)`
    public let engineProfiles: Set<String>
    /// `(space_id, persona_snapshot_id, snapshot_revision)`
    public let personaSnapshots: Set<String>
    /// `attachment_id` → `state`
    public let attachmentStates: [String: String]

    public init(
        engineProfiles: Set<String>,
        personaSnapshots: Set<String>,
        attachmentStates: [String: String]
    ) {
        self.engineProfiles = engineProfiles
        self.personaSnapshots = personaSnapshots
        self.attachmentStates = attachmentStates
    }
}

/// 방 가족의 완결성만 판정한다. 렌더링은 assembler가 한다.
///
/// 규칙 셋:
///  1. 참조된 revision이 없으면 그 가족을 unsupported로 표시한다. 기본값을 지어내지 않는다.
///  2. 모르는 entity_type은 버리지 않고 `unknownEntity`로 올린다. 조용한 누락이
///     "완전한 대화"처럼 보이는 것이 가장 나쁜 실패다.
///  3. 한 가족의 결손이 다른 방으로 번지지 않는다.
///
/// `group_state`에는 gap이 없다. 평문에서 그것을 가리키는 참조가 없어서 "있어야
/// 하는데 없다"를 판정할 방법이 없다. 못 재는 것을 재는 척하지 않는다.
public struct SyncCanonicalRoomSnapshotBuilder {
    public static let roomScopedTypes: Set<String> =
        ["room", "group_state", "worldline", "turn", "bubble", "checkpoint"]
    public static let poolTypes: Set<String> =
        ["engine_profile", "persona_snapshot", "attachment"]

    public init() {}

    /// 계정 단위 pool을 모은다. 모르는 entity_type이 있으면 `unknown`이 true다.
    public static func pools(_ entries: [SyncReplicaEntry]) -> (pools: SyncRoomFamilyPools, unknown: Bool) {
        var engineProfiles: Set<String> = []
        var personaSnapshots: Set<String> = []
        var attachmentStates: [String: String] = [:]
        var unknown = false
        for entry in entries {
            guard let identity = object(entry.identityJSON) else { unknown = true; continue }
            switch entry.entityType {
            case "engine_profile":
                if let key = revisionKey(identity, "engine_profile_id", "profile_revision") {
                    engineProfiles.insert(key)
                } else { unknown = true }
            case "persona_snapshot":
                if let key = revisionKey(identity, "persona_snapshot_id", "snapshot_revision") {
                    personaSnapshots.insert(key)
                } else { unknown = true }
            case "attachment":
                guard let id = identity["attachment_id"] as? String,
                      let projection = object(entry.projectionJSON),
                      let state = projection["state"] as? String
                else { unknown = true; continue }
                attachmentStates[id.uppercased()] = state
            default:
                if !roomScopedTypes.contains(entry.entityType) { unknown = true }
            }
        }
        return (
            SyncRoomFamilyPools(
                engineProfiles: engineProfiles,
                personaSnapshots: personaSnapshots,
                attachmentStates: attachmentStates),
            unknown
        )
    }

    /// 한 방 가족의 결손을 모은다. 정렬된 채로 돌려준다.
    public func gaps(
        roomEntries: [SyncReplicaEntry], pools: SyncRoomFamilyPools, poolsHadUnknown: Bool
    ) -> [SyncRoomFamilyGap] {
        var found: Set<SyncRoomFamilyGap> = poolsHadUnknown ? [.unknownEntity] : []
        var worldlines: Set<String> = []
        var turnIDs: Set<String> = []
        var referencedWorldlines: Set<String> = []
        var checkpointTurns: Set<String> = []

        for entry in roomEntries {
            guard let identity = Self.object(entry.identityJSON) else {
                found.insert(.unknownEntity); continue
            }
            let projection = Self.object(entry.projectionJSON) ?? [:]
            switch entry.entityType {
            case "room":
                // room_ai_state_ref는 평문 보조 블록이다. 가리키는 revision이
                // pool에 없으면 기본값으로 때우지 않고 unsupported로 올린다.
                if let profile = Self.revisionKeyFromProjection(
                    identity, projection, "engine_profile_id", "engine_profile_revision"),
                   !pools.engineProfiles.contains(profile) {
                    found.insert(.missingEngineProfile)
                }
                if let persona = Self.revisionKeyFromProjection(
                    identity, projection, "persona_snapshot_id", "persona_snapshot_revision"),
                   !pools.personaSnapshots.contains(persona) {
                    found.insert(.missingPersonaSnapshot)
                }
            case "worldline":
                if let id = identity["worldline_id"] as? String { worldlines.insert(id.uppercased()) }
            case "turn":
                if let id = identity["turn_id"] as? String { turnIDs.insert(id.uppercased()) }
                if let line = identity["worldline_id"] as? String { referencedWorldlines.insert(line.uppercased()) }
            case "bubble":
                if let line = identity["worldline_id"] as? String { referencedWorldlines.insert(line.uppercased()) }
                if let attachment = projection["attachment_ref_attachment_id"] as? String {
                    // 아직 ready가 아닌 첨부를 가진 방은 이어쓰기를 열지 않는다.
                    // 다른 기기에서 "볼 수 없는 사진"이 뜨는 상태다.
                    if pools.attachmentStates[attachment.uppercased()] != "ready" {
                        found.insert(.attachmentNotReady)
                    }
                }
            case "checkpoint":
                if let line = identity["worldline_id"] as? String { referencedWorldlines.insert(line.uppercased()) }
                for key in ["first_turn_id", "last_turn_id"] {
                    if let turn = projection[key] as? String { checkpointTurns.insert(turn.uppercased()) }
                }
            case "group_state":
                break
            case "engine_profile", "persona_snapshot", "attachment":
                // 계정 단위 pool이다. 방 목록에 섞여 들어와도 모르는 것으로 치지 않는다.
                break
            default:
                found.insert(.unknownEntity)
            }
        }

        if !referencedWorldlines.subtracting(worldlines).isEmpty { found.insert(.missingWorldline) }
        if !checkpointTurns.subtracting(turnIDs).isEmpty { found.insert(.missingCheckpointTurn) }
        return found.sorted()
    }

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func revisionKey(_ identity: [String: Any], _ idKey: String, _ revisionKey: String) -> String? {
        guard let space = identity["space_id"] as? String,
              let id = identity[idKey] as? String,
              let revision = identity[revisionKey] as? NSNumber
        else { return nil }
        return "\(space)|\(id.uppercased())|\(revision.int64Value)"
    }

    private static func revisionKeyFromProjection(
        _ identity: [String: Any], _ projection: [String: Any],
        _ idKey: String, _ revisionKey: String
    ) -> String? {
        guard let space = identity["space_id"] as? String,
              let id = projection[idKey] as? String,
              let revision = projection[revisionKey] as? NSNumber
        else { return nil }
        return "\(space)|\(id.uppercased())|\(revision.int64Value)"
    }
}
