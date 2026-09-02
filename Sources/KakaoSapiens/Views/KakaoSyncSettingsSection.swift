import SwiftUI

/// The "기기 간 동기화 (합성 시험)" settings section.
///
/// A screen with no side effects of its own. Appearing reads stored status and
/// nothing else; everything that sends a request, stores a secret or writes the
/// replica is behind a button, and which buttons exist comes from the model's
/// `actions` rather than from conditions written here. A view cannot offer an
/// action the state machine considers unsafe.
///
/// This section never reads or writes a conversation. What a successful walk
/// fills is the opaque shadow replica, which no conversation screen consults.
struct KakaoSyncSettingsSection: View {
    @StateObject private var host = SyncSettingsHost()
    @ObservedObject private var runtime = SyncRuntimeHost.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            runtimeStatus

            if let model = host.model {
                SyncSettingsBody(
                    model: model,
                    host: host.environmentHost,
                    pairing: host.pairingModel,
                    pairingConnection: host.pairingConnection,
                    transition: host.transitionModel,
                    devices: host.deviceListModel,
                    rotation: host.rotationModel,
                    shadow: host.shadowModel,
                    shadowRoomTitle: host.shadowRoomTitle,
                    shadowRead: host.shadowReadModel
                )
            } else {
                unconfigured
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .task { await host.prepare() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("기기 간 동기화 (합성 시험)")
                .font(.custom("Pretendard-Bold", size: 13))
            Text("시험용 합성 계정만 연결합니다. 이 화면은 실제 대화를 읽거나 올리지 않습니다.")
                .font(.custom("Pretendard-Regular", size: 11))
                .foregroundColor(KakaoTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 지금 동기화가 실제로 무엇을 하고 있는지 한 줄로 말한다.
    ///
    /// 설정 파일이 없어도 보인다. 꺼져 있는 것과 설정이 없는 것은 다른 상태이고,
    /// 사용자는 둘 다 알아야 한다.
    private var runtimeStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(runtime.status.isActive ? Color.green : KakaoTheme.textSecondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(runtime.statusLabel)
                .font(.custom("Pretendard-Regular", size: 11))
                .foregroundColor(KakaoTheme.textSecondary)
        }
    }

    private var unconfigured: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("합성 시험 환경이 설정되어 있지 않습니다")
                .font(.custom("Pretendard-Medium", size: 12))
            Text("설정 파일이 없으면 이 화면은 아무것도 하지 않습니다. 시험 환경을 쓰려면 응용 프로그램 지원 폴더에 sync-synthetic.json을 두십시오.")
                .font(.custom("Pretendard-Regular", size: 11))
                .foregroundColor(KakaoTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KakaoTheme.sunken, in: RoundedRectangle(cornerRadius: 9))
    }
}

/// Builds the model once the environment file is found, and not before.
@MainActor
private final class SyncSettingsHost: ObservableObject {
    @Published private(set) var model: SyncOnboardingModel?
    @Published private(set) var pairingModel: SyncPairingHostUIModel?
    @Published private(set) var transitionModel: SyncAccountTransitionModel?
    @Published private(set) var deviceListModel: SyncDeviceListModel?
    @Published private(set) var rotationModel: SyncRecoveryRotationModel?
    @Published private(set) var shadowModel: SyncShadowUploadModel?
    @Published private(set) var shadowReadModel: SyncShadowReadModel?
    private(set) var pairingConnection: SyncConnectionConfiguration?
    private(set) var environmentHost = ""
    private(set) var shadowRoomTitle = ""

    /// The one room Phase 3 is allowed to copy, chosen by the user.
    ///
    /// Hard-coded rather than picked in the UI on purpose: a room picker over
    /// the whole list is one misclick away from copying a conversation nobody
    /// agreed to copy, and this phase is one room only.
    private static let designatedShadowRoom = UUID(
        uuidString: "90B3EE60-2244-4838-9C1E-10A27295F6EB"
    )!

    func prepare() async {
        guard model == nil, let environment = SyncSyntheticEnvironment.load() else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let directory = support.appendingPathComponent("KakaoSapiens/sync")
        let replica = SyncReplicaStore(fileURL: directory.appendingPathComponent("replica.plist"))
        let connectionStore = SyncConnectionStateStore(
            fileURL: directory.appendingPathComponent("connection.json")
        )
        guard let onboarding = try? SyncOnboardingCoordinator(
            baseURL: environment.baseURL,
            vault: KeychainSyncSecretVault(),
            connectionStore: connectionStore,
            journal: SyncEnrollmentJournal(
                fileURL: directory.appendingPathComponent("enrollment.json")
            ),
            transport: URLSessionSyncTransport(),
            // The word list ships as a package resource, so it lives in this
            // module's bundle rather than at the top of the app bundle. Asking
            // `.main` for it finds nothing, and the screen then fails to
            // prepare on every real install while passing every unit test.
            words: (try? SyncRecoveryMnemonic.bundledWords(bundle: .module)) ?? []
        ),
        let client = try? SyncWorkerClient(
            baseURL: environment.baseURL,
            // Read per request, not captured here. This screen is built while
            // nothing is stored yet, so a token taken now would stay empty for
            // the rest of the session and every read would be refused until
            // the app restarted.
            token: { Self.storedToken() },
            transport: URLSessionSyncTransport()
        ) else { return }

        environmentHost = environment.displayHost
        let built = SyncOnboardingModel(
            onboarding: onboarding,
            pull: SyncPullCoordinator(
                client: client,
                replica: replica,
                stateURL: directory.appendingPathComponent("pull.json")
            ),
            replica: replica,
            spaceID: "MAC_SPACE",
            platform: "macos",
            identity: { (environment.accountID, environment.deviceID, environment.enrollmentID) }
        )
        model = built
        deviceListModel = SyncDeviceListModel(client: client)

        // The account this device is actually in, which is not always the one
        // its synthetic environment file names. A device that joined an
        // existing account keeps its own pre-join account id in that file while
        // the account it really belongs to is recorded in connection state.
        // Scope keys are derived from the account, so reading the wrong one
        // encrypts under a key nobody else can open — while identity, order and
        // the content digest all still look correct.
        var activeAccountID = environment.accountID
        var activeDeviceID = environment.deviceID
        if case .available(let connection) = connectionStore.load() {
            activeAccountID = connection.accountID
            activeDeviceID = connection.deviceID
        }

        // Enrollment writes version 1, so the first rotation claims 2. A wrong
        // guess is refused by the Worker as a conflict rather than overwriting
        // whatever is current, so this is a starting point and not an
        // assumption the account depends on.
        rotationModel = SyncRecoveryRotationModel(
            coordinator: SyncRecoveryRotationCoordinator(
                // The joined account, not the pre-join one in the environment
                // file: the account is inside the recovery AAD, so wrapping
                // under the wrong one produces a phrase that cannot open the
                // master key when it is finally needed.
                accountID: activeAccountID,
                client: client,
                words: (try? SyncRecoveryMnemonic.bundledWords(bundle: .module)) ?? []
            )
        )

        // The conversation files live beside the app's other support data, not
        // in the sync directory: the shadow reads them where they already are
        // and writes nothing there.
        let storageDirectory = support.appendingPathComponent("KakaoSapiens")
        shadowRoomTitle = Self.roomTitle(
            for: Self.designatedShadowRoom, in: storageDirectory
        ) ?? "지정한 시험방"
        shadowModel = SyncShadowUploadModel(
            coordinator: SyncShadowUploadCoordinator(
                directory: directory,
                accountID: activeAccountID,
                deviceID: activeDeviceID,
                client: client,
                outbox: SyncOutbox(fileURL: directory.appendingPathComponent("shadow-outbox.plist"))
            ),
            roomID: Self.designatedShadowRoom,
            storageDirectory: storageDirectory
        )
        shadowReadModel = SyncShadowReadModel(
            reader: SyncShadowReader(accountID: activeAccountID, client: client)
        )
        // Reading stored status is the only thing that happens without a press.
        await built.refresh()

        let transitionCoordinator = SyncAccountTransitionCoordinator(
            vault: KeychainSyncSlottedSecretVault(),
            connectionStore: connectionStore,
            files: SyncTransitionFiles(directoryURL: directory),
            journal: SyncAccountTransitionJournal(fileURL: directory.appendingPathComponent("transition.json")),
            outbox: SyncOutbox(fileURL: directory.appendingPathComponent("outbox.plist"))
        )
        try? transitionCoordinator.recoverIfNeeded()
        if transitionCoordinator.availability() != .noActiveAccount {
            let transition = SyncAccountTransitionModel(service: transitionCoordinator)
            transition.refresh()
            transitionModel = transition
        }

        guard case .available(let connection) = connectionStore.load(),
              SyncPairingHostAvailability.canHost(connection: connection) else { return }
        let pairingClient = SyncPairingClient(
            baseURL: connection.baseURL,
            token: { Self.storedToken() },
            transport: URLSessionSyncTransport()
        )
        pairingConnection = connection
        pairingModel = SyncPairingHostUIModel(
            service: SyncPairingHostCoordinator(
                client: pairingClient,
                secrets: { SyncSecretStore.load() },
                random: SystemSyncRandomSource()
            )
        )
    }

    /// Read-only, and only the title. Used to name the room on screen so the
    /// user can see which one the button would copy.
    private static func roomTitle(for roomID: UUID, in storageDirectory: URL) -> String? {
        guard
            let data = try? Data(contentsOf: storageDirectory.appendingPathComponent("rooms_list.json")),
            let rooms = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return rooms.first { row in
            (row["id"] as? String)?.uppercased() == roomID.uuidString.uppercased()
        }?["title"] as? String
    }

    private static func storedToken() -> Data? {
        guard case .available(let bundle) = SyncSecretStore.load() else { return nil }
        return bundle.deviceToken
    }
}

private struct SyncSettingsBody: View {
    @ObservedObject var model: SyncOnboardingModel
    let host: String
    let pairing: SyncPairingHostUIModel?
    let pairingConnection: SyncConnectionConfiguration?
    let transition: SyncAccountTransitionModel?
    let devices: SyncDeviceListModel?
    let rotation: SyncRecoveryRotationModel?
    let shadow: SyncShadowUploadModel?
    let shadowRoomTitle: String
    let shadowRead: SyncShadowReadModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            statusRow
            if let phrase = model.recoveryPhrase { phraseCard(phrase) }
            buttons
            if let transition { SyncAccountTransitionCard(model: transition, onboarding: model) }
            if let devices { SyncDeviceListCard(model: devices) }
            if let rotation { SyncRecoveryRotationCard(model: rotation, nextVersion: 2) }
            if let shadow { SyncShadowUploadCard(model: shadow, roomTitle: shadowRoomTitle) }
            if let shadowRead { SyncShadowReadCard(model: shadowRead) }
            if let pairing, let pairingConnection {
                SyncPairingHostCard(model: pairing, connection: pairingConnection)
            }
            // The host only. A full URL could carry a path or query, and this
            // is the one thing about the endpoint the screen ever shows.
            Text("연결 대상: \(host)")
                .font(.custom("Pretendard-Regular", size: 10))
                .foregroundColor(KakaoTheme.textTertiary)
        }
    }

    private var statusRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.custom("Pretendard-Medium", size: 12))
                Text(statusDetail)
                    .font(.custom("Pretendard-Regular", size: 11))
                    .foregroundColor(KakaoTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KakaoTheme.sunken, in: RoundedRectangle(cornerRadius: 9))
    }

    private func phraseCard(_ phrase: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("복구 문구 (한 번만 표시됩니다)")
                .font(.custom("Pretendard-Bold", size: 12))
            Text(phrase)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("이 문구는 어디에도 저장되지 않습니다. 종이에 적어 따로 보관한 뒤 아래 버튼을 누르십시오. 문구를 잃고 연결된 기기도 모두 잃으면 복구할 수 없습니다.")
                .font(.custom("Pretendard-Regular", size: 11))
                .foregroundColor(KakaoTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KakaoTheme.rowHover, in: RoundedRectangle(cornerRadius: 9))
    }

    private var buttons: some View {
        HStack(spacing: 7) {
            if model.actions.canBeginConnection {
                action("합성 계정 연결 준비") { await model.beginConnection() }
            }
            if model.actions.canConfirmPhrase {
                action("문구를 적어 두었습니다") { await model.confirmPhraseSaved() }
            }
            if model.actions.canRetryEnrollment {
                action("같은 요청 다시 보내기") { await model.retryEnrollment() }
            }
            if model.actions.canAdvanceBootstrap {
                action("합성 스냅샷 한 페이지 받기") { await model.advanceBootstrap() }
            }
            Spacer(minLength: 0)
        }
    }

    private func action(_ title: String, _ work: @escaping () async -> Void) -> some View {
        Button {
            Task { await work() }
        } label: {
            Text(title)
                .font(.custom("Pretendard-Medium", size: 11))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(KakaoTheme.bubbleMine, in: RoundedRectangle(cornerRadius: 7))
                .foregroundColor(KakaoTheme.bubbleMineText)
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch model.state {
        case .connectedSyncOff, .replicaReady: return Color.green
        case .relinkRequired, .retryableError: return Color.orange
        default: return KakaoTheme.textTertiary
        }
    }

    private var statusTitle: String {
        switch model.state {
        case .disconnected: return "연결 안 됨"
        case .preparing: return "연결 준비 중"
        case .awaitingPhraseConfirmation: return "복구 문구 확인 필요"
        case .enrolling: return "등록 요청 중"
        case .connectedSyncOff: return "연결됨 · 동기화 꺼짐"
        case .bootstrapping: return "합성 스냅샷 받는 중"
        case .replicaReady: return "합성 자료 준비됨"
        case .relinkRequired: return "재연결 필요"
        case .retryableError: return "다시 시도할 수 있는 오류"
        }
    }

    private var statusDetail: String {
        switch model.state {
        case .disconnected:
            return "아직 아무것도 보내지 않았습니다."
        case .preparing:
            return "요청을 만들고 있습니다. 아직 보내지 않았습니다."
        case .awaitingPhraseConfirmation:
            return "문구를 보관하기 전에는 등록 요청을 보내지 않습니다."
        case .enrolling:
            return "서버 응답을 기다리는 중입니다."
        case .connectedSyncOff:
            return "계정만 연결했습니다. 실제 대화 동기화는 켜지지 않았습니다."
        case .bootstrapping(let applied):
            return "받은 항목 \(applied)개. 한 번에 한 페이지씩 받습니다."
        case .replicaReady(let entries):
            return "합성 항목 \(entries)개를 별도 보관소에 두었습니다. 기존 대화는 그대로입니다."
        case .relinkRequired:
            return "저장된 키와 연결 정보가 맞지 않습니다. 새 키를 자동으로 만들지 않습니다."
        case .retryableError(let error):
            return Self.detail(for: error)
        }
    }

    /// Failure text carries a cause, never a value: no endpoint, token, phrase
    /// or server message reaches the screen.
    private static func detail(for error: SyncOnboardingUIError) -> String {
        switch error {
        case .phraseNotConfirmed: return "문구 확인이 끝나지 않았습니다."
        case .enrollmentRefused: return "서버가 등록을 받지 않았습니다."
        case .enrollmentRefusedRetryPending:
            return "서버가 등록을 받지 않았습니다. 같은 요청을 그대로 다시 보낼 수 있습니다."
        case .storageFailed: return "이 기기에 저장하지 못했습니다."
        case .networkFailed: return "서버에 닿지 못했습니다."
        case .bootstrapFailed: return "받은 페이지를 적용하지 못했습니다. 같은 위치부터 다시 받습니다."
        case .notConnected: return "먼저 계정을 연결해야 합니다."
        }
    }
}

private struct SyncDeviceListCard: View {
    @ObservedObject var model: SyncDeviceListModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("연결된 기기")
                .font(.custom("Pretendard-Bold", size: 12))
            switch model.state {
            case .idle:
                detail("버튼을 누르면 이 계정에 연결된 기기만 확인합니다.")
                button("연결된 기기 보기") { await model.load() }
            case .loading:
                detail("기기 목록을 확인하고 있습니다.")
            case .failed:
                detail("기기 목록을 가져오지 못했습니다. 비밀값은 표시하지 않았습니다.")
                button("다시 시도") { await model.load() }
            case .loaded(let devices):
                if devices.isEmpty { detail("현재 표시할 기기가 없습니다.") }
                ForEach(devices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.title + (device.isCurrent ? " · 현재 기기" : ""))
                                .font(.custom("Pretendard-Medium", size: 11))
                            Text("연결: \(device.linkedAt)")
                                .font(.custom("Pretendard-Regular", size: 10))
                                .foregroundColor(KakaoTheme.textTertiary)
                        }
                        Spacer()
                    }
                }
                button("새로고침") { await model.load() }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KakaoTheme.sunken, in: RoundedRectangle(cornerRadius: 9))
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.custom("Pretendard-Regular", size: 11))
            .foregroundColor(KakaoTheme.textSecondary)
    }

    private func button(_ title: String, work: @escaping () async -> Void) -> some View {
        Button { Task { await work() } } label: {
            Text(title).font(.custom("Pretendard-Medium", size: 11))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(KakaoTheme.bubbleMine, in: RoundedRectangle(cornerRadius: 7))
        .foregroundColor(KakaoTheme.bubbleMineText)
    }
}

private struct SyncAccountTransitionCard: View {
    @ObservedObject var model: SyncAccountTransitionModel
    @ObservedObject var onboarding: SyncOnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("동기화 계정 관리")
                .font(.custom("Pretendard-Bold", size: 12))
            Text(detail)
                .font(.custom("Pretendard-Regular", size: 11))
                .foregroundColor(KakaoTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                if model.actions.canRequestUnlink {
                    button("이 기기 연결 해제") { model.requestUnlink() }
                }
                if model.actions.canConfirmUnlink {
                    button("연결 해제 확인") {
                        model.confirmUnlink()
                        Task { await onboarding.refresh() }
                    }
                }
                if model.actions.canDismiss { button("취소") { model.dismiss() } }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KakaoTheme.sunken, in: RoundedRectangle(cornerRadius: 9))
    }

    private var detail: String {
        switch model.state {
        case .confirmingUnlink:
            return "로컬 대화는 유지하고 이 Mac의 동기화 키와 shadow 자료만 제거합니다. 원격 계정과 다른 기기는 삭제하지 않습니다."
        case .blocked:
            return "동기화가 켜져 있거나 미전송 변경이 남아 있어 지금은 연결을 해제할 수 없습니다."
        case .unlinked:
            return "이 Mac의 연결을 해제했습니다. 로컬 대화는 그대로입니다."
        case .error:
            return "연결 해제를 완료하지 못했습니다. 기존 연결을 유지했습니다."
        default:
            return "로컬 대화를 보존한 채 이 Mac의 동기화 연결만 해제할 수 있습니다."
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.custom("Pretendard-Medium", size: 11))
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(KakaoTheme.bubbleMine, in: RoundedRectangle(cornerRadius: 7))
            .foregroundColor(KakaoTheme.bubbleMineText)
    }
}

private struct SyncPairingHostCard: View {
    @ObservedObject var model: SyncPairingHostUIModel
    let connection: SyncConnectionConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("새 기기 합류")
                .font(.custom("Pretendard-Bold", size: 12))
            Text(detail)
                .font(.custom("Pretendard-Regular", size: 11))
                .foregroundColor(KakaoTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let qrText = model.qrText,
               model.state == .sessionReady || model.state == .waitingClaim {
                SyncPairingQRCodeView(text: qrText)
                    .frame(width: 190, height: 190)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                Text("주변에서 QR이 보이지 않게 하세요. QR은 5분 뒤 만료됩니다.")
                    .font(.custom("Pretendard-Regular", size: 10))
                    .foregroundColor(Color.orange)
            }

            if case .verifySAS(let digits) = model.state {
                Text(digits)
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .accessibilityLabel("기기 확인 번호 \(digits)")
                Text("새 기기에도 같은 6자리가 보일 때만 승인하세요.")
                    .font(.custom("Pretendard-Regular", size: 10))
                    .foregroundColor(KakaoTheme.textSecondary)
            }

            HStack(spacing: 7) {
                if model.actions.canOpenSession {
                    action("합류 QR 만들기") {
                        await model.openSession(
                            accountID: connection.accountID,
                            baseURL: connection.baseURL
                        )
                    }
                }
                if model.actions.canPoll {
                    action("합류 요청 확인") { await model.poll() }
                }
                if model.actions.canApprove {
                    action("6자리 일치 · 승인") { await model.approve(confirmed: true) }
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KakaoTheme.rowHover, in: RoundedRectangle(cornerRadius: 9))
        .onDisappear { model.reset() }
    }

    private func action(_ title: String, work: @escaping () async -> Void) -> some View {
        Button {
            Task { await work() }
        } label: {
            Text(title)
                .font(.custom("Pretendard-Medium", size: 11))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(KakaoTheme.bubbleMine, in: RoundedRectangle(cornerRadius: 7))
                .foregroundColor(KakaoTheme.bubbleMineText)
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        switch model.state {
        case .idle: return "Mac에 연결된 합성 계정으로 phone 또는 tablet을 초대합니다."
        case .sessionReady, .waitingClaim: return "새 기기에서 가가오독 앱의 QR 스캔을 여세요."
        case .verifySAS: return "두 화면의 확인 번호를 비교하세요."
        case .approving: return "새 기기를 승인하고 있습니다."
        case .completed: return "새 기기가 합류했습니다. 동기화는 아직 꺼져 있습니다."
        case .expired: return "QR이 만료됐습니다. 새 QR을 만드세요."
        case .error: return "합류를 진행하지 못했습니다. 비밀값은 표시하지 않았습니다."
        }
    }
}

/// Reissuing the recovery phrase.
///
/// The three enrolled devices were connected with a phrase nobody wrote down,
/// which means the account is one lost-devices event away from being
/// unrecoverable. This card fixes that without disturbing the link: the master
/// key is unchanged, so no device has to pair again.
///
/// The confirmation field is not a formality. What is typed is decoded back to
/// entropy and used to actually unwrap the master key — the same path a
/// recovery on a blank device takes. Until that succeeds the card does not say
/// the account is recoverable, because it is not yet known to be.
private struct SyncRecoveryRotationCard: View {
    @ObservedObject var model: SyncRecoveryRotationModel
    let nextVersion: UInt32

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("복구 문구 재발급")
                .font(.custom("Pretendard-Bold", size: 12))

            switch model.stage {
            case .idle:
                detail("지금 계정의 복구 문구는 어디에도 기록돼 있지 않습니다. 새 문구를 발급하면 연결된 기기는 그대로 두고 문구만 바뀝니다.")
                button("새 복구 문구 발급") { await model.issue(nextVersion: nextVersion) }

            case .awaitingConfirmation(let phrase, let version):
                Text(phrase)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KakaoTheme.rowHover, in: RoundedRectangle(cornerRadius: 7))
                detail("버전 \(version). 종이에 적은 뒤 아래에 그대로 다시 입력하십시오. 다시 입력해 확인하기 전까지는 복구가 된다고 볼 수 없습니다.")
                TextField("적어 둔 문구를 입력", text: $model.typedPhrase)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                HStack(spacing: 7) {
                    plainButton("확인") { model.confirm() }
                    Spacer(minLength: 0)
                }

            case .confirmed(let version):
                detail("복구 문구 버전 \(version) 확인됨. 적어 둔 문구로 계정 master key를 실제로 풀어 확인했습니다.")

            case .failed(let error):
                detail(message(for: error))
                HStack(spacing: 7) {
                    if case .phraseMismatch = error {
                        plainButton("문구 다시 입력") { model.retryConfirmation() }
                    } else {
                        button("다시 시도") { await model.issue(nextVersion: nextVersion) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KakaoTheme.sunken, in: RoundedRectangle(cornerRadius: 9))
    }

    private func message(for error: SyncRecoveryRotationError) -> String {
        switch error {
        case .phraseMismatch:
            return "입력한 문구가 화면의 문구와 다릅니다. 새 문구 자체는 이미 발급됐으니 다시 입력하십시오."
        case .rejected(let status):
            return "서버가 요청을 받지 않았습니다 (\(status)). 새 문구는 발급되지 않았습니다."
        case .transport:
            return "서버에 닿지 못했습니다. 새 문구는 발급되지 않았습니다."
        case .secretsUnavailable:
            return "이 기기에 계정 키가 없습니다. 먼저 계정에 연결하십시오."
        case .wordListUnavailable:
            return "단어 목록을 읽지 못했습니다."
        case .malformedResponse:
            return "요청을 만들지 못했습니다."
        case .nothingToConfirm:
            return "확인할 발급 건이 없습니다."
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.custom("Pretendard-Regular", size: 11))
            .foregroundColor(KakaoTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func button(_ title: String, work: @escaping () async -> Void) -> some View {
        plainButton(title) { Task { await work() } }
    }

    private func plainButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Pretendard-Medium", size: 11))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(KakaoTheme.bubbleMine, in: RoundedRectangle(cornerRadius: 7))
                .foregroundColor(KakaoTheme.bubbleMineText)
        }
        .buttonStyle(.plain)
    }
}

/// The one-way shadow copy of the designated test room.
///
/// One room, one direction, one button. The report it shows is counts and a
/// hash — never a title or a line of the conversation — because the question
/// being answered is "did every row arrive", not "what does it say".
///
/// The remote numbers are read back from the change feed rather than tallied
/// from the upload responses. An upload that answered "applied" proves the
/// request was taken, not that another device will see the row.
private struct SyncShadowUploadCard: View {
    @ObservedObject var model: SyncShadowUploadModel
    let roomTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("시험방 shadow 복사 (단방향)")
                .font(.custom("Pretendard-Bold", size: 12))

            switch model.stage {
            case .idle:
                detail("\(roomTitle) 한 방만 암호화해 합성 Worker로 단방향 복사합니다. 원본 대화 파일은 읽기만 하고 고치지 않으며, 서버가 준 것을 원본에 되쓰지도 않습니다. 첨부 이미지는 이번 회차에서 복사하지 않습니다.")
                button("shadow 복사 실행") { await model.run() }

            case .running:
                detail("복사하는 중입니다.")

            case .finished(let report):
                report.matches ? detail("로컬과 원격이 일치합니다.") : detail("로컬과 원격이 다릅니다. 아래 숫자를 확인하십시오.")
                row("올린 operation", "\(report.uploadedOperations)")
                row("turn", "로컬 \(report.localTurnCount) / 원격 \(report.remoteTurnCount)")
                row("말풍선", "로컬 \(report.localBubbleCount) / 원격 \(report.remoteBubbleCount)")
                if report.skippedAttachments > 0 {
                    row("복사 안 한 첨부", "\(report.skippedAttachments)")
                }
                // Identity and order only; the text is not in this digest.
                row("내용 hash", String(report.localContentHash.prefix(16)) + "…")

            case .failed(let error):
                detail(message(for: error))
                button("다시 시도") { await model.run() }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KakaoTheme.sunken, in: RoundedRectangle(cornerRadius: 9))
    }

    private func message(for error: SyncShadowUploadError) -> String {
        switch error {
        case .secretsUnavailable: return "이 기기에 계정 키가 없습니다. 먼저 계정에 연결하십시오."
        case .roomNotFound: return "지정한 시험방을 찾지 못했습니다."
        case .unreadableStorage: return "로컬 대화 파일을 읽지 못했습니다. 원본은 그대로입니다."
        case .uploadFailed(let status): return "서버가 operation을 받지 않았습니다 (\(status)). 남은 것은 outbox에 그대로 있어 다시 시도하면 이어집니다."
        case .transport: return "서버에 닿지 못했습니다. 남은 것은 outbox에 그대로 있습니다."
        case .projectionUnreadable: return "원격 projection을 읽지 못해 대조하지 못했습니다."
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.custom("Pretendard-Regular", size: 11))
                .foregroundColor(KakaoTheme.textSecondary)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 11, design: .monospaced))
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.custom("Pretendard-Regular", size: 11))
            .foregroundColor(KakaoTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func button(_ title: String, work: @escaping () async -> Void) -> some View {
        Button { Task { await work() } } label: {
            Text(title)
                .font(.custom("Pretendard-Medium", size: 11))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(KakaoTheme.bubbleMine, in: RoundedRectangle(cornerRadius: 7))
                .foregroundColor(KakaoTheme.bubbleMineText)
        }
        .buttonStyle(.plain)
    }
}

/// Reading a room the phone owns.
///
/// The counterpart of the upload card, one direction the other way. The room id
/// is typed in because this device has no local copy of that room to pick from —
/// the phone reports it after it writes.
private struct SyncShadowReadCard: View {
    @ObservedObject var model: SyncShadowReadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("다른 기기의 방 받아 확인 (역방향)")
                .font(.custom("Pretendard-Bold", size: 12))
            detail("폰이 올린 방을 받아 이 기기 키로 실제로 풀 수 있는지 확인합니다. 대화 내용은 표시하지 않습니다.")
            TextField("폰이 알려준 방 ID", text: $model.roomIDText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))

            switch model.stage {
            case .idle, .failed:
                if case .failed(let error) = model.stage { detail(message(for: error)) }
                button("받아서 확인") { await model.run() }
                    .opacity(model.canRun ? 1 : 0.4)
            case .running:
                detail("받아서 확인하는 중입니다.")
            case .finished(let result):
                detail(result.allDecrypted ? "받은 말풍선을 모두 풀었습니다." : "풀지 못한 말풍선이 있습니다.")
                row("공간", result.spaceID)
                row("turn", "\(result.turnCount)")
                row("말풍선", "\(result.bubbleCount)")
                row("복호화 성공", "\(result.decryptedCount) / \(result.bubbleCount)")
                row("내용 hash", String(result.contentHash.prefix(16)) + "…")
                row("진단", result.diagnostic)
                button("다시 확인") { await model.run() }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KakaoTheme.sunken, in: RoundedRectangle(cornerRadius: 9))
    }

    private func message(for error: SyncShadowReadError) -> String {
        switch error {
        case .secretsUnavailable: return "이 기기에 계정 키가 없습니다."
        case .transport: return "서버에 닿지 못했습니다."
        case .malformedProjection: return "받은 자료의 모양이 계약과 다릅니다."
        case .roomAbsent: return "그 방이 아직 이 계정에 도착하지 않았습니다."
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.custom("Pretendard-Regular", size: 11))
                .foregroundColor(KakaoTheme.textSecondary)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 11, design: .monospaced))
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.custom("Pretendard-Regular", size: 11))
            .foregroundColor(KakaoTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func button(_ title: String, work: @escaping () async -> Void) -> some View {
        Button { Task { await work() } } label: {
            Text(title)
                .font(.custom("Pretendard-Medium", size: 11))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(KakaoTheme.bubbleMine, in: RoundedRectangle(cornerRadius: 7))
                .foregroundColor(KakaoTheme.bubbleMineText)
        }
        .buttonStyle(.plain)
    }
}
