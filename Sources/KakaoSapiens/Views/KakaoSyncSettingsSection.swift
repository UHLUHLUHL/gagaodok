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

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header

            if let model = host.model {
                SyncSettingsBody(
                    model: model,
                    host: host.environmentHost,
                    pairing: host.pairingModel,
                    pairingConnection: host.pairingConnection
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
    private(set) var pairingConnection: SyncConnectionConfiguration?
    private(set) var environmentHost = ""

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
        // Reading stored status is the only thing that happens without a press.
        await built.refresh()

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

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            statusRow
            if let phrase = model.recoveryPhrase { phraseCard(phrase) }
            buttons
            if model.disconnectConfirmationVisible { disconnectCard }
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
            if model.actions.canRequestDisconnect {
                Button("연결 해제") { model.requestDisconnect() }
                    .font(.custom("Pretendard-Medium", size: 11))
                    .buttonStyle(.plain)
                    .foregroundColor(KakaoTheme.textSecondary)
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

    private var disconnectCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("연결을 해제하시겠습니까?")
                .font(.custom("Pretendard-Medium", size: 12))
            Text("이 버전에서는 확인만 제공하며 저장된 키나 원격 자료를 지우지 않습니다. 실제 해제는 다음 단계에서 별도로 구현합니다.")
                .font(.custom("Pretendard-Regular", size: 11))
                .foregroundColor(KakaoTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("닫기") { model.dismissDisconnect() }
                .font(.custom("Pretendard-Medium", size: 11))
                .buttonStyle(.plain)
                .foregroundColor(KakaoTheme.textSecondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KakaoTheme.sunken, in: RoundedRectangle(cornerRadius: 9))
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
