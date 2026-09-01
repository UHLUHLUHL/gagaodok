import Foundation

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}

private actor Recorder {
    var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}

private struct StubTransport: SyncHTTPTransport {
    let recorder: Recorder
    let status: Int
    let body: Data
    func send(_ request: URLRequest) async throws -> SyncHTTPResponse {
        await recorder.record(request)
        return SyncHTTPResponse(statusCode: status, body: body)
    }
}

@main private struct Runner {
    static func main() async throws {
        let attachment = "70000000-0000-4000-8000-000000000001"
        let token = Data(repeating: 0x11, count: 32)
        let base = URL(string: "https://example.invalid")!

        let uploadRecorder = Recorder()
        let uploadClient = try SyncWorkerClient(
            baseURL: base, deviceToken: token,
            transport: StubTransport(recorder: uploadRecorder, status: 204, body: Data()))
        let payload = Data(repeating: 0x5A, count: 130)
        _ = try await uploadClient.putAttachmentContent(attachmentID: attachment, body: payload)
        let uploads = await uploadRecorder.requests
        try check(uploads.count == 1, "upload did not send exactly one request")
        try check(uploads[0].httpMethod == "PUT", "upload is not a PUT")
        try check(uploads[0].url?.path == "/v1/attachments/\(attachment)/content", "upload path is wrong")
        try check(uploads[0].httpBody == payload, "upload body was altered")

        let completeRecorder = Recorder()
        let completeClient = try SyncWorkerClient(
            baseURL: base, deviceToken: token,
            transport: StubTransport(recorder: completeRecorder, status: 204, body: Data()))
        _ = try await completeClient.completeAttachment(attachmentID: attachment)
        let completes = await completeRecorder.requests
        try check(completes[0].httpMethod == "POST", "complete is not a POST")
        try check(completes[0].url?.path == "/v1/attachments/\(attachment)/complete", "complete path is wrong")
        // 원격에서 한 번 물렸던 자리다. body를 붙이면 안 된다.
        try check(completes[0].httpBody == nil || completes[0].httpBody?.isEmpty == true,
                  "complete must send no body")

        let downloadRecorder = Recorder()
        let bytes = Data(repeating: 0x7F, count: 64)
        let downloadClient = try SyncWorkerClient(
            baseURL: base, deviceToken: token,
            transport: StubTransport(recorder: downloadRecorder, status: 200, body: bytes))
        let response = try await downloadClient.getAttachmentContent(attachmentID: attachment)
        try check(response.body == bytes, "download body was altered")
        let downloads = await downloadRecorder.requests
        try check(downloads[0].httpMethod == "GET", "download is not a GET")

        // 소문자 UUID는 Worker 경로에 매칭되지 않으므로 클라이언트가 먼저 막는다.
        // 글자가 들어간 ID여야 대소문자 차이가 실제로 생긴다. 숫자뿐인 ID로
        // 시험하면 lowercased()가 원본과 같아 통과할 수 없는 검사가 된다.
        let lettered = "7000000A-0000-4000-8000-00000000000B"
        try check(lettered.lowercased() != lettered, "the fixture id has no letters to lowercase")
        var lowercaseRejected = false
        do { _ = try await downloadClient.getAttachmentContent(attachmentID: lettered.lowercased()) }
        catch { lowercaseRejected = true }
        try check(lowercaseRejected, "a non-canonical attachment id was accepted")
        // 같은 ID의 정규 형태는 받아들여야 한다. 위 거부가 우연이 아님을 확인한다.
        _ = try await downloadClient.getAttachmentContent(attachmentID: lettered)

        print("12 attachment client checks passed")
    }
}
