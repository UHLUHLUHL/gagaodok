import Foundation

private actor DeviceTransport: SyncHTTPTransport {
    var response: SyncHTTPResponse
    var requestCount = 0
    /// Answered instead of `response` when the request is a POST, so a revoke
    /// can be refused while the list keeps loading.
    var postResponse: SyncHTTPResponse?
    private(set) var seen: [(method: String, path: String)] = []
    init(_ response: SyncHTTPResponse, postResponse: SyncHTTPResponse? = nil) {
        self.response = response
        self.postResponse = postResponse
    }
    func send(_ request: URLRequest) async throws -> SyncHTTPResponse {
        requestCount += 1
        let method = request.httpMethod ?? "GET"
        seen.append((method, request.url?.path ?? ""))
        if method == "POST", let postResponse {
            if !(200..<300).contains(postResponse.statusCode) {
                throw SyncWorkerClientError.httpStatus(postResponse.statusCode)
            }
            return postResponse
        }
        return response
    }
    func count() -> Int { requestCount }
    func requests() -> [(method: String, path: String)] { seen }
}

@main
enum SyncDeviceListModelTests {
    @MainActor
    static func main() async throws {
        let body = Data(#"{"result":{"devices":[{"device_id":"B0000000-0000-4000-8000-000000000001","platform":"macos","linked_at":"2026-08-31T00:00:00Z","is_current":true},{"device_id":"B0000000-0000-4000-8000-000000000002","platform":"android_phone","linked_at":"2026-08-31T00:01:00Z","is_current":false}]}}"#.utf8)
        let transport = DeviceTransport(SyncHTTPResponse(statusCode: 200, body: body))
        let client = try SyncWorkerClient(
            baseURL: URL(string: "https://sync.invalid")!,
            deviceToken: Data(repeating: 1, count: 32),
            transport: transport
        )
        let model = SyncDeviceListModel(client: client)
        try require(model.state == .idle)
        let initialCount = await transport.count()
        try require(initialCount == 0)

        await model.load()
        guard case .loaded(let devices) = model.state else { throw Failure() }
        try require(devices.map(\.title) == ["Mac", "Android 폰"])
        try require(devices.first?.isCurrent == true)
        let loadedCount = await transport.count()
        try require(loadedCount == 1)

        let badTransport = DeviceTransport(SyncHTTPResponse(statusCode: 200, body: Data(#"{"result":{"devices":[{"device_id":"x","platform":"unknown","linked_at":"secret","is_current":false}]}}"#.utf8)))
        let badClient = try SyncWorkerClient(baseURL: URL(string: "https://sync.invalid")!, deviceToken: Data(repeating: 2, count: 32), transport: badTransport)
        let badModel = SyncDeviceListModel(client: badClient)
        await badModel.load()
        try require(badModel.state == .failed)

        // Removing another device: asking is not doing, and the list is read
        // back from the server rather than edited locally.
        let revokeTransport = DeviceTransport(
            SyncHTTPResponse(statusCode: 200, body: body),
            postResponse: SyncHTTPResponse(statusCode: 200, body: Data("{}".utf8))
        )
        let revokeClient = try SyncWorkerClient(
            baseURL: URL(string: "https://sync.invalid")!,
            deviceToken: Data(repeating: 3, count: 32),
            transport: revokeTransport
        )
        let revokeModel = SyncDeviceListModel(client: revokeClient)
        await revokeModel.load()
        guard case .loaded(let revokeDevices) = revokeModel.state else { throw Failure() }
        let phone = revokeDevices[1]
        revokeModel.requestRevoke(phone)
        try require(revokeModel.pendingRevoke == phone)
        let beforeConfirm = await revokeTransport.count()
        try require(beforeConfirm == 1)
        await revokeModel.confirmRevoke()
        try require(revokeModel.pendingRevoke == nil)
        try require(revokeModel.revokeFailed == false)
        let sent = await revokeTransport.requests()
        try require(sent.contains { $0.method == "POST" && $0.path == "/v1/account/devices/\(phone.id)/revoke" })
        try require(sent.filter { $0.method == "GET" }.count >= 2)

        // Revoking this device is never offered: it would leave the Mac
        // holding keys the account no longer honours.
        let current = revokeDevices[0]
        try require(revokeModel.canRevoke(current) == false)
        revokeModel.requestRevoke(current)
        try require(revokeModel.pendingRevoke == nil)

        // A refused revoke says so and leaves the list alone.
        let refusedTransport = DeviceTransport(
            SyncHTTPResponse(statusCode: 200, body: body),
            postResponse: SyncHTTPResponse(statusCode: 409, body: Data())
        )
        let refusedClient = try SyncWorkerClient(
            baseURL: URL(string: "https://sync.invalid")!,
            deviceToken: Data(repeating: 4, count: 32),
            transport: refusedTransport
        )
        let refusedModel = SyncDeviceListModel(client: refusedClient)
        await refusedModel.load()
        guard case .loaded(let refusedBefore) = refusedModel.state else { throw Failure() }
        refusedModel.requestRevoke(refusedBefore[1])
        await refusedModel.confirmRevoke()
        try require(refusedModel.revokeFailed == true)
        guard case .loaded(let refusedAfter) = refusedModel.state else { throw Failure() }
        try require(refusedAfter == refusedBefore)

        print("Swift sync device list model: 6 passed")
    }

    private static func require(_ value: @autoclosure () throws -> Bool) throws {
        if try !value() { throw Failure() }
    }
    private struct Failure: Error {}
}
