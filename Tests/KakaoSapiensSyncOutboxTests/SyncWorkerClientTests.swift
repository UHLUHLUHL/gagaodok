import Foundation

private actor Transport: SyncHTTPTransport {
    var responses: [SyncHTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [SyncHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> SyncHTTPResponse {
        requests.append(request)
        return responses.removeFirst()
    }
    func captured() -> [URLRequest] { requests }
}

@main
enum SyncWorkerClientTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = SyncOutbox(fileURL: directory.appendingPathComponent("outbox.plist"))
        let operationID = "10000000-0000-4000-8000-000000000001"
        let raw = Data("{ \"ciphertext\" : \"EXACT\" }".utf8)
        try outbox.enqueue(operationID: operationID, rawBody: raw)
        let transport = Transport([SyncHTTPResponse(statusCode: 503, body: Data()), SyncHTTPResponse(statusCode: 200, body: Data("{}".utf8))])
        let client = try SyncWorkerClient(baseURL: URL(string:"https://sync.invalid")!,deviceToken:Data((0..<32).map(UInt8.init)),transport:transport)
        do { _ = try await client.drainOne(from: outbox); throw Failure() } catch SyncWorkerClientError.httpStatus(503) {}
        try require(try outbox.pending().count == 1)
        _ = try await client.drainOne(from: outbox)
        try require(try outbox.pending().isEmpty)
        let requests = await transport.captured()
        try require(requests.count == 2 && requests.allSatisfy { $0.httpBody == raw })
        try require(requests.allSatisfy { $0.value(forHTTPHeaderField:"Authorization")?.hasPrefix("Device gdt1_") == true })
        // A client built before enrollment must still authenticate afterwards.
        //
        // The settings screen constructs its client once, while no token is
        // stored yet. On a real install that client then refused every read
        // until the app was restarted, because the token it captured at
        // construction never changed.
        let lateOutbox = SyncOutbox(fileURL: directory.appendingPathComponent("late.plist"))
        try lateOutbox.enqueue(operationID: "10000000-0000-4000-8000-000000000002", rawBody: raw)
        var stored: Data? = nil
        let lateTransport = Transport([SyncHTTPResponse(statusCode: 200, body: Data("{}".utf8))])
        let lateClient = try SyncWorkerClient(
            baseURL: URL(string: "https://sync.invalid")!,
            token: { stored },
            transport: lateTransport
        )
        // Nothing stored yet: refused here, and never sent unauthenticated.
        do { _ = try await lateClient.drainOne(from: lateOutbox); throw Failure() }
        catch SyncWorkerClientError.invalidToken {}
        let beforeToken = await lateTransport.captured()
        try require(beforeToken.isEmpty)

        stored = Data((0..<32).map(UInt8.init))
        _ = try await lateClient.drainOne(from: lateOutbox)
        let lateRequests = await lateTransport.captured()
        try require(lateRequests.count == 1)
        try require(lateRequests[0].value(forHTTPHeaderField: "Authorization")?.hasPrefix("Device gdt1_") == true)

        let deviceTransport = Transport([SyncHTTPResponse(statusCode: 200, body: Data("{}".utf8))])
        let deviceClient = try SyncWorkerClient(
            baseURL: URL(string: "https://sync.invalid")!,
            deviceToken: Data((0..<32).map(UInt8.init)),
            transport: deviceTransport
        )
        _ = try await deviceClient.devices()
        let deviceRequests = await deviceTransport.captured()
        try require(deviceRequests.count == 1)
        try require(deviceRequests[0].url?.path == "/v1/account/devices")
        try require(deviceRequests[0].url?.query == nil)
        try require(deviceRequests[0].value(forHTTPHeaderField: "Authorization")?.hasPrefix("Device gdt1_") == true)

        print("Swift sync worker client: 3 passed")
    }
    private static func require(_ value:@autoclosure() throws->Bool)throws{if try !value(){throw Failure()}}
    private struct Failure:Error{}
}
