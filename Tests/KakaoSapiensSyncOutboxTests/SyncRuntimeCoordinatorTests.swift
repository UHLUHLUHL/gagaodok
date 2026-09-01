import Foundation

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message: message) } }

private actor Counter { var value = 0; func increment() { value += 1 } }
@main private struct Runner {
    static func main() async throws {
        let counter = Counter()
        let disabled = SyncRuntimeCoordinator(switches: .init(syncEnabled: false, remoteReadEnabled: true, remoteReplyEnabled: true), pull: { await counter.increment() })
        await disabled.foreground()
        let disabledCount = await counter.value
        try check(disabledCount == 0, "disabled sync made a request")
        let enabled = SyncRuntimeCoordinator(switches: .init(syncEnabled: true, remoteReadEnabled: false, remoteReplyEnabled: false), pull: { await counter.increment() })
        await enabled.foreground()
        let enabledCount = await counter.value
        let canReadRemote = enabled.canReadRemote
        let canReplyRemote = enabled.canReplyRemote
        try check(enabledCount == 1 && !canReadRemote && !canReplyRemote, "switches are not independent")
        print("2 runtime switch tests passed")
    }
}
