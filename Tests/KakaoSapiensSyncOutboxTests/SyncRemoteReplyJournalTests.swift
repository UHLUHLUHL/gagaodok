import Foundation

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message: message) } }

private let handle = SyncRoomHandle(
    originSpaceID: "MAC_SPACE", roomID: UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!
)
private let replyID = "E0000000-0000-4000-8000-000000000001"
private func operation(_ id: String, _ byte: UInt8) -> SyncRemoteReplyOperation {
    SyncRemoteReplyOperation(operationID: id, rawBody: Data([byte, 2, 3]))
}

private func testReopenReturnsExactRawBytesAndStagesNeverRegress() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("journal.plist")
    let journal = SyncRemoteReplyJournal(fileURL: file)
    let first = operation("E0000000-0000-4000-8000-000000000010", 1)
    try journal.prepare(replyID: replyID, handle: handle, writerSpaceID: "PHONE_SPACE", userText: "로컬에만", operations: [first])
    try journal.advance(replyID: replyID, to: .turnCreated)
    let reopened = SyncRemoteReplyJournal(fileURL: file)
    try check(reopened.entry(replyID)?.operations == [first], "raw operation bytes changed across reopen")
    do { try reopened.advance(replyID: replyID, to: .prepared); throw Failure(message: "stage regressed") }
    catch SyncRemoteReplyJournalError.stageRegression { }
}

private func testConflictRebuildsOnlyUnacknowledgedOperations() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = SyncRemoteReplyJournal(fileURL: root.appendingPathComponent("journal.plist"))
    let turn = operation("E0000000-0000-4000-8000-000000000011", 1)
    let user = operation("E0000000-0000-4000-8000-000000000012", 2)
    let ai = operation("E0000000-0000-4000-8000-000000000013", 3)
    try journal.prepare(replyID: replyID, handle: handle, writerSpaceID: "PHONE_SPACE", userText: "keep", operations: [turn, user, ai])
    let userReplacement = operation("E0000000-0000-4000-8000-000000000014", 4)
    let aiReplacement = operation("E0000000-0000-4000-8000-000000000015", 5)
    try journal.rebuildForBubbleOrderConflict(replyID: replyID, userBubbleAcknowledged: false, replacementUser: userReplacement, replacementAI: aiReplacement)
    try check(journal.entry(replyID)?.operations == [turn, userReplacement, aiReplacement], "both unsubmitted bubbles must be rebuilt")
    try journal.acknowledge(replyID: replyID, operationID: userReplacement.operationID)
    let nextAI = operation("E0000000-0000-4000-8000-000000000016", 6)
    try journal.rebuildForBubbleOrderConflict(replyID: replyID, userBubbleAcknowledged: true, replacementUser: nil, replacementAI: nextAI)
    try check(journal.entry(replyID)?.operations == [turn, userReplacement, nextAI], "an acknowledged user bubble must be preserved")
}

private func testCompletedEntrySurvivesUntilProjectionObservation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = SyncRemoteReplyJournal(fileURL: root.appendingPathComponent("journal.plist"))
    let op = operation("E0000000-0000-4000-8000-000000000017", 7)
    try journal.prepare(replyID: replyID, handle: handle, writerSpaceID: "PHONE_SPACE", userText: "local", operations: [op])
    try journal.advance(replyID: replyID, to: .complete)
    try check(journal.entry(replyID) != nil, "complete must not erase before the feed observes it")
    try journal.observeProjection(replyID: replyID, operationID: op.operationID)
    try check(journal.entry(replyID) == nil, "observed complete reply must be removed")
}

@main private struct Runner {
    static func main() throws {
        try testReopenReturnsExactRawBytesAndStagesNeverRegress(); print("ok - replay and monotonic stage")
        try testConflictRebuildsOnlyUnacknowledgedOperations(); print("ok - order conflict rebuild")
        try testCompletedEntrySurvivesUntilProjectionObservation(); print("ok - projection acknowledgement")
        print("3 remote reply journal tests passed")
    }
}
