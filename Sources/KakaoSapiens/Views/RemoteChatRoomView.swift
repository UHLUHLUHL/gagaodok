import SwiftUI

/// A display-only window over the dedicated remote projection repository.
/// Reply, edit and delete are intentionally absent until continuation semantics
/// are opened in the next gate.
public struct RemoteChatRoomView: View {
    public let snapshot: SyncRemoteRoomSnapshot
    public let onClose: () -> Void
    @AppStorage("sync.remote.behaviorNoticeSeen") private var noticeSeen = false
    @State private var replyText = ""
    @State private var replyStatus: String?
    @State private var isPreparingReply = false

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
                        Text(snapshot.continuationCapability == .chatbot ? "다른 기기에서 시작한 개인 챗봇 방입니다. 답장은 이 기기의 Gemini 설정으로 준비됩니다." : "이 방은 이어쓰기 capability가 없어 읽기 전용입니다.")
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

                if snapshot.continuationCapability == .chatbot {
                    HStack(spacing: 8) {
                        TextField("답장", text: $replyText).textFieldStyle(.roundedBorder)
                        Button(isPreparingReply ? "준비 중" : "보내기") { prepareReply() }
                            .disabled(isPreparingReply || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(12)
                    if let replyStatus { Text(replyStatus).font(.system(size: 10)).foregroundColor(KakaoTheme.textSecondary).padding(.bottom, 8) }
                } else {
                    HStack { Text("원격 방 답장은 지원되는 개인 챗봇 방에서만 가능합니다").font(.system(size: 12)).foregroundColor(KakaoTheme.textTertiary); Spacer(); Image(systemName: "lock.fill").foregroundColor(KakaoTheme.textTertiary) }.padding(14)
                }
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

    private func prepareReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isPreparingReply = true
        Task {
            defer { isPreparingReply = false }
            do {
                guard case .available(let secrets) = SyncSecretStore.load() else { throw SyncRemoteReplyBuilderError.unsupportedRoom }
                let root = ChatRoomManager.shared.appSupportURL.appendingPathComponent("sync")
                guard case .available(let connection) = SyncConnectionStateStore(fileURL: root.appendingPathComponent("connection.json")).load() else { throw SyncRemoteReplyBuilderError.unsupportedRoom }
                let turns = snapshot.messages.sorted { $0.timestamp < $1.timestamp }.map { ConversationTurn(id: $0.turnID, sender: $0.sender == "나" ? .user : .sapiens, text: $0.text) } + [ConversationTurn(id: UUID(), sender: .user, text: text)]
                let response = try await GeminiService.shared.generateResponse(conversation: turns, roomId: nil, model: .gemini37Flash, mode: .companion).rawText
                let coordinator = SyncRemoteReplyCoordinator(builder: .init(accountID: connection.accountID, deviceID: connection.deviceID, masterKey: secrets.accountMasterKey), journal: .init(fileURL: root.appendingPathComponent("remote-replies.plist")), outbox: .init(fileURL: root.appendingPathComponent("outbox.plist")))
                _ = try coordinator.prepare(room: snapshot, writerSpaceID: "MAC_SPACE", userText: text, selectedModel: .gemini37Flash, response: response)
                replyText = ""; replyStatus = "답장을 이 기기의 동기화 대기열에 보관했습니다."
            } catch { replyStatus = "답장을 준비하지 못했습니다. 기존 원격 대화는 변경되지 않았습니다." }
        }
    }
}
