import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct SingleChatRoomView: View {
    let roomId: UUID
    @ObservedObject var roomManager = ChatRoomManager.shared
    @ObservedObject var modelManager = ModelSelectionManager.shared
    
    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var selectedAttachment: ChatAttachment? = nil
    @State private var isTyping: Bool = false
    @State private var windowOpacity: Double = 1.0
    @State private var activeImageModal: ChatAttachment? = nil
    @State private var isProfileModalPresented: Bool = false
    @State private var editingMessage: ChatMessage? = nil
    // 뒤늦게 확정되는 말풍선 높이를 언제까지 따라갈지 정하는 기준 시각입니다.
    @State private var lastScrollAnchorAt = Date.distantPast
    @State private var isFileDropTargeted: Bool = false
    
    public init(roomId: UUID) {
        self.roomId = roomId
        let loaded = ChatRoomManager.shared.loadMessagesForRoom(roomId: roomId)
        // 인삿말 없이 사용자가 먼저 시작
        _messages = State(wrappedValue: loaded)
    }
    
    private var room: ChatRoom {
        roomManager.getRoom(id: roomId) ?? ChatRoom(id: roomId)
    }
    
    private var currentAvatar: NSImage? {
        roomManager.loadAvatarForRoom(profile: room.profile)
    }
    
    /// 본문에서 떼어냈습니다. 한 덩어리로 두면 타입 검사가 시간 안에 끝나지 않습니다.
    private var messageList: some View {
        LazyVStack(spacing: 0) {
            if !messages.isEmpty {
                // 카카오톡 상단 날짜 구분선
                KakaoDateDividerView(date: messages.first?.timestamp ?? Date())
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }

            ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                MessageBubbleView(
                    message: msg,
                    isFirstInGroup: isFirstMessageInGroup(at: index),
                    isLastInGroup: isLastMessageInGroup(at: index),
                    botName: room.profile.name,
                    customAvatar: currentAvatar,
                    isEditingThisMessage: editingMessage?.id == msg.id,
                    onImageTapped: { activeImageModal = $0 },
                    onEditMessage: { startEditingMessage($0) },
                    onDeleteMessage: { deleteMessage($0) },
                    onAvatarTapped: { isProfileModalPresented = true }
                )
                .id(msg.id)
            }

            if isTyping {
                TypingIndicatorView(botName: room.profile.name, customAvatar: currentAvatar)
                    .id("typingIndicator")
                    .transition(.opacity)
            }

            Spacer()
                .frame(height: 8)
                .id("bottomSpacer")
        }
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // 카카오톡 시그니처 파스텔 연하늘색 단일 배경 (#BACEE0)
            Color(red: 0.729, green: 0.808, blue: 0.878)
                .ignoresSafeArea(.all)
            
            VStack(spacing: 0) {
                // 상단 헤더
                ChatHeaderView(
                    botName: room.profile.name,
                    customAvatar: currentAvatar,
                    onAvatarTapped: { isProfileModalPresented = true },
                    opacity: $windowOpacity,
                    onToggleSidebar: {
                        WindowManager.shared.openMainWindow()
                    },
                    onSearchTapped: nil,
                    onCallTapped: {
                        isProfileModalPresented = true
                    },
                    onMenuTapped: {
                        isProfileModalPresented = true
                    }
                )
                
                // 메시지 스크롤뷰
                ScrollViewReader { proxy in
                    ScrollView {
                        messageList
                    }
                    .onChange(of: messages.count) {
                        lastScrollAnchorAt = Date()
                        scrollToBottom(proxy: proxy)
                        roomManager.saveMessagesForRoom(roomId: roomId, messages: messages)
                    }
                    .onChange(of: isTyping) {
                        lastScrollAnchorAt = Date()
                        scrollToBottom(proxy: proxy)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .bubbleHeightSettled)) { _ in
                        // 수식 말풍선은 KaTeX가 그려진 뒤에야 높이가 확정되어 뒤늦게 커집니다.
                        // 새 메시지 직후 잠깐 동안만 따라 내려가고, 그 뒤에는 사용자가
                        // 옛 대화를 훑어보는 중일 수 있으므로 화면을 건드리지 않습니다.
                        guard Date().timeIntervalSince(lastScrollAnchorAt) < 6 else { return }
                        scrollToBottom(proxy: proxy, animated: false)
                    }
                    .onAppear {
                        lastScrollAnchorAt = Date()
                        scrollToBottom(proxy: proxy, animated: false)
                    }
                }
                
                // 메시지 수정 중 알림 바
                if editingMessage != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color.black.opacity(0.6))
                        
                        Text("메시지 수정 중...")
                            .font(.custom("Pretendard-Medium", size: 12))
                            .foregroundColor(Color.black.opacity(0.7))
                        
                        Spacer()
                        
                        Button(action: {
                            editingMessage = nil
                            inputText = ""
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(Color.black.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.98, green: 0.94, blue: 0.75))
                    .overlay(Divider(), alignment: .bottom)
                }
                
                // 하단 입력창
                ChatInputView(
                    text: $inputText,
                    selectedAttachment: $selectedAttachment,
                    onSend: handleSendOrEdit
                )
            }
            .opacity(windowOpacity)
            
            // 이미지 확대 모달
            if let attachment = activeImageModal {
                ImageViewerModal(attachment: attachment) {
                    activeImageModal = nil
                }
                .transition(.opacity)
            }
            
            // 프로필 편집 모달
            if isProfileModalPresented {
                RoomProfileModal(roomId: roomId) {
                    isProfileModalPresented = false
                }
                .transition(.opacity)
            }

            if isFileDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                    .overlay(
                        VStack(spacing: 9) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.system(size: 28, weight: .medium))
                            Text("여기에 놓아 첨부")
                                .font(.custom("Pretendard-Bold", size: 14))
                        }
                        .foregroundColor(.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    )
                    .padding(12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .frame(minWidth: 330, minHeight: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all)
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.image.identifier],
            isTargeted: $isFileDropTargeted,
            perform: handleDroppedItems
        )
    }

    private func handleDroppedItems(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = object as? URL,
                      let attachment = ChatAttachment.fromURL(url) else { return }
                DispatchQueue.main.async {
                    selectedAttachment = attachment
                }
            }
            return true
        }

        guard let imageType = provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .first(where: { $0.conforms(to: .image) }) else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: imageType.identifier) { data, _ in
            guard let data, !data.isEmpty else { return }
            let ext = imageType.preferredFilenameExtension ?? "png"
            let attachment = ChatAttachment(
                type: .image,
                fileName: "드롭한 이미지.\(ext)",
                fileSize: Int64(data.count),
                fileExtension: ext,
                dataBase64: data.base64EncodedString(),
                mimeType: imageType.preferredMIMEType ?? "image/png"
            )
            DispatchQueue.main.async {
                selectedAttachment = attachment
            }
        }
        return true
    }
    
    // MARK: - 메시지 수정 모드 진입
    private func startEditingMessage(_ message: ChatMessage) {
        editingMessage = message
        inputText = message.text
    }
    
    // MARK: - 메시지 삭제
    private func deleteMessage(_ message: ChatMessage) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            // 분할된 AI 말풍선 하나를 지우면 같은 응답 턴 전체를 화면과 API 문맥에서 제거합니다.
            if let turnId = message.turnId {
                messages.removeAll(where: { $0.turnId == turnId })
            } else {
                messages.removeAll(where: { $0.id == message.id })
            }
            roomManager.saveMessagesForRoom(roomId: roomId, messages: messages)
        }
    }
    
    // MARK: - 그룹핑 판별
    private func isFirstMessageInGroup(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let current = messages[index]
        let previous = messages[index - 1]
        if current.sender != previous.sender { return true }
        return abs(current.timestamp.timeIntervalSince(previous.timestamp)) > 60
    }
    
    private func isLastMessageInGroup(at index: Int) -> Bool {
        guard index < messages.count - 1 else { return true }
        let current = messages[index]
        let next = messages[index + 1]
        if current.sender != next.sender { return true }
        return abs(next.timestamp.timeIntervalSince(current.timestamp)) > 60
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // 마지막 말풍선이 아니라 맨 끝 여백을 기준으로 내려야 바닥까지 완전히 닿습니다.
            // 말풍선을 기준으로 잡으면 그 아래 여백만큼 덜 내려간 상태로 멈춥니다.
            let target: () -> Void = {
                if isTyping {
                    proxy.scrollTo("typingIndicator", anchor: .bottom)
                } else {
                    proxy.scrollTo("bottomSpacer", anchor: .bottom)
                }
            }
            if animated {
                withAnimation(.easeOut(duration: 0.25)) { target() }
            } else {
                // 높이가 뒤늦게 확정될 때마다 애니메이션을 걸면 화면이 계속 출렁입니다.
                target()
            }
        }
    }
    
    // MARK: - 메시지 전송 또는 수정 재전송
    private func handleSendOrEdit() {
        // 한 방에서 응답 순서가 뒤섞이지 않도록 현재 응답이 끝난 뒤 다음 요청을 받습니다.
        guard !isTyping else { return }
        if let editTarget = editingMessage {
            let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return }
            
            guard let editIdx = messages.firstIndex(where: { $0.id == editTarget.id }) else {
                editingMessage = nil
                return
            }
            
            var truncated = Array(messages.prefix(through: editIdx))
            truncated[editIdx] = ChatMessage(
                id: editTarget.id,
                sender: .user,
                text: trimmedText,
                timestamp: Date(),
                attachment: selectedAttachment ?? editTarget.attachment,
                turnId: editTarget.turnId ?? UUID(),
                canonicalText: trimmedText
            )
            
            self.messages = truncated
            self.editingMessage = nil
            self.inputText = ""
            self.selectedAttachment = nil
            self.isTyping = true
            
            roomManager.saveMessagesForRoom(roomId: roomId, messages: messages)
            
            triggerAIResponse(history: truncated)
        } else {
            let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty || selectedAttachment != nil else { return }
            
            let userMessage = ChatMessage(
                sender: .user,
                text: trimmedText,
                timestamp: Date(),
                attachment: selectedAttachment,
                turnId: UUID(),
                canonicalText: trimmedText
            )
            
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                messages.append(userMessage)
            }
            
            inputText = ""
            selectedAttachment = nil
            isTyping = true
            
            triggerAIResponse(history: messages)
        }
    }
    
    private func triggerAIResponse(history: [ChatMessage]) {
        let currentBotName = room.profile.name
        let currentRoomId = roomId
        let currentModel = modelManager.selectedModel
        let currentPersona = room.profile.persona
        let conversation = ConversationTurn.from(messages: history)

        Task {
            do {
                let response = try await GeminiService.shared.generateResponse(
                    conversation: conversation,
                    botName: currentBotName,
                    roomId: currentRoomId,
                    model: currentModel,
                    persona: currentPersona
                )
                
                await MainActor.run {
                    self.isTyping = false
                }
                
                let responseTurnId = UUID()
                for (idx, bubble) in response.bubbles.enumerated() {
                    if idx > 0 {
                        try? await Task.sleep(nanoseconds: 450_000_000)
                    }
                    
                    await MainActor.run {
                        let sapiensMsg = ChatMessage(
                            sender: .sapiens,
                            text: bubble.text,
                            timestamp: Date(),
                            attachment: bubble.attachment,
                            turnId: responseTurnId,
                            canonicalText: idx == 0 ? response.rawText : nil
                        )
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            self.messages.append(sapiensMsg)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.isTyping = false
                    let errorMsg = ChatMessage(
                        sender: .sapiens,
                        text: "요청을 처리하는 중 오류가 발생했습니다: \(error.localizedDescription)",
                        timestamp: Date(),
                        turnId: UUID(),
                        canonicalText: "요청을 처리하는 중 오류가 발생했습니다: \(error.localizedDescription)"
                    )
                    withAnimation {
                        self.messages.append(errorMsg)
                    }
                }
            }
        }
    }
}

// MARK: - 개별 채팅방 프로필 모달
public struct RoomProfileModal: View {
    let roomId: UUID
    let onClose: () -> Void
    @ObservedObject var roomManager = ChatRoomManager.shared

    @State private var isPersonaEditorPresented: Bool = false
    @State private var isProfileEditorPresented: Bool = false

    public init(roomId: UUID, onClose: @escaping () -> Void) {
        self.roomId = roomId
        self.onClose = onClose
    }

    private var room: ChatRoom {
        roomManager.getRoom(id: roomId) ?? ChatRoom(id: roomId)
    }

    private var currentAvatar: NSImage? {
        roomManager.loadAvatarForRoom(profile: room.profile)
    }

    /// 프로필 사진을 흐려 배경으로 깝니다. 사진이 없으면 회색 그라디언트로 떨어집니다.
    /// 블러가 너무 세면 색만 번져 보이므로 적당히 두고 어두운 막을 덮어 글자를 살립니다.
    private var cardBackground: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.42, green: 0.44, blue: 0.47),
                         Color(red: 0.26, green: 0.28, blue: 0.31)],
                startPoint: .top, endPoint: .bottom
            )
            if let avatar = currentAvatar {
                Image(nsImage: avatar)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 22)
                    .opacity(0.45)
            }
            LinearGradient(
                colors: [Color.black.opacity(0.22), Color.black.opacity(0.52)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    private func toolbarCircle(_ systemName: String, action: (() -> Void)? = nil) -> some View {
        Button(action: { action?() }) {
            Circle()
                .fill(Color.black.opacity(0.28))
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    /// 카카오톡처럼 아래쪽에 알약 하나로 묶습니다.
    /// 항목이 3개라 좁은 창에서는 글자가 잘리므로 폭에 맞춰 균등 분배합니다.
    private var actionBar: some View {
        HStack(spacing: 0) {
            actionItem("bubble.left.fill", "대화하기", highlighted: false) { onClose() }
            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 15)
            actionItem("pencil", "프로필", highlighted: false) { isProfileEditorPresented = true }
            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 15)
            actionItem("theatermasks.fill", "말투", highlighted: room.profile.persona.isEnabled) {
                isPersonaEditorPresented = true
            }
        }
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.18)))
    }

    private func actionItem(_ systemName: String, _ title: String, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName).font(.system(size: 10.5))
                Text(title).font(.custom("Pretendard-Medium", size: 12))
            }
            .foregroundColor(highlighted ? Color(red: 0.996, green: 0.898, blue: 0.0) : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    public var body: some View {
        GeometryReader { geo in
            // 창이 좁아도 내용이 잘리지 않도록 남는 폭 안에서만 자랍니다.
            let cardWidth = min(max(geo.size.width - 40, 260), 320)
            let cardHeight = min(max(geo.size.height - 90, 380), 470)

            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Spacer()
                        toolbarCircle("xmark") { onClose() }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)

                    Spacer(minLength: 10)

                    RoomAvatarView(image: currentAvatar, size: 84)
                        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
                        .padding(.bottom, 11)

                    Text(room.profile.name)
                        .font(.custom("Pretendard-Bold", size: 18))
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                        .lineLimit(1)

                    if !room.profile.statusMessage.isEmpty {
                        Text(room.profile.statusMessage)
                            .font(.custom("Pretendard-Regular", size: 11.5))
                            .foregroundColor(.white.opacity(0.88))
                            .shadow(radius: 1)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 20)
                            .padding(.top, 3)
                    }

                    Spacer(minLength: 14)

                    actionBar
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
                .frame(width: cardWidth, height: cardHeight)
                .background(cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 22, x: 0, y: 10)

                if isPersonaEditorPresented {
                    PersonaEditorView(roomId: roomId) { isPersonaEditorPresented = false }
                        .transition(.opacity)
                }

                if isProfileEditorPresented {
                    ProfileEditSheet(
                        title: "프로필 편집",
                        name: room.profile.name,
                        statusMessage: room.profile.statusMessage,
                        image: currentAvatar,
                        onCancel: { isProfileEditorPresented = false },
                        onConfirm: { result in
                            roomManager.updateRoomProfile(roomId: roomId, name: result.name, statusMessage: result.statusMessage)
                            if result.didChangeImage {
                                roomManager.updateRoomAvatar(roomId: roomId, image: result.image)
                            }
                            isProfileEditorPresented = false
                        }
                    )
                    .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .environment(\.colorScheme, .light)
    }

}
