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
                        LazyVStack(spacing: 0) {
                            if !messages.isEmpty {
                                // 카카오톡 상단 날짜 구분선
                                KakaoDateDividerView(date: messages.first?.timestamp ?? Date())
                                    .padding(.top, 6)
                                    .padding(.bottom, 4)
                            }
                            
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                                let isFirstInGroup = isFirstMessageInGroup(at: index)
                                let isLastInGroup = isLastMessageInGroup(at: index)
                                
                                MessageBubbleView(
                                    message: msg,
                                    isFirstInGroup: isFirstInGroup,
                                    isLastInGroup: isLastInGroup,
                                    botName: room.profile.name,
                                    customAvatar: currentAvatar,
                                    isEditingThisMessage: editingMessage?.id == msg.id,
                                    onImageTapped: { attachment in
                                        activeImageModal = attachment
                                    },
                                    onEditMessage: { msgToEdit in
                                        startEditingMessage(msgToEdit)
                                    },
                                    onDeleteMessage: { msgToDelete in
                                        deleteMessage(msgToDelete)
                                    }
                                )
                                .id(msg.id)
                            }
                            
                            // 도톰한 타이핑 인디케이터 (현재 방 이름 & 아바타)
                            if isTyping {
                                TypingIndicatorView(
                                    botName: room.profile.name,
                                    customAvatar: currentAvatar
                                )
                                .id("typingIndicator")
                                .transition(.opacity)
                            }
                            
                            Spacer()
                                .frame(height: 8)
                                .id("bottomSpacer")
                        }
                    }
                    .onChange(of: messages.count) {
                        scrollToBottom(proxy: proxy)
                        roomManager.saveMessagesForRoom(roomId: roomId, messages: messages)
                    }
                    .onChange(of: isTyping) {
                        scrollToBottom(proxy: proxy)
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
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.25)) {
                if isTyping {
                    proxy.scrollTo("typingIndicator", anchor: .bottom)
                } else if let lastMsg = messages.last {
                    proxy.scrollTo(lastMsg.id, anchor: .bottom)
                }
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
        let conversation = ConversationTurn.from(messages: history)
        
        Task {
            do {
                let response = try await GeminiService.shared.generateResponse(
                    conversation: conversation,
                    botName: currentBotName,
                    roomId: currentRoomId,
                    model: currentModel
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
    
    @State private var isEditing: Bool = false
    @State private var editName: String = ""
    @State private var editStatusMessage: String = ""
    
    public init(roomId: UUID, onClose: @escaping () -> Void) {
        self.roomId = roomId
        self.onClose = onClose
        let current = ChatRoomManager.shared.getRoom(id: roomId)
        _editName = State(initialValue: current?.profile.name ?? "사피엔스")
        _editStatusMessage = State(initialValue: current?.profile.statusMessage ?? "수학 학습 파트너")
    }
    
    private var room: ChatRoom {
        roomManager.getRoom(id: roomId) ?? ChatRoom(id: roomId)
    }
    
    private var currentAvatar: NSImage? {
        roomManager.loadAvatarForRoom(profile: room.profile)
    }
    
    public var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture {
                    if !isEditing { onClose() }
                }
            
            ZStack(alignment: .top) {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.65, green: 0.65, blue: 0.63),
                        Color(red: 0.52, green: 0.52, blue: 0.50),
                        Color(red: 0.40, green: 0.40, blue: 0.38)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                
                VStack(spacing: 0) {
                    // 상단 툴바
                    HStack(spacing: 12) {
                        Spacer()
                        
                        Circle()
                            .fill(Color.black.opacity(0.25))
                            .frame(width: 26, height: 26)
                            .overlay(Image(systemName: "gift").font(.system(size: 12)).foregroundColor(.white))
                        
                        Circle()
                            .fill(Color.black.opacity(0.25))
                            .frame(width: 26, height: 26)
                            .overlay(Image(systemName: "waveform.path").font(.system(size: 12)).foregroundColor(.white))
                        
                        Button(action: onClose) {
                            Circle()
                                .fill(Color.black.opacity(0.25))
                                .frame(width: 26, height: 26)
                                .overlay(Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    
                    // BGM 바
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(colors: [.orange, .red, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 34, height: 34)
                            .overlay(Image(systemName: "music.note").foregroundColor(.white.opacity(0.8)).font(.system(size: 14)))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(room.profile.musicTitle)
                                .font(.custom("Pretendard-Medium", size: 12))
                                .foregroundColor(.white)
                            Text(room.profile.musicArtist)
                                .font(.custom("Pretendard-Regular", size: 10))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        
                        Spacer()
                        Image(systemName: "suit.heart").font(.system(size: 13)).foregroundColor(.white.opacity(0.8))
                        Image(systemName: "play").font(.system(size: 13)).foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(8)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    
                    Spacer()
                    
                    // 아바타 (스퀘어클 74x74)
                    ZStack(alignment: .bottomTrailing) {
                        RoomAvatarView(image: currentAvatar, size: 74)
                            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
                            .onTapGesture { pickImage() }
                        
                        Button(action: { pickImage() }) {
                            Circle()
                                .fill(Color(red: 0.2, green: 0.2, blue: 0.2))
                                .frame(width: 24, height: 24)
                                .overlay(Image(systemName: "camera.fill").font(.system(size: 11)).foregroundColor(.white))
                                .shadow(radius: 2)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 2, y: 2)
                    }
                    .padding(.bottom, 10)
                    
                    // 이름 및 상태메시지
                    if isEditing {
                        VStack(spacing: 8) {
                            TextField("이름 입력", text: $editName)
                                .textFieldStyle(.plain)
                                .font(.custom("Pretendard-Bold", size: 16))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(6)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(6)
                                .frame(width: 200)
                            
                            TextField("상태 메시지", text: $editStatusMessage)
                                .textFieldStyle(.plain)
                                .font(.custom("Pretendard-Regular", size: 12))
                                .foregroundColor(.white.opacity(0.9))
                                .multilineTextAlignment(.center)
                                .padding(5)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(6)
                                .frame(width: 240)
                        }
                        .padding(.bottom, 16)
                    } else {
                        VStack(spacing: 4) {
                            Text(room.profile.name)
                                .font(.custom("Pretendard-Bold", size: 19))
                                .foregroundColor(.white)
                                .shadow(radius: 2)
                            
                            Text(room.profile.statusMessage)
                                .font(.custom("Pretendard-Regular", size: 12))
                                .foregroundColor(.white.opacity(0.85))
                                .shadow(radius: 1)
                        }
                        .padding(.bottom, 20)
                    }
                    
                    // 하단 분할 바
                    HStack(spacing: 0) {
                        if isEditing {
                            Button(action: {
                                roomManager.updateRoomAvatar(roomId: roomId, image: nil)
                            }) {
                                Text("기본 사진으로")
                                    .font(.custom("Pretendard-Regular", size: 12))
                                    .foregroundColor(.white.opacity(0.9))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            
                            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 16)
                            
                            Button(action: {
                                roomManager.updateRoomProfile(roomId: roomId, name: editName, statusMessage: editStatusMessage)
                                isEditing = false
                            }) {
                                Text("저장 완료")
                                    .font(.custom("Pretendard-Bold", size: 12))
                                    .foregroundColor(Color(red: 0.996, green: 0.902, blue: 0.0))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button(action: onClose) {
                                HStack(spacing: 6) {
                                    Image(systemName: "bubble.left.fill").font(.system(size: 11))
                                    Text("대화하기").font(.custom("Pretendard-Medium", size: 12.5))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            
                            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 16)
                            
                            Button(action: {
                                editName = room.profile.name
                                editStatusMessage = room.profile.statusMessage
                                isEditing = true
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "pencil").font(.system(size: 11))
                                    Text("프로필 편집").font(.custom("Pretendard-Medium", size: 12.5))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Color.white.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .cornerRadius(14)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .frame(width: 300, height: 440)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 12)
        }
    }
    
    private func pickImage() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [.image]
        
        if openPanel.runModal() == .OK, let url = openPanel.url {
            if let image = NSImage(contentsOf: url) {
                roomManager.updateRoomAvatar(roomId: roomId, image: image)
            }
        }
    }
}
