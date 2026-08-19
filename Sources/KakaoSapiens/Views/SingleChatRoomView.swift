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
    @StateObject private var selection = BubbleSelectionModel()
    // 뒤늦게 확정되는 말풍선 높이를 언제까지 따라갈지 정하는 기준 시각입니다.
    @State private var lastScrollAnchorAt = Date.distantPast
    @State private var isFileDropTargeted: Bool = false
    @State private var isSearching = false
    @State private var searchQuery = ""
    @State private var searchHitIndex = 0
    /// 답변을 받는 중인 작업입니다. 취소를 누르면 이걸 끊습니다.
    @State private var responseTask: Task<Void, Never>?

    /// 검색어를 담은 메시지들입니다. 최근 것이 1번이 되도록 뒤에서부터 셉니다.
    ///
    /// 계산 프로퍼티로 두면 말풍선 한 줄마다 전체 대화를 다시 훑어 O(n²)이 됩니다.
    /// 검색어가 바뀔 때 한 번만 계산해 담아 둡니다.
    @State private var searchHits: [UUID] = []

    private func recomputeSearchHits() {
        let needle = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            searchHits = []
            return
        }
        searchHits = messages.reversed()
            .filter { $0.text.range(of: needle, options: .caseInsensitive) != nil }
            .map(\.id)
    }

    private var currentSearchHit: UUID? {
        guard !searchHits.isEmpty, searchHitIndex < searchHits.count else { return nil }
        return searchHits[searchHitIndex]
    }
    
    public init(roomId: UUID) {
        self.roomId = roomId
        let loaded = ChatRoomManager.shared.loadMessagesForRoom(roomId: roomId)
        // 인삿말 없이 사용자가 먼저 시작
        _messages = State(wrappedValue: loaded)
    }
    
    private var room: ChatRoom {
        roomManager.getRoom(id: roomId) ?? ChatRoom(id: roomId)
    }
    
    /// 이 방이 쓰는 모델입니다. 고른 적이 없으면 전역 기본값을 따릅니다.
    private var activeModel: AIModel {
        room.resolvedModel(default: modelManager.selectedModel)
    }

    /// 이 방이 수학 멘토인지 챗봇인지입니다. 고른 적이 없으면 지금까지의 동작인 멘토입니다.
    private var activeMode: ChatMode { room.resolvedMode }

    private var currentAvatar: NSImage? {
        roomManager.loadAvatarForRoom(profile: room.profile)
    }
    
    /// 말풍선 위치를 재는 좌표계 이름입니다.
    static let chatSpace = "chatSelectionSpace"

    /// 드래그로 고른 말풍선의 본문을 화면에 보이는 순서대로 잇습니다.
    private var selectedTranscript: String {
        messages
            .filter { selection.isSelected($0.id) && !$0.text.isEmpty }
            .map(\.text)
            .joined(separator: "\n")
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
                    isSelected: selection.isSelected(msg.id),
                    isRichContentActive: BubbleViewportRenderingPolicy.shouldRenderRichContent(
                        isInstantiated: true,
                        isInsidePreloadRegion: true
                    ),
                    searchQuery: isSearching ? searchQuery : "",
                    isCurrentSearchHit: currentSearchHit == msg.id,
                    onImageTapped: { activeImageModal = $0 },
                    onEditMessage: { startEditingMessage($0) },
                    onDeleteMessage: { deleteMessage($0) },
                    allowsObsidianExport: activeMode == .mathMentor,
                    onExportToObsidian: { message in
                        ObsidianExportWindowManager.shared.present(
                            messages: messages,
                            endingAt: message,
                            selectedMessageIDs: selection.selected,
                            roomID: roomId,
                            roomName: room.profile.name,
                            model: activeModel
                        )
                    },
                    onAvatarTapped: { isProfileModalPresented = true },
                    onResendMessage: { resendMessage($0) }
                )
                .id(msg.id)
                .reportsBubbleFrame(id: msg.id, in: Self.chatSpace)
            }

            if isTyping {
                TypingIndicatorView(
                    botName: room.profile.name,
                    customAvatar: currentAvatar,
                    onCancel: { cancelResponse() }
                )
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
            KakaoTheme.chatBackground
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
                    onSearchTapped: {
                        withAnimation(.easeOut(duration: 0.16)) { isSearching.toggle() }
                        if !isSearching { searchQuery = "" }
                    },
                    onCallTapped: {
                        isProfileModalPresented = true
                    },
                    onMenuTapped: {
                        isProfileModalPresented = true
                    },
                    onBatchObsidianExport: {
                        presentBatchObsidianExport(criterion: "내가 헷갈리거나 틀렸거나 어려워했던 문제들 모두")
                    },
                    activeModel: activeModel,
                    onModelSelected: { roomManager.updateRoomModel(roomId: roomId, model: $0) },
                    activeMode: activeMode,
                    onModeSelected: { roomManager.updateRoomMode(roomId: roomId, mode: $0) }
                )

                if isSearching {
                    ChatSearchBar(
                        query: $searchQuery,
                        hitCount: searchHits.count,
                        currentIndex: searchHitIndex,
                        onPrevious: { moveSearch(by: 1) },   // 위 = 더 오래된 쪽
                        onNext: { moveSearch(by: -1) },
                        onClose: {
                            withAnimation(.easeOut(duration: 0.16)) { isSearching = false }
                            searchQuery = ""
                        }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                // 메시지 스크롤뷰
                ScrollViewReader { proxy in
                    GeometryReader { _ in
                        ScrollView {
                            messageList
                                .onPreferenceChange(BubbleFramePreferenceKey.self) { frames in
                                    selection.updateFrames(frames)
                                }
                        }
                        .coordinateSpace(name: Self.chatSpace)
                        // macOS에서는 스크롤이 휠·트랙패드로 일어나므로 드래그를 가져와도 안 부딪힙니다.
                        .gesture(
                            DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.chatSpace))
                                .onChanged { value in
                                    if selection.marquee == nil {
                                        selection.beginDrag(at: value.startLocation)
                                    }
                                    selection.extendDrag(to: value.location)
                                }
                                .onEnded { _ in selection.endDrag() }
                        )
                        // 그냥 한 번 누르면 선택을 놓습니다. 위 DragGesture가 클릭을 삼켜서
                        // onTapGesture로는 오지 않으므로 나란히 도는 제스처로 답니다.
                        // 놓을 방법이 없으면 고른 채로 남아 ⌘C를 계속 가로챕니다.
                        .simultaneousGesture(TapGesture().onEnded { selection.clear() })
                        // 복사할 글은 선택이 바뀌는 순간 미리 만들어 둡니다.
                        .onChange(of: selection.selected) {
                            selection.copyText = selectedTranscript
                        }
                        .onChange(of: messages.count) {
                            lastScrollAnchorAt = Date()
                            scrollToBottom(proxy: proxy)
                            roomManager.saveMessagesForRoom(roomId: roomId, messages: messages)
                        }
                    // 검색어를 고치면 가장 최근 결과부터 다시 봅니다.
                    .onChange(of: searchQuery) {
                        recomputeSearchHits()
                        searchHitIndex = 0
                        scrollToSearchHit(proxy: proxy)
                    }
                    .onChange(of: searchHitIndex) {
                        scrollToSearchHit(proxy: proxy)
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
                        selection.startMonitoringCopy()
                    }
                        .onDisappear {
                            // 창을 닫으면 고른 것도 같이 놓습니다. 창이 여럿일 때
                            // 안 보이는 창의 선택이 ⌘C를 가로채지 않도록요.
                            selection.clear()
                            selection.stopMonitoringCopy()
                        }
                    }
                }
                
                // 메시지 수정 중 알림 바
                if editingMessage != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(KakaoTheme.textSecondary)
                        
                        Text("메시지 수정 중...")
                            .font(.custom("Pretendard-Medium", size: 12))
                            .foregroundColor(KakaoTheme.textPrimary)
                        
                        Spacer()
                        
                        Button(action: {
                            editingMessage = nil
                            inputText = ""
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(KakaoTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.98, green: 0.94, blue: 0.75))
                    .overlay(HairlineDivider(), alignment: .bottom)
                }
                
                // 하단 입력창
                ChatInputView(
                    text: $inputText,
                    selectedAttachment: $selectedAttachment,
                    onSend: handleSendOrEdit
                )
            }
            
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

            // 멘토 모드의 명시적 Obsidian 명령은 대화 메시지/API 컨텍스트에 넣지 않습니다.
            // 일반 답변으로 보내면 내보내기는 실행되지 않고 대화만 불필요하게 늘어납니다.
            if activeMode == .mathMentor {
                switch ObsidianCommandIntent.classify(trimmedText) {
                case .batch:
                    let attachment = selectedAttachment
                    inputText = ""; selectedAttachment = nil
                    presentBatchObsidianExport(criterion: trimmedText, commandAttachment: attachment)
                    return
                case .single:
                    if let endpoint = messages.last(where: { $0.sender == .sapiens }) {
                        inputText = ""; selectedAttachment = nil
                        ObsidianExportWindowManager.shared.present(
                            messages: messages, endingAt: endpoint, selectedMessageIDs: [],
                            roomID: roomId, roomName: room.profile.name, model: activeModel
                        )
                        return
                    }
                case .none: break
                }
            }
            
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

    private func presentBatchObsidianExport(criterion: String, commandAttachment: ChatAttachment? = nil) {
        ObsidianBatchExportWindowManager.shared.present(
            messages: messages, roomID: roomId, roomName: room.profile.name,
            model: activeModel, criterion: criterion, commandAttachment: commandAttachment
        )
    }
    
    /// 실패해도 사용자에게 알리기 전에 조용히 다시 시도하는 횟수입니다.
    /// 네트워크가 잠깐 끊기거나 서버가 일시적으로 막는 경우가 대부분이라,
    /// 그때마다 실패를 보여주면 멀쩡한 대화가 지저분해집니다.
    private static let silentRetryCount = 2
    private static let retryBackoff: [UInt64] = [800_000_000, 2_000_000_000]

    private func triggerAIResponse(history: [ChatMessage]) {
        let currentBotName = room.profile.name
        let currentRoomId = roomId
        let currentModel = activeModel
        let currentMode = activeMode
        let currentPersona = room.profile.persona
        // 지난 턴이 상황극이었으면 이번 턴의 첫 문단부터 묘사를 갈라낼 수 있습니다.
        let wasRoleplaying = RoleplayParser.roleplayInProgress(messages: history)
        let conversation = ConversationTurn.from(messages: history)
        // 실패로 남길 대상은 방금 보낸 내 메시지입니다.
        let failingMessageId = history.last(where: { $0.sender == .user })?.id

        responseTask = Task {
            let responseTurnId = UUID()
            // 첫 말풍선이 붙는 순간 타이핑 표시를 끕니다. 예전에는 답변 전체를 받은 뒤였습니다.
            var attempt = 0
            while true {
                do {
                    let rawText = try await GeminiService.shared.streamResponse(
                        conversation: conversation,
                        botName: currentBotName,
                        roomId: currentRoomId,
                        model: currentModel,
                        persona: currentPersona,
                        mode: currentMode,
                        roleplayInProgress: wasRoleplaying
                    ) { bubble in
                        await MainActor.run {
                            self.isTyping = false
                            let sapiensMsg = ChatMessage(
                                sender: .sapiens,
                                text: bubble.text,
                                timestamp: Date(),
                                attachment: bubble.attachment,
                                turnId: responseTurnId,
                                canonicalText: nil,
                                kind: bubble.kind
                            )
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                self.messages.append(sapiensMsg)
                            }
                        }
                    }

                    // 원문은 스트림이 끝나야 확정됩니다. 메시지 수정과 재생성이 이 값을 쓰므로
                    // 그 턴의 첫 말풍선에 뒤늦게 붙여 둡니다.
                    await MainActor.run {
                        self.isTyping = false
                        guard let idx = self.messages.firstIndex(where: { $0.turnId == responseTurnId }) else { return }
                        self.messages[idx].canonicalText = rawText
                    }
                    return
                } catch is CancellationError {
                    await MainActor.run { self.isTyping = false }
                    return
                } catch {
                    // 사용자가 멈춘 것은 실패가 아닙니다. 표시를 남기지 않습니다.
                    if Task.isCancelled {
                        await MainActor.run { self.isTyping = false }
                        return
                    }
                    // 말풍선이 이미 하나라도 붙었으면 다시 보낼 수 없습니다.
                    // 처음부터 다시 받으면 앞부분이 두 번 나옵니다.
                    let alreadyShown = await MainActor.run {
                        self.messages.contains { $0.turnId == responseTurnId }
                    }
                    // **다시 보내도 소용없는 실패는 다시 보내지 않습니다.**
                    // 키가 틀렸거나(401) 요청이 잘못됐거나(400) 안전 필터에 걸린 요청은
                    // 몇 번을 보내도 똑같이 실패합니다. 그 두 번은 화면에 아무것도
                    // 남기지 않으면서 요금만 세 배로 냈습니다.
                    // 전송 계층이 만든 오류가 아니면(주로 네트워크) 지금까지처럼 다시 시도합니다.
                    if !alreadyShown, AIServiceError.isRetryable(error), attempt < Self.silentRetryCount {
                        try? await Task.sleep(nanoseconds: Self.retryBackoff[attempt])
                        attempt += 1
                        continue
                    }
                    await MainActor.run {
                        self.isTyping = false
                        // 답변자 쪽에 오류 말풍선을 남기지 않습니다.
                        // 카카오톡처럼 내 말풍선에 표시를 달아 재전송하거나 지울 수 있게 합니다.
                        guard let failingMessageId,
                              let idx = self.messages.firstIndex(where: { $0.id == failingMessageId }) else { return }
                        withAnimation { self.messages[idx].deliveryFailed = true }
                    }
                    return
                }
            }
        }
    }

    private func scrollToSearchHit(proxy: ScrollViewProxy) {
        guard let hit = currentSearchHit else { return }
        // 찾은 말풍선을 가운데로 올려 앞뒤 맥락이 함께 보이게 합니다.
        withAnimation(.easeInOut(duration: 0.22)) {
            proxy.scrollTo(hit, anchor: .center)
        }
    }

    /// 답변 받기를 멈춥니다. 그때까지 붙은 말풍선은 그대로 둡니다.
    private func cancelResponse() {
        responseTask?.cancel()
        responseTask = nil
        isTyping = false
    }

    /// 검색 결과 사이를 옮겨 다닙니다. 양 끝에서는 반대편으로 돌아갑니다.
    private func moveSearch(by step: Int) {
        let count = searchHits.count
        guard count > 0 else { return }
        searchHitIndex = ((searchHitIndex + step) % count + count) % count
    }

    /// 실패 표시가 붙은 내 메시지를 다시 보냅니다.
    private func resendMessage(_ message: ChatMessage) {
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[idx].deliveryFailed = false
        isTyping = true
        // 그 메시지까지의 이력으로 다시 요청합니다. 뒤에 다른 대화가 있어도 순서를 지킵니다.
        triggerAIResponse(history: Array(messages.prefix(through: idx)))
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
                KakaoTheme.textSecondary
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
        
    }

}
