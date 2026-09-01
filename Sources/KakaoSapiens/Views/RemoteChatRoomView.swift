import SwiftUI

/// A display-only window over the dedicated remote projection repository.
/// Reply, edit and delete are intentionally absent until continuation semantics
/// are opened in the next gate.
public struct RemoteChatRoomView: View {
    public let snapshot: SyncRemoteRoomSnapshot
    public let onClose: () -> Void
    @AppStorage("sync.remote.behaviorNoticeSeen") private var noticeSeen = false

    public init(snapshot: SyncRemoteRoomSnapshot, onClose: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.title).font(.custom("Pretendard-Bold", size: 16))
                        Text("\(originLabel)에서 시작 · 수동 확인 필요")
                            .font(.system(size: 10)).foregroundColor(KakaoTheme.textSecondary)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                HairlineDivider()

                if !noticeSeen {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundColor(.orange)
                        Text("다른 기기에서 시작한 방입니다. 답장을 열면 이 기기의 설정으로 응답하게 됩니다. 현재 검증 단계에서는 읽기만 가능합니다.")
                            .font(.system(size: 11)).foregroundColor(KakaoTheme.textSecondary)
                        Spacer()
                        Button("확인") { noticeSeen = true }.buttonStyle(.plain)
                    }
                    .padding(12).background(KakaoTheme.sunken)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(snapshot.messages, id: \.messageID) { message in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(message.sender)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(KakaoTheme.textSecondary)
                                Text(message.text)
                                    .font(.custom("Pretendard-Regular", size: 13))
                                    .foregroundColor(KakaoTheme.textPrimary)
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .background(Color(red: 0.74, green: 0.82, blue: 0.87))

                HStack {
                    Text("원격 방 답장은 다음 단계에서 활성화됩니다")
                        .font(.system(size: 12)).foregroundColor(KakaoTheme.textTertiary)
                    Spacer()
                    Image(systemName: "lock.fill").foregroundColor(KakaoTheme.textTertiary)
                }
                .padding(14).background(KakaoTheme.surface)
            }
            .frame(width: 360, height: 540)
            .background(KakaoTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(radius: 18)
        }
    }

    private var originLabel: String {
        switch snapshot.handle.originSpaceID {
        case "MAC_SPACE": return "Mac"
        case "TABLET_SPACE": return "태블릿"
        default: return "다른 기기"
        }
    }
}
