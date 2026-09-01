import Foundation

private struct Failure: Error { let message: String }
private func check(_ v: @autoclosure () -> Bool, _ m: String) throws {
    if !v() { throw Failure(message: m) }
}

@main private struct Runner {
    static func main() throws {
        typealias S = SyncAttachmentDisplayState
        try check(S.state(remoteState: "allocated", lastError: nil) == .pending, "allocated is not pending")
        try check(S.state(remoteState: "uploaded", lastError: nil) == .pending, "uploaded is not pending")
        try check(S.state(remoteState: "ready", lastError: nil) == .ready, "ready is not ready")
        // 다시 시도해도 결과가 같은 실패는 재시도로 안내하지 않는다.
        try check(S.state(remoteState: "ready", lastError: .hashMismatch) == .unavailable, "hash mismatch is retryable")
        try check(S.state(remoteState: "ready", lastError: .sizeMismatch) == .unavailable, "size mismatch is retryable")
        try check(S.state(remoteState: "ready", lastError: .decryptionFailed) == .unavailable, "decryption failure is retryable")
        try check(S.state(remoteState: "ready", lastError: .notReady) == .retryable, "notReady is not retryable")
        // 되돌릴 수 없는 서버 상태는 전부 unavailable이다.
        for dead in ["abandoned", "tombstoned", "garbage_collected"] {
            try check(S.state(remoteState: dead, lastError: nil) == .unavailable, "\(dead) is not unavailable")
        }
        // 모르는 상태를 ready로 낙관하지 않는다.
        try check(S.state(remoteState: "something_new", lastError: nil) == .unavailable, "an unknown state defaulted to ready")
        print("11 attachment display state checks passed")
    }
}
