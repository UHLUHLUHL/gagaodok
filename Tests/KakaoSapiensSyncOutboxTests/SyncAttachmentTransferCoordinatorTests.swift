import Foundation
import CryptoKit

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}

private actor Calls {
    var order: [String] = []
    func add(_ name: String) { order.append(name) }
}

private struct OrderedTransport: SyncHTTPTransport {
    let calls: Calls
    let completeStatus: Int
    /// GET이 돌려줄 바이트. 비워 두면 크기 검사에 먼저 걸려 해시 검사를 시험할 수 없다.
    var downloadBody: Data = Data()
    func send(_ request: URLRequest) async throws -> SyncHTTPResponse {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/complete") {
            await calls.add("complete")
            return SyncHTTPResponse(statusCode: completeStatus, body: Data())
        }
        if request.httpMethod == "GET" {
            await calls.add("get")
            return SyncHTTPResponse(statusCode: 200, body: downloadBody)
        }
        await calls.add("put")
        return SyncHTTPResponse(statusCode: 204, body: Data())
    }
}

@main private struct Runner {
    static func main() async throws {
        let account = "11111111-1111-4111-8111-111111111111"
        let attachment = "70000000-0000-4000-8000-000000000001"
        let master = Data(repeating: 0x22, count: 32)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attach-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = Data((0..<96).map { UInt8($0) })
        let fixedRandom: (Int) -> Data = { count in Data(repeating: 0x40, count: count) }
        let base = URL(string: "https://example.invalid")!
        let token = Data(repeating: 0x11, count: 32)

        // 1. 봉투 크기가 정확히 원본 + 34여야 한다.
        let calls = Calls()
        let client = try SyncWorkerClient(
            baseURL: base, deviceToken: token,
            transport: OrderedTransport(calls: calls, completeStatus: 204))
        let coordinator = SyncAttachmentTransferCoordinator(
            accountID: account, masterKey: master, client: client, rootDirectory: root)
        let plan = try coordinator.prepare(
            bytes: source, attachmentID: attachment, kind: .attachment,
            fileName: "note.pdf", mimeType: "application/pdf", randomBytes: fixedRandom)
        try check(plan.ciphertextByteSize == plan.sourceByteSize + 34, "overhead is not 34")
        try check(plan.ciphertext.count == Int(plan.ciphertextByteSize), "ciphertext size disagrees")
        try check(plan.ciphertextHashHex.count == 64
                  && plan.ciphertextHashHex.lowercased() == plan.ciphertextHashHex,
                  "hash is not lowercase hex 64")

        // 2. 업로드는 반드시 PUT 다음 complete 순서다.
        try await coordinator.upload(plan)
        let order = await calls.order
        try check(order == ["put", "complete"], "upload order is not put→complete, got \(order)")

        // 3. complete가 실패하면 ready가 아니므로 오류가 나야 한다.
        let failingClient = try SyncWorkerClient(
            baseURL: base, deviceToken: token,
            transport: OrderedTransport(calls: Calls(), completeStatus: 500))
        let failingCoordinator = SyncAttachmentTransferCoordinator(
            accountID: account, masterKey: master, client: failingClient, rootDirectory: root)
        var completeFailed = false
        do { try await failingCoordinator.upload(plan) } catch { completeFailed = true }
        try check(completeFailed, "a failed complete was reported as success")

        // 4. 크기가 다르면 거부한다.
        var sizeRejected = false
        do {
            _ = try await coordinator.download(
                attachmentID: attachment, kind: .attachment, sourceByteSize: 96,
                ciphertextByteSize: 999, ciphertextHashHex: plan.ciphertextHashHex,
                wrappedFileKeyBase64: plan.wrappedFileKeyBase64)
        } catch { sizeRejected = true }
        try check(sizeRejected, "a size mismatch was accepted")

        // 5. 해시가 다르면 거부한다.
        //    크기가 맞는 실제 바이트를 돌려줘야 크기 검사를 통과해 해시 검사에 닿는다.
        //    빈 body를 쓰면 크기 검사에 먼저 걸려 이 시험이 무의미해진다.
        let hashClient = try SyncWorkerClient(
            baseURL: base, deviceToken: token,
            transport: OrderedTransport(
                calls: Calls(), completeStatus: 204, downloadBody: plan.ciphertext))
        let hashCoordinator = SyncAttachmentTransferCoordinator(
            accountID: account, masterKey: master, client: hashClient, rootDirectory: root)
        var hashRejected = false
        do {
            _ = try await hashCoordinator.download(
                attachmentID: attachment, kind: .attachment, sourceByteSize: 96,
                ciphertextByteSize: plan.ciphertextByteSize,
                ciphertextHashHex: String(repeating: "0", count: 64),
                wrappedFileKeyBase64: plan.wrappedFileKeyBase64)
        } catch { hashRejected = true }
        try check(hashRejected, "a hash mismatch was accepted")

        // 5b. 올바른 해시와 올바른 바이트면 왕복한다. 위 거부가 우연이 아님을 확인한다.
        let roundTrip = try await hashCoordinator.download(
            attachmentID: attachment, kind: .attachment, sourceByteSize: 96,
            ciphertextByteSize: plan.ciphertextByteSize,
            ciphertextHashHex: plan.ciphertextHashHex,
            wrappedFileKeyBase64: plan.wrappedFileKeyBase64)
        let restored = try Data(contentsOf: roundTrip)
        try check(restored == source, "the round trip did not restore the source bytes")

        // 6. 12MB를 넘으면 조용히 자르지 않고 명시적으로 거부한다.
        var tooLargeRejected = false
        do {
            _ = try coordinator.prepare(
                bytes: Data(count: Int(SyncAttachmentTransferCoordinator.maxSourceBytes) + 1),
                attachmentID: attachment, kind: .attachment,
                fileName: "big.bin", mimeType: "application/octet-stream",
                randomBytes: fixedRandom)
        } catch { tooLargeRejected = true }
        try check(tooLargeRejected, "an oversized attachment was accepted")

        // 7. 복호화 결과는 sync/remote/attachments 아래에만 쓴다.
        //    카메라·PDF 원본 경로를 덮어쓰지 않는다.
        let expectedPrefix = root
            .appendingPathComponent("sync/remote/attachments", isDirectory: true).path
        let destination = try SyncAttachmentTransferCoordinator.destinationPath(
            rootDirectory: root, attachmentID: attachment)
        try check(destination.path.hasPrefix(expectedPrefix),
                  "attachments escape sync/remote/attachments")
        try check(roundTrip.path == destination.path, "the round trip wrote somewhere else")

        print("11 attachment transfer checks passed")
    }
}
