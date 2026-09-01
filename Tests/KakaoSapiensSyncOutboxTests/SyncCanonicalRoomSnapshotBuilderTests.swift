import Foundation

private struct Failure: Error { let message: String }
private func check(_ v: @autoclosure () -> Bool, _ m: String) throws {
    if !v() { throw Failure(message: m) }
}

private let account = "11111111-1111-4111-8111-111111111111"
private let master = Data(repeating: 0x33, count: 32)
private let room = "10000000-0000-4000-8000-000000000001"
private let otherRoom = "10000000-0000-4000-8000-000000000002"
private let turn = "30000000-0000-4000-8000-000000000001"
private let message = "20000000-0000-4000-8000-000000000001"
private let otherMessage = "20000000-0000-4000-8000-000000000002"
private let attachment = "70000000-0000-4000-8000-000000000001"
private let profile = "50000000-0000-4000-8000-000000000001"
private let persona = "60000000-0000-4000-8000-000000000001"
private let worldline = "40000000-0000-4000-8000-000000000001"

private func json(_ value: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func entry(_ type: String, _ identity: [String: Any], _ projection: [String: Any]) -> SyncReplicaEntry {
    SyncReplicaEntry(entityType: type, identityJSON: json(identity), projectionJSON: json(projection))
}

/// MAC이 만든 방을 PHONE이 읽는 상황을 만든다. 노출 정책상 보이는 조합이다.
private func sealed(_ text: String, room: String, entity: String, id: String, field: String, order: UInt64?) -> String {
    let keys = try! SyncE2EE.deriveScopeKeys(
        accountMasterKey: master,
        scope: SyncE2EE.Scope(accountID: account, spaceID: "MAC_SPACE", roomID: room, worldlineID: nil))
    let envelope = try! SyncE2EE.seal(
        plaintext: Data(text.utf8), key: keys.fieldAEADKey,
        nonce: Data(repeating: 0x07, count: 12),
        context: SyncE2EE.AADContext(
            scope: SyncE2EE.Scope(accountID: account, spaceID: "MAC_SPACE", roomID: room, worldlineID: nil),
            entityType: entity, entityID: id, fieldPath: field, bubbleOrder: order, recoveryVersion: nil))
    return SyncE2EE.encodeBase64(envelope)
}

private func roomEntry(_ roomID: String, aiState: [String: Any] = [:]) -> SyncReplicaEntry {
    var projection: [String: Any] = [
        "origin_space_id": "MAC_SPACE",
        "title": sealed("합성 방", room: roomID, entity: "room", id: roomID, field: "title", order: nil),
    ]
    projection.merge(aiState) { current, _ in current }
    return entry("room", ["space_id": "MAC_SPACE", "room_id": roomID], projection)
}

private func turnEntry(_ roomID: String, _ turnID: String) -> SyncReplicaEntry {
    entry("turn",
          ["space_id": "MAC_SPACE", "room_id": roomID, "worldline_id": NSNull(), "turn_id": turnID],
          ["is_tombstoned": false])
}

private func bubbleEntry(
    _ roomID: String, _ turnID: String, _ messageID: String, order: UInt64, attachmentRef: String? = nil
) -> SyncReplicaEntry {
    var projection: [String: Any] = [
        "bubble_order": order,
        "timestamp": "2026-01-01T00:00:00Z",
        "is_tombstoned": false,
        "sender": sealed("나", room: roomID, entity: "bubble", id: messageID, field: "sender", order: order),
        "kind": sealed("speech", room: roomID, entity: "bubble", id: messageID, field: "kind", order: order),
        "text": sealed("안녕", room: roomID, entity: "bubble", id: messageID, field: "text", order: order),
    ]
    if let attachmentRef { projection["attachment_ref_attachment_id"] = attachmentRef }
    return entry("bubble",
                 ["space_id": "MAC_SPACE", "room_id": roomID, "worldline_id": NSNull(),
                  "turn_id": turnID, "message_id": messageID],
                 projection)
}

private func attachmentEntry(_ state: String) -> SyncReplicaEntry {
    entry("attachment", ["attachment_id": attachment], ["state": state, "kind": "attachment"])
}

@main private struct Runner {
    static func main() throws {
        let builder = SyncCanonicalRoomSnapshotBuilder()
        let assembler = SyncRemoteRoomAssembler(
            accountID: account, registeredSpaceID: "PHONE_SPACE", masterKey: master)

        let base = [roomEntry(room), turnEntry(room, turn), bubbleEntry(room, turn, message, order: 1)]

        // 1. 완결된 가족은 gap이 없다.
        let (emptyPools, emptyUnknown) = SyncCanonicalRoomSnapshotBuilder.pools(base)
        try check(builder.gaps(roomEntries: base, pools: emptyPools, poolsHadUnknown: emptyUnknown).isEmpty,
                  "a complete family reported a gap")

        // 2. 참조된 engine_profile revision이 없으면 기본값으로 때우지 않는다.
        let withProfileRef = [
            roomEntry(room, aiState: ["engine_profile_id": profile, "engine_profile_revision": 3]),
            turnEntry(room, turn), bubbleEntry(room, turn, message, order: 1),
        ]
        var (pools, unknown) = SyncCanonicalRoomSnapshotBuilder.pools(withProfileRef)
        try check(builder.gaps(roomEntries: withProfileRef, pools: pools, poolsHadUnknown: unknown)
                    == [.missingEngineProfile],
                  "a missing engine profile revision was not reported")

        // 같은 revision을 넣어주면 gap이 사라진다. 위 판정이 우연이 아님을 확인한다.
        let profileRow = entry("engine_profile",
            ["space_id": "MAC_SPACE", "engine_profile_id": profile, "profile_revision": 3],
            ["compaction_compat_tag": "x"])
        (pools, unknown) = SyncCanonicalRoomSnapshotBuilder.pools(withProfileRef + [profileRow])
        try check(builder.gaps(roomEntries: withProfileRef, pools: pools, poolsHadUnknown: unknown).isEmpty,
                  "supplying the referenced revision did not clear the gap")

        // 3. persona_snapshot도 같다.
        let withPersonaRef = [
            roomEntry(room, aiState: ["persona_snapshot_id": persona, "persona_snapshot_revision": 2]),
            turnEntry(room, turn), bubbleEntry(room, turn, message, order: 1),
        ]
        (pools, unknown) = SyncCanonicalRoomSnapshotBuilder.pools(withPersonaRef)
        try check(builder.gaps(roomEntries: withPersonaRef, pools: pools, poolsHadUnknown: unknown)
                    == [.missingPersonaSnapshot],
                  "a missing persona snapshot revision was not reported")

        // 4. ready가 아닌 첨부는 완결이 아니다.
        let allocated = base.dropLast() + [
            bubbleEntry(room, turn, message, order: 1, attachmentRef: attachment),
            attachmentEntry("allocated"),
        ]
        (pools, unknown) = SyncCanonicalRoomSnapshotBuilder.pools(Array(allocated))
        try check(builder.gaps(roomEntries: Array(allocated), pools: pools, poolsHadUnknown: unknown)
                    == [.attachmentNotReady],
                  "a non-ready attachment counted as complete")

        let ready = base.dropLast() + [
            bubbleEntry(room, turn, message, order: 1, attachmentRef: attachment),
            attachmentEntry("ready"),
        ]
        (pools, unknown) = SyncCanonicalRoomSnapshotBuilder.pools(Array(ready))
        try check(builder.gaps(roomEntries: Array(ready), pools: pools, poolsHadUnknown: unknown).isEmpty,
                  "a ready attachment still reported a gap")

        // 5. 참조된 세계선이 없으면 보고한다.
        let namedWorldline = entry("turn",
            ["space_id": "MAC_SPACE", "room_id": room, "worldline_id": worldline, "turn_id": turn],
            ["is_tombstoned": false])
        (pools, unknown) = SyncCanonicalRoomSnapshotBuilder.pools([roomEntry(room), namedWorldline])
        try check(builder.gaps(roomEntries: [roomEntry(room), namedWorldline], pools: pools, poolsHadUnknown: unknown)
                    == [.missingWorldline],
                  "a missing named worldline was not reported")

        // 6. 모르는 entity_type을 조용히 버리지 않는다.
        let stray = entry("gemini_cache", ["space_id": "MAC_SPACE", "room_id": room], ["x": 1])
        let snapshots = assembler.assemble(base + [stray])
        try check(snapshots.count == 1, "the stray entity removed the room")
        try check(snapshots[0].unsupportedReason?.contains("unknown_entity") == true,
                  "an unknown entity type was silently dropped")

        // 7. 손상된 가족은 그 가족만 막고 다른 방에 번지지 않는다.
        let healthy = [roomEntry(otherRoom), turnEntry(otherRoom, turn),
                       bubbleEntry(otherRoom, turn, otherMessage, order: 1)]
        let broken = base.dropLast() + [
            bubbleEntry(room, turn, message, order: 1, attachmentRef: attachment),
            attachmentEntry("allocated"),
        ]
        let mixed = assembler.assemble(Array(broken) + healthy)
        try check(mixed.count == 2, "a broken family removed a healthy room")
        let brokenSnapshot = mixed.first { $0.handle.roomID.uuidString == room }!
        let healthySnapshot = mixed.first { $0.handle.roomID.uuidString == otherRoom }!
        try check(brokenSnapshot.unsupportedReason == "attachment_not_ready", "the broken room stayed openable")
        try check(healthySnapshot.unsupportedReason == nil, "the healthy room was blocked")

        // 8. bubble이 첨부 참조와 상태를 싣고 온다. 화면이 네 상태를 정할 수 있다.
        let readySnapshots = assembler.assemble(Array(ready))
        let carried = readySnapshots[0].messages[0]
        try check(carried.attachmentID == attachment, "the bubble lost its attachment reference")
        try check(carried.attachmentState == "ready", "the bubble lost the attachment state")
        try check(SyncAttachmentDisplayState.state(
            remoteState: carried.attachmentState!, lastError: nil) == .ready,
            "a ready attachment did not display as ready")

        print("14 room family completeness checks passed")
    }
}
