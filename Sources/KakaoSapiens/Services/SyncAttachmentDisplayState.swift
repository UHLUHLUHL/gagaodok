import Foundation

/// 서버 상태와 마지막 오류만으로 화면 상태를 정한다.
///
/// 화면에서 떼어낸 이유는 이 판단이 검증 가능해야 하기 때문이다. 앱을 설치하지
/// 않는 동안에도 이 규칙만은 테스트로 고정된다.
public enum SyncAttachmentDisplayState: String, Equatable {
    /// `allocated` 또는 `uploaded` — 아직 다른 기기가 받을 수 없다.
    case pending
    case ready
    /// 다시 시도하면 결과가 달라질 수 있다.
    case retryable
    /// 다시 시도해도 결과가 같다.
    case unavailable

    public static func state(
        remoteState: String, lastError: SyncAttachmentError?
    ) -> SyncAttachmentDisplayState {
        switch remoteState {
        case "allocated", "uploaded":
            return .pending
        case "ready":
            switch lastError {
            case nil:
                return .ready
            // 다시 시도해도 같은 결과가 나오는 실패다. 재시도를 권하지 않는다.
            case .hashMismatch, .sizeMismatch, .decryptionFailed, .tooLarge, .identityNotCanonical:
                return .unavailable
            case .notReady:
                return .retryable
            }
        default:
            // abandoned·tombstoned·garbage_collected, 그리고 아직 모르는 값.
            // 모르는 상태를 ready로 낙관하지 않는다.
            return .unavailable
        }
    }
}
