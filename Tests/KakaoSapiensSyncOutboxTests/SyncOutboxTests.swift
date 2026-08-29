import Foundation

@main
enum SyncOutboxTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("outbox.plist")
        let firstID = "10000000-0000-4000-8000-000000000001"
        let secondID = "10000000-0000-4000-8000-000000000002"
        let first = Data("{\"ciphertext\":\"ONE\"}".utf8)
        let second = Data("{\"ciphertext\":\"TWO\"}".utf8)
        let outbox = SyncOutbox(fileURL: file)
        try require(outbox.enqueue(operationID: firstID, rawBody: first), "first enqueue")
        try require(outbox.enqueue(operationID: secondID, rawBody: second), "second enqueue")
        try require(!outbox.enqueue(operationID: firstID, rawBody: first), "byte replay")
        try expect(.replayMismatch) { try outbox.enqueue(operationID: firstID, rawBody: second) }
        let reopened = SyncOutbox(fileURL: file)
        try require(try reopened.pending() == [SyncOutboxEntry(operationID:firstID,rawBody:first),SyncOutboxEntry(operationID:secondID,rawBody:second)], "restart order and bytes")
        try require(try reopened.acknowledge(operationID: firstID), "ack")
        try require(try reopened.pending().map(\.operationID) == [secondID], "ack persistence")
        print("Swift sync outbox: 1 passed")
    }
    private static func require(_ value:@autoclosure() throws->Bool,_ message:String)throws{if try !value(){throw Failure(message)}}
    private static func expect(_ expected:SyncOutboxError,_ work:() throws->Void)throws{do{try work();throw Failure("expected error")}catch let error as SyncOutboxError{try require(String(describing:error)==String(describing:expected),"wrong error")}}
    private struct Failure:Error{let message:String;init(_ message:String){self.message=message}}
}
