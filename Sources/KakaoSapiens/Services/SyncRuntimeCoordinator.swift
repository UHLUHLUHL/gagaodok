import Foundation

/// 동기화가 도는 계기. 이 넷 말고는 없다.
///
/// APNs·FCM·background polling을 쓰지 않는다.
public enum SyncRuntimeTrigger: String, Equatable {
    case launch
    case foreground
    case manual
    case afterSend
}

public enum SyncRuntimeStatus: String, Equatable {
    case disabled
    case idle
    case running
    case pausedRevoked
    case offline

    /// 화면에 그대로 쓰는 문구.
    ///
    /// `disabled`에서 "동기화 중"이라고 말하지 않는 것이 이 매핑의 핵심이다.
    /// 순수 함수로 둔 이유는 앱을 띄우지 않고도 그 불변식을 시험하기 위해서다.
    public var label: String {
        switch self {
        case .disabled: return "동기화가 꺼져 있습니다."
        case .idle: return "마지막으로 확인함"
        case .running: return "확인하는 중"
        case .pausedRevoked: return "이 기기의 연결이 해제되었습니다."
        case .offline: return "연결할 수 없습니다."
        }
    }
}

public struct SyncRuntimeSwitches: Equatable {
    public var syncEnabled: Bool
    public var remoteReadEnabled: Bool
    public var remoteReplyEnabled: Bool
    public init(syncEnabled: Bool, remoteReadEnabled: Bool, remoteReplyEnabled: Bool) {
        self.syncEnabled = syncEnabled; self.remoteReadEnabled = remoteReadEnabled; self.remoteReplyEnabled = remoteReplyEnabled
    }
}

/// Foreground-only scheduling boundary. Turning any feature off preserves its
/// local data; it changes only whether the corresponding action is permitted.
///
/// 스위치를 끄는 것은 지우는 것이 아니다. replica·로컬 대화·outbox·journal은
/// 그대로 남는다.
@MainActor public final class SyncRuntimeCoordinator {
    public private(set) var switches: SyncRuntimeSwitches
    public private(set) var status: SyncRuntimeStatus
    private let pull: () async -> Void
    private var pulling = false
    private var revoked = false

    public init(switches: SyncRuntimeSwitches, pull: @escaping () async -> Void) {
        self.switches = switches
        self.pull = pull
        self.status = switches.syncEnabled ? .idle : .disabled
    }

    public var canReadRemote: Bool { switches.syncEnabled && switches.remoteReadEnabled && !revoked }
    public var canReplyRemote: Bool { switches.syncEnabled && switches.remoteReplyEnabled && !revoked }

    public func set(_ switches: SyncRuntimeSwitches) {
        self.switches = switches
        if !revoked { status = switches.syncEnabled ? .idle : .disabled }
    }

    /// token이 폐기되면 멈추되 outbox와 journal은 남긴다.
    public func pauseForRevokedToken() {
        revoked = true
        status = .pausedRevoked
    }

    /// 네 계기 전부에서 이것을 부른다.
    ///
    /// `syncEnabled`가 꺼져 있으면 요청이 한 건도 나가지 않는다. 설정 화면이나
    /// 원격 방 화면을 열었다는 이유만으로는 나가지 않는다.
    public func run(_ trigger: SyncRuntimeTrigger) async {
        guard !revoked else { return }
        guard switches.syncEnabled else { status = .disabled; return }
        // 단일 실행 잠금. 겹쳐 불러도 한 번만 돈다.
        guard !pulling else { return }
        pulling = true
        status = .running
        await pull()
        pulling = false
        if !revoked { status = .idle }
    }

    /// 기존 호출부 호환.
    public func foreground() async { await run(.foreground) }
}
