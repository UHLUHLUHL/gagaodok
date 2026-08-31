import Foundation

private actor DeviceTransport: SyncHTTPTransport {
    var response: SyncHTTPResponse
    var requestCount = 0
    init(_ response: SyncHTTPResponse) { self.response = response }
    func send(_ request: URLRequest) async throws -> SyncHTTPResponse {
        requestCount += 1
        return response
    }
    func count() -> Int { requestCount }
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

        print("Swift sync device list model: 3 passed")
    }

    private static func require(_ value: @autoclosure () throws -> Bool) throws {
        if try !value() { throw Failure() }
    }
    private struct Failure: Error {}
}
