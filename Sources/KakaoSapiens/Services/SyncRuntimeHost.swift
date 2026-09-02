import Foundation

/// 앱 lifecycle이 붙잡는 단 하나의 지점.
///
/// 기본값이 전부 꺼짐이므로 여기에 연결하는 것만으로는 요청이 한 건도 나가지
/// 않는다. 실제 pull은 연결이 활성화될 때 `attach(pull:)`로 주입한다.
@MainActor public final class SyncRuntimeHost: ObservableObject {
    public static let shared = SyncRuntimeHost()

    private var coordinator = SyncRuntimeCoordinator(
        switches: .init(syncEnabled: false, remoteReadEnabled: false, remoteReplyEnabled: false),
        pull: {})

    /// 화면이 이것을 본다. coordinator를 건드릴 때마다 여기로 옮겨 담는다.
    @Published public private(set) var status: SyncRuntimeStatus = .disabled

    private init() {}

    private func publishStatus() { status = coordinator.status }
    public var canReadRemote: Bool { coordinator.canReadRemote }
    public var canReplyRemote: Bool { coordinator.canReplyRemote }

    /// 연결이 만들어진 뒤에만 부른다. 부르기 전에는 아무 일도 하지 않는 coordinator다.
    public func attach(switches: SyncRuntimeSwitches, pull: @escaping () async -> Void) {
        coordinator = SyncRuntimeCoordinator(switches: switches, pull: pull)
        publishStatus()
    }

    public func set(_ switches: SyncRuntimeSwitches) { coordinator.set(switches); publishStatus() }
    public func pauseForRevokedToken() { coordinator.pauseForRevokedToken(); publishStatus() }
    public func run(_ trigger: SyncRuntimeTrigger) async {
        await coordinator.run(trigger)
        publishStatus()
    }

    /// 상태 표시 문구. `syncEnabled=false`인 동안 "동기화 중"이라고 말하지 않는다.
    public var statusLabel: String { status.label }
}
