import Foundation

/// 앱 lifecycle이 붙잡는 단 하나의 지점.
///
/// 기본값이 전부 꺼짐이므로 여기에 연결하는 것만으로는 요청이 한 건도 나가지
/// 않는다. 실제 pull은 연결이 활성화될 때 `attach(pull:)`로 주입한다.
@MainActor public final class SyncRuntimeHost {
    public static let shared = SyncRuntimeHost()

    private var coordinator = SyncRuntimeCoordinator(
        switches: .init(syncEnabled: false, remoteReadEnabled: false, remoteReplyEnabled: false),
        pull: {})

    private init() {}

    public var status: SyncRuntimeStatus { coordinator.status }
    public var canReadRemote: Bool { coordinator.canReadRemote }
    public var canReplyRemote: Bool { coordinator.canReplyRemote }

    /// 연결이 만들어진 뒤에만 부른다. 부르기 전에는 아무 일도 하지 않는 coordinator다.
    public func attach(switches: SyncRuntimeSwitches, pull: @escaping () async -> Void) {
        coordinator = SyncRuntimeCoordinator(switches: switches, pull: pull)
    }

    public func set(_ switches: SyncRuntimeSwitches) { coordinator.set(switches) }
    public func pauseForRevokedToken() { coordinator.pauseForRevokedToken() }
    public func run(_ trigger: SyncRuntimeTrigger) async { await coordinator.run(trigger) }

    /// 상태 표시 문구. `syncEnabled=false`인 동안 "동기화 중"이라고 말하지 않는다.
    public var statusLabel: String {
        switch coordinator.status {
        case .disabled: return "동기화가 꺼져 있습니다."
        case .idle: return "마지막으로 확인함"
        case .running: return "확인하는 중"
        case .pausedRevoked: return "이 기기의 연결이 해제되었습니다."
        case .offline: return "연결할 수 없습니다."
        }
    }
}
