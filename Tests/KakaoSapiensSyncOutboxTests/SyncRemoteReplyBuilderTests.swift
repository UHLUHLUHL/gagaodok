import Foundation
private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message: message) } }
private let id = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
private func room(_ capability: SyncRemoteContinuationCapability?) -> SyncRemoteRoomSnapshot { .init(handle: .init(originSpaceID: "MAC_SPACE", roomID: id), title: "합성", writerSpaces: ["MAC_SPACE"], messages: [], contentHash: "x", continuationCapability: capability) }
@main private struct Runner { static func main() throws {
    let builder = SyncRemoteReplyBuilder(accountID: "A0000000-0000-4000-8000-000000000002", deviceID: "A0000000-0000-4000-8000-000000000003", masterKey: Data(repeating: 7, count: 32))
    let plan = try builder.prepareReply(room: room(.chatbot), writerSpaceID: "PHONE_SPACE", userText: "질문", assistantText: "답", selectedGeminiModel: .gemini37Flash)
    let ops = try plan.operations.map { try JSONSerialization.jsonObject(with: $0.rawBody) as! [String: Any] }
    try check(ops.map { $0["op"] as? String } == ["create_room", "create_turn", "create_bubble", "create_bubble"], "writer shard and turn order")
    try check(ops.allSatisfy { $0["cache"] == nil && $0["affection"] == nil }, "local state leaked")
    do { _ = try builder.prepareReply(room: room(nil), writerSpaceID: "PHONE_SPACE", userText: "q", assistantText: "a", selectedGeminiModel: .gemini37Flash); throw Failure(message:"legacy allowed") } catch SyncRemoteReplyBuilderError.unsupportedRoom {}
    print("2 remote reply builder tests passed")
} }
