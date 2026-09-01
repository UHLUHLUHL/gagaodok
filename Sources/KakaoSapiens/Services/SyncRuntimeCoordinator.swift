import Foundation

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
@MainActor public final class SyncRuntimeCoordinator {
    public private(set) var switches: SyncRuntimeSwitches
    private let pull: () async -> Void
    private var pulling = false
    public init(switches: SyncRuntimeSwitches, pull: @escaping () async -> Void) { self.switches = switches; self.pull = pull }
    public var canReadRemote: Bool { switches.syncEnabled && switches.remoteReadEnabled }
    public var canReplyRemote: Bool { switches.syncEnabled && switches.remoteReplyEnabled }
    public func set(_ switches: SyncRuntimeSwitches) { self.switches = switches }
    public func foreground() async {
        guard switches.syncEnabled, !pulling else { return }
        pulling = true; defer { pulling = false }
        await pull()
    }
}
