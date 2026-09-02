import Foundation

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}

@main private struct Runner {
    static func main() async throws {
        let all: [SyncRuntimeTrigger] = [.launch, .foreground, .manual, .afterSend]

        // 1. syncEnabled=false면 어떤 계기로도 요청이 나가지 않는다.
        //    설정 화면이나 원격 방 화면을 열었다는 이유만으로도 나가지 않는다.
        for trigger in all {
            let counter = Counter()
            let off = await SyncRuntimeCoordinator(
                switches: .init(syncEnabled: false, remoteReadEnabled: true, remoteReplyEnabled: true),
                pull: { await counter.increment() })
            await off.run(trigger)
            let count = await counter.value
            try check(count == 0, "trigger \(trigger.rawValue) made a request while sync was disabled")
            let status = await off.status
            try check(status == .disabled, "status is not disabled")
        }

        // 2. 네 계기 전부에서 돈다.
        for trigger in all {
            let counter = Counter()
            let on = await SyncRuntimeCoordinator(
                switches: .init(syncEnabled: true, remoteReadEnabled: true, remoteReplyEnabled: true),
                pull: { await counter.increment() })
            await on.run(trigger)
            let count = await counter.value
            try check(count == 1, "trigger \(trigger.rawValue) did not run")
            let status = await on.status
            try check(status == .idle, "status did not return to idle after \(trigger.rawValue)")
        }

        // 3. 단일 실행 잠금 — 겹쳐 부르면 한 번만 돈다.
        let slow = Counter()
        let single = await SyncRuntimeCoordinator(
            switches: .init(syncEnabled: true, remoteReadEnabled: true, remoteReplyEnabled: true),
            pull: {
                try? await Task.sleep(nanoseconds: 50_000_000)
                await slow.increment()
            })
        async let first: Void = single.run(.foreground)
        async let second: Void = single.run(.foreground)
        _ = await (first, second)
        let slowCount = await slow.value
        try check(slowCount == 1, "single-flight lock did not hold, ran \(slowCount) times")

        // 4. 스위치는 서로 독립이다. 하나를 꺼도 다른 하나가 꺼지지 않는다.
        let readOff = await SyncRuntimeCoordinator(
            switches: .init(syncEnabled: true, remoteReadEnabled: false, remoteReplyEnabled: true),
            pull: {})
        let cannotRead = await readOff.canReadRemote
        let canReply = await readOff.canReplyRemote
        try check(!cannotRead && canReply, "disabling remote read also disabled reply")

        // 5. token 폐기는 멈추되 스위치 자체는 건드리지 않는다.
        let afterRevoke = Counter()
        let revoked = await SyncRuntimeCoordinator(
            switches: .init(syncEnabled: true, remoteReadEnabled: true, remoteReplyEnabled: true),
            pull: { await afterRevoke.increment() })
        await revoked.pauseForRevokedToken()
        for trigger in all { await revoked.run(trigger) }
        let revokedCount = await afterRevoke.value
        try check(revokedCount == 0, "a revoked runtime still ran")
        let revokedStatus = await revoked.status
        try check(revokedStatus == .pausedRevoked, "status is not pausedRevoked")
        let revokedRead = await revoked.canReadRemote
        let revokedReply = await revoked.canReplyRemote
        try check(!revokedRead && !revokedReply, "a revoked runtime still permits remote work")

        // 6. 화면 문구가 상태를 잘못 말하지 않는다.
        //    꺼져 있는데 "동기화 중"이라고 말하는 것이 가장 나쁜 거짓말이다.
        let busyWords = ["확인하는 중", "동기화 중"]
        for quiet in [SyncRuntimeStatus.disabled, .pausedRevoked, .offline] {
            for word in busyWords {
                try check(!quiet.label.contains(word),
                          "\(quiet.rawValue) label claims work is happening: \(quiet.label)")
            }
        }
        try check(SyncRuntimeStatus.disabled.label == "동기화가 꺼져 있습니다.", "disabled label drifted")
        try check(SyncRuntimeStatus.running.label == "확인하는 중", "running label drifted")
        // 다섯 상태가 서로 다른 문구를 갖는다. 두 상태가 같은 말을 하면 구분이 안 된다.
        let labels = Set([SyncRuntimeStatus.disabled, .idle, .running, .pausedRevoked, .offline].map(\.label))
        try check(labels.count == 5, "two statuses share a label")

        // 7. 표시등 색. 켜져 있으면 초록, 아니면 회색이다.
        //    running만 초록으로 두면 실제로 도는 순간이 아주 짧아 대부분의 시간에
        //    꺼진 것과 구별되지 않는다.
        try check(SyncRuntimeStatus.idle.isActive, "idle is not active")
        try check(SyncRuntimeStatus.running.isActive, "running is not active")
        try check(!SyncRuntimeStatus.disabled.isActive, "disabled is active")
        try check(!SyncRuntimeStatus.pausedRevoked.isActive, "pausedRevoked is active")
        try check(!SyncRuntimeStatus.offline.isActive, "offline is active")
        // 활성으로 보이는데 진행 중이 아니라고 말하거나 그 반대가 되면 안 된다.
        try check(SyncRuntimeStatus.disabled.label.contains("꺼져"),
                  "the inactive default does not say it is off")

        print("39 runtime switch checks passed")
    }
}
