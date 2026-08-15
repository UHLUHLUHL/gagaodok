import SwiftUI
import AppKit

public struct KakaoMainWindowView: View {
    @ObservedObject var roomManager = ChatRoomManager.shared
    @ObservedObject var tokenManager = TokenUsageManager.shared
    @ObservedObject var myProfile = ProfileState.shared

    enum Tab { case friends, chats }

    @State private var tab: Tab = .chats
    @State private var searchText: String = ""
    // 실제 카카오톡처럼 돋보기를 눌러야 검색창이 나옵니다.
    @State private var isSearchVisible = false
    @State private var isSettingsPresented = false
    @State private var isAddingFriend = false
    @State private var editingFriend: ChatRoom?
    @State private var isEditingMyProfile = false
    @State private var profileCardRoomId: UUID?
    @State private var favoritesCollapsed = false
    @State private var friendsCollapsed = false

    // 카카오톡 팔레트
    private let ink = Color(red: 0.10, green: 0.10, blue: 0.11)
    private let subInk = Color(red: 0.53, green: 0.55, blue: 0.58)
    private let rail = Color(red: 0.965, green: 0.965, blue: 0.969)
    private let hairline = Color(red: 0.91, green: 0.92, blue: 0.93)
    private let searchFill = Color(red: 0.945, green: 0.949, blue: 0.957)

    public init() {}

    // MARK: - 검색

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private func matches(_ room: ChatRoom) -> Bool {
        let query = trimmedQuery.lowercased()
        guard !query.isEmpty else { return true }
        if room.profile.name.lowercased().contains(query)
            || room.profile.statusMessage.lowercased().contains(query) { return true }
        // 방 이름뿐 아니라 주고받은 말도 뒤집니다.
        return roomManager.firstMatch(roomId: room.id, query: query) != nil
    }

    /// 검색 중에는 마지막 대화 대신 찾은 문장을 보여줍니다. 카카오톡과 같은 방식입니다.
    private func previewText(for room: ChatRoom) -> String {
        guard !trimmedQuery.isEmpty,
              let hit = roomManager.firstMatch(roomId: room.id, query: trimmedQuery) else {
            return room.lastMessageText
        }
        return hit
    }

    private var chatRooms: [ChatRoom] { roomManager.conversationRooms.filter(matches) }
    private var favorites: [ChatRoom] { roomManager.favoriteRooms.filter(matches) }
    private var others: [ChatRoom] { roomManager.regularRooms.filter(matches) }

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sideRail
                Divider().overlay(hairline)
                VStack(spacing: 0) {
                    header
                    if isSearchVisible { searchBar }
                    Divider().overlay(hairline)
                    content
                }
                .background(Color.white)
            }

            if isSettingsPresented {
                KakaoUsageSettingsView(onClose: { isSettingsPresented = false })
                    .transition(.opacity)
            }
            if let roomId = profileCardRoomId {
                RoomProfileModal(roomId: roomId) { profileCardRoomId = nil }
                    .transition(.opacity)
            }
            if isAddingFriend { addFriendSheet }
            if let friend = editingFriend { editFriendSheet(friend) }
            if isEditingMyProfile { myProfileSheet }
        }
        .frame(minWidth: 350, idealWidth: 420, minHeight: 480, idealHeight: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all)
        .environment(\.colorScheme, .light)
    }

    // MARK: - 좌측 레일

    private var sideRail: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 54)
            // 실제 카카오톡은 선택된 탭만 채워진 아이콘이고 나머지는 외곽선입니다.
            railIcon(filled: "person.fill", outline: "person",
                     selected: tab == .friends) { tab = .friends }
            railIcon(filled: "bubble.left.fill", outline: "bubble.left",
                     selected: tab == .chats) { tab = .chats }
            Spacer()
            railIcon(filled: "gearshape.fill", outline: "gearshape",
                     selected: isSettingsPresented) { isSettingsPresented = true }
            Spacer().frame(height: 18)
        }
        // 신호등 버튼(좌측 상단 3개)이 레일 안에 들어오려면 최소 72pt가 필요합니다.
        // 실제 카카오톡도 이 정도 폭을 씁니다.
        .frame(width: 76)
        .background(rail)
    }

    private func railIcon(filled: String, outline: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: selected ? filled : outline)
                .font(.system(size: 22, weight: selected ? .regular : .light))
                .foregroundColor(selected ? ink : Color.black.opacity(0.30))
                .frame(width: 48, height: 44)
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    // MARK: - 헤더

    private var header: some View {
        HStack(spacing: 2) {
            Text(tab == .friends ? "친구" : "채팅")
                .font(.custom("Pretendard-Bold", size: 17))
                .foregroundColor(ink)
            Spacer()
            Button(action: {
                isSearchVisible.toggle()
                if isSearchVisible {
                    // 첫 타자에서 모든 방을 한꺼번에 읽느라 멈추지 않도록 미리 만들어 둡니다.
                    roomManager.primeSearchIndex()
                } else {
                    searchText = ""
                }
            }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15.5))
                    .foregroundColor(isSearchVisible ? ink : Color.black.opacity(0.72))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("검색")

            Button(action: { isAddingFriend = true }) {
                Group {
                    if tab == .friends {
                        AddFriendIcon()
                    } else {
                        ComposeChatIcon()
                    }
                }
                // 돋보기보다 살짝 크게 잡아 원본과 비슷한 무게로 보이게 합니다.
                .frame(width: 19, height: 19)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(tab == .friends ? "친구 추가" : "새 대화 상대 만들기")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundColor(subInk)
            TextField(tab == .friends ? "친구 검색" : "채팅방 이름, 대화 내용 검색", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(ink)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(subInk)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(searchFill, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 14)
        .padding(.bottom, 11)
    }

    // MARK: - 본문

    @ViewBuilder
    private var content: some View {
        ScrollView {
            // 두 목록이 같은 방을 담아 행 ID(room.id)가 겹칩니다.
            // 한 LazyVStack 안에서 분기하면 탭을 바꿔도 이전 탭의 행이 그대로 재사용되어
            // 친구 목록에 채팅 행이 그려집니다. 목록마다 별도 스택과 고유 id를 줘서 갈라놓습니다.
            if tab == .friends {
                LazyVStack(spacing: 0) { friendsList }.id("friendsList")
            } else {
                LazyVStack(spacing: 0) { chatList }.id("chatList")
            }
        }
        .background(Color.white)
    }

    @ViewBuilder
    private var friendsList: some View {
        myProfileRow
        Rectangle().fill(hairline).frame(height: 1).padding(.leading, 16)

        if !favorites.isEmpty {
            sectionHeader("즐겨찾는 친구", favorites.count, collapsed: $favoritesCollapsed)
            if !favoritesCollapsed { ForEach(favorites) { friendRow($0) } }
        }
        if !others.isEmpty {
            sectionHeader("친구", others.count, collapsed: $friendsCollapsed)
            if !friendsCollapsed { ForEach(others) { friendRow($0) } }
        }
        if favorites.isEmpty && others.isEmpty {
            emptyState(icon: "person.2",
                       title: searchText.isEmpty ? "아직 친구가 없어요" : "검색 결과가 없어요",
                       detail: searchText.isEmpty ? "오른쪽 위 + 를 눌러 대화 상대를 만들어 보세요." : nil)
        }
    }

    @ViewBuilder
    private var chatList: some View {
        if chatRooms.isEmpty {
            emptyState(icon: "bubble.left.and.bubble.right",
                       title: searchText.isEmpty ? "진행 중인 대화가 없어요" : "검색 결과가 없어요",
                       detail: searchText.isEmpty ? "친구 탭에서 상대를 골라 대화를 시작해 보세요." : nil)
        } else {
            ForEach(chatRooms) { room in
                KakaoChatRoomRow(
                    room: room,
                    avatarImage: roomManager.loadAvatarForRoom(profile: room.profile),
                    previewText: previewText(for: room),
                    onOpen: { WindowManager.shared.openChatRoom(roomId: room.id) },
                    onDelete: { roomManager.deleteRoom(id: room.id) },
                    onTogglePin: { roomManager.togglePinned(roomId: room.id) },
                    onEditProfile: { editingFriend = room }
                )
            }
        }
    }

    private func sectionHeader(_ title: String, _ count: Int, collapsed: Binding<Bool>) -> some View {
        Button(action: { collapsed.wrappedValue.toggle() }) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.custom("Pretendard-Medium", size: 12))
                    .foregroundColor(subInk)
                Text("\(count)")
                    .font(.custom("Pretendard-Medium", size: 12))
                    .foregroundColor(subInk.opacity(0.8))
                Spacer()
                Image(systemName: collapsed.wrappedValue ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(subInk.opacity(0.75))
            }
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private var myProfileRow: some View {
        Button(action: { isEditingMyProfile = true }) {
            HStack(spacing: 12) {
                RoomAvatarView(image: myProfile.customImage, size: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(myProfile.name)
                        .font(.custom("Pretendard-Bold", size: 14))
                        .foregroundColor(ink)
                    if !myProfile.statusMessage.isEmpty {
                        Text(myProfile.statusMessage)
                            .font(.custom("Pretendard-Regular", size: 11.5))
                            .foregroundColor(subInk)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(subInk.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func friendRow(_ room: ChatRoom) -> some View {
        FriendRow(
            room: room,
            avatarImage: roomManager.loadAvatarForRoom(profile: room.profile),
            onOpenCard: { profileCardRoomId = room.id },
            onStartChat: { WindowManager.shared.openChatRoom(roomId: room.id) },
            onEdit: { editingFriend = room },
            onTogglePin: { roomManager.togglePinned(roomId: room.id) },
            onDelete: { roomManager.deleteRoom(id: room.id) }
        )
    }

    private func emptyState(icon: String, title: String, detail: String?) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundColor(subInk.opacity(0.45))
            Text(title)
                .font(.custom("Pretendard-Bold", size: 13))
                .foregroundColor(subInk)
            if let detail {
                Text(detail)
                    .font(.custom("Pretendard-Regular", size: 11.5))
                    .foregroundColor(subInk.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
        .padding(.horizontal, 30)
    }

    // MARK: - 시트

    private var addFriendSheet: some View {
        ProfileEditSheet(
            title: "새 대화 상대",
            confirmLabel: "추가",
            name: "",
            statusMessage: "",
            image: nil,
            onCancel: { isAddingFriend = false },
            onConfirm: { result in
                let room = roomManager.createNewRoom(name: result.name, status: result.statusMessage)
                if result.didChangeImage {
                    roomManager.updateRoomAvatar(roomId: room.id, image: result.image)
                }
                isAddingFriend = false
                tab = .friends
            }
        )
        .transition(.opacity)
    }

    private func editFriendSheet(_ friend: ChatRoom) -> some View {
        ProfileEditSheet(
            title: "프로필 편집",
            name: friend.profile.name,
            statusMessage: friend.profile.statusMessage,
            image: roomManager.loadAvatarForRoom(profile: friend.profile),
            onCancel: { editingFriend = nil },
            onConfirm: { result in
                roomManager.updateRoomProfile(roomId: friend.id, name: result.name, statusMessage: result.statusMessage)
                if result.didChangeImage {
                    roomManager.updateRoomAvatar(roomId: friend.id, image: result.image)
                }
                editingFriend = nil
            }
        )
        .transition(.opacity)
    }

    private var myProfileSheet: some View {
        ProfileEditSheet(
            title: "프로필 편집",
            name: myProfile.name,
            statusMessage: myProfile.statusMessage,
            image: myProfile.customImage,
            onCancel: { isEditingMyProfile = false },
            onConfirm: { result in
                myProfile.updateProfile(name: result.name, statusMessage: result.statusMessage)
                if result.didChangeImage { myProfile.setProfileImage(result.image) }
                isEditingMyProfile = false
            }
        )
        .transition(.opacity)
    }
}

// MARK: - 친구 목록 한 줄

private struct FriendRow: View {
    let room: ChatRoom
    let avatarImage: NSImage?
    let onOpenCard: () -> Void
    let onStartChat: () -> Void
    let onEdit: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            RoomAvatarView(image: avatarImage, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(room.profile.name)
                        .font(.custom("Pretendard-Bold", size: 13))
                        .foregroundColor(Color(red: 0.10, green: 0.10, blue: 0.11))
                        .lineLimit(1)
                    if room.profile.persona.isEnabled {
                        Image(systemName: "theatermasks.fill")
                            .font(.system(size: 8.5))
                            .foregroundColor(Color(red: 0.86, green: 0.72, blue: 0.0))
                    }
                }
                if !room.profile.statusMessage.isEmpty {
                    Text(room.profile.statusMessage)
                        .font(.custom("Pretendard-Regular", size: 11))
                        .foregroundColor(Color.black.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer()
            if isHovered {
                Button(action: onStartChat) {
                    Text("대화")
                        .font(.custom("Pretendard-Medium", size: 11))
                        .foregroundColor(Color(red: 0.10, green: 0.10, blue: 0.11))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color(red: 0.945, green: 0.949, blue: 0.957), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovered ? Color(red: 0.965, green: 0.969, blue: 0.976) : Color.white)
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        .onTapGesture { onOpenCard() }
        .contextMenu {
            Button("대화 시작") { onStartChat() }
            Button("프로필 편집") { onEdit() }
            Button(room.isPinned ? "즐겨찾기 해제" : "즐겨찾기") { onTogglePin() }
            Divider()
            Button("삭제", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - 카카오톡 macOS 정통 네이티브 스타일 설정 모달
public struct KakaoSettingsModal: View {
    let onClose: () -> Void
    @ObservedObject var tokenManager = TokenUsageManager.shared
    @ObservedObject var roomManager = ChatRoomManager.shared
    @ObservedObject var modelManager = ModelSelectionManager.shared

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }
    
    public var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
            
            VStack(spacing: 0) {
                // 상단 타이틀 바 (카카오톡 특유의 미니멀 헤더)
                HStack {
                    Text("설정")
                        .font(.custom("Pretendard-Bold", size: 15))
                        .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.1))
                    
                    Spacer()
                    
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color.black.opacity(0.5))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
                
                Divider()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // 1. 카카오톡 머니/지갑 감성의 정갈한 총 사용량 카드
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("API 사용 금액")
                                    .font(.custom("Pretendard-Medium", size: 12.5))
                                    .foregroundColor(Color.black.opacity(0.6))
                                
                                Spacer()
                                
                                Text(modelManager.selectedModel.displayName)
                                    .font(.custom("Pretendard-Medium", size: 10.5))
                                    .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(red: 0.996, green: 0.902, blue: 0.0)) // 카카오 옐로우 뱃지
                                    .cornerRadius(4)
                            }
                            
                            HStack(alignment: .lastTextBaseline, spacing: 6) {
                                Text(String(format: "₩%.2f", tokenManager.totalCostKRW))
                                    .font(.custom("Pretendard-Bold", size: 24))
                                    .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.1))
                                
                                Text(String(format: "($%.4f)", tokenManager.totalCostUSD))
                                    .font(.custom("Pretendard-Regular", size: 12))
                                    .foregroundColor(Color.black.opacity(0.45))
                            }
                            
                            Divider()
                                .padding(.vertical, 2)
                            
                            HStack {
                                Text("누적 토큰")
                                    .font(.custom("Pretendard-Regular", size: 11.5))
                                    .foregroundColor(Color.black.opacity(0.55))
                                
                                Spacer()
                                
                                Text("\(tokenManager.totalTokens.formatted()) tokens")
                                    .font(.custom("Pretendard-Bold", size: 12))
                                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                            }
                            
                            HStack {
                                Text("입력 / 출력")
                                    .font(.custom("Pretendard-Regular", size: 11))
                                    .foregroundColor(Color.black.opacity(0.45))
                                
                                Spacer()
                                
                                Text("\(tokenManager.totalPromptTokens.formatted()) / \(tokenManager.totalCandidatesTokens.formatted())")
                                    .font(.custom("Pretendard-Regular", size: 11))
                                    .foregroundColor(Color.black.opacity(0.55))
                            }
                        }
                        .padding(14)
                        .background(Color(red: 0.965, green: 0.965, blue: 0.97))
                        .cornerRadius(10)
                        
                        // 2. 대화방별 상세 사용량
                        VStack(alignment: .leading, spacing: 8) {
                            Text("대화방별 사용 내역")
                                .font(.custom("Pretendard-Bold", size: 12.5))
                                .foregroundColor(Color.black.opacity(0.75))
                                .padding(.leading, 2)
                            
                            VStack(spacing: 0) {
                                ForEach(Array(roomManager.rooms.enumerated()), id: \.element.id) { idx, room in
                                    let usage = tokenManager.getUsage(for: room.id)
                                    HStack(spacing: 10) {
                                        RoomAvatarView(image: roomManager.loadAvatarForRoom(profile: room.profile), size: 34)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(room.title)
                                                .font(.custom("Pretendard-Bold", size: 12.5))
                                                .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.1))
                                                .lineLimit(1)
                                            
                                            Text("\(usage.totalTokens.formatted()) tokens (입력 \(usage.promptTokens.formatted()) · 출력 \(usage.candidatesTokens.formatted()))")
                                                .font(.custom("Pretendard-Regular", size: 10))
                                                .foregroundColor(Color.black.opacity(0.45))
                                        }
                                        
                                        Spacer()
                                        
                                        Text(String(format: "₩%.2f", usage.costKRW(exchangeRate: tokenManager.exchangeRate)))
                                            .font(.custom("Pretendard-Bold", size: 13))
                                            .foregroundColor(Color(red: 0.12, green: 0.12, blue: 0.12))
                                    }
                                    .padding(.vertical, 9)
                                    .padding(.horizontal, 4)
                                    
                                    if idx < roomManager.rooms.count - 1 {
                                        Divider()
                                            .padding(.leading, 44)
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .background(Color.white)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
                            )
                        }
                        
                        // 3. 단가 정보 풋터
                        VStack(alignment: .leading, spacing: 3) {
                            Text("단가 기준 (Google AI Studio 공식 요율)")
                                .font(.custom("Pretendard-Bold", size: 10.5))
                                .foregroundColor(Color.black.opacity(0.45))
                            
                            Text("• 입력: $1.50 / 1M tokens · 출력(사고 포함): $7.50 / 1M tokens")
                                .font(.custom("Pretendard-Regular", size: 10))
                                .foregroundColor(Color.black.opacity(0.45))
                            Text("• 컨텍스트 캐싱: $0.15 / 1M tokens (90% 할인)")
                                .font(.custom("Pretendard-Regular", size: 10))
                                .foregroundColor(Color.black.opacity(0.45))
                            Text("• 적용 환율: 1 USD = 1,420.00 KRW")
                                .font(.custom("Pretendard-Regular", size: 10))
                                .foregroundColor(Color.black.opacity(0.45))
                        }
                        .padding(.horizontal, 4)
                        
                        // 4. 통계 초기화 버튼
                        Button(action: {
                            tokenManager.resetAllUsage()
                        }) {
                            Text("사용량 초기화")
                                .font(.custom("Pretendard-Regular", size: 11.5))
                                .foregroundColor(Color.red.opacity(0.75))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                    }
                    .padding(14)
                }
            }
            .frame(width: 310, height: 480)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
        }
    }
}

// MARK: - 카카오톡 채팅방 Row
private struct KakaoChatRoomRow: View {
    let room: ChatRoom
    let avatarImage: NSImage?
    /// 검색 중에는 마지막 대화 대신 찾은 문장을 보여줍니다.
    var previewText: String? = nil
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void
    let onEditProfile: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        HStack(spacing: 12) {
            // 스퀘어클 아바타 (44x44)
            RoomAvatarView(image: avatarImage, size: 48)
            
            VStack(alignment: .leading, spacing: 3.5) {
                HStack(spacing: 4) {
                    Text(room.profile.name)
                        .font(.custom("Pretendard-Bold", size: 14))
                        .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.1))
                        .lineLimit(1)

                    if room.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8.5))
                            .foregroundColor(Color.black.opacity(0.35))
                    }
                    if room.profile.persona.isEnabled {
                        Image(systemName: "theatermasks.fill")
                            .font(.system(size: 8.5))
                            .foregroundColor(Color(red: 0.86, green: 0.72, blue: 0.0))
                    }

                    Spacer()
                    
                    Text(formattedTime(room.lastMessageTime))
                        .font(.custom("Pretendard-Regular", size: 10.5))
                        .foregroundColor(Color.black.opacity(0.4))
                }
                
                HStack {
                    Text(cleanSnippet(previewText ?? room.lastMessageText))
                        .font(.custom("Pretendard-Regular", size: 12))
                        .foregroundColor(Color.black.opacity(0.55))
                        .lineLimit(1)
                    
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isHovered ? Color(red: 0.94, green: 0.95, blue: 0.97) : Color.white)
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture(count: 1) { onOpen() }
        .contextMenu {
            Button("채팅방 열기") { onOpen() }
            Button("프로필 편집") { onEditProfile() }
            Button(room.isPinned ? "상단 고정 해제" : "상단 고정") { onTogglePin() }
            Divider()
            Button("채팅방 나가기 (삭제)", role: .destructive) { onDelete() }
        }
    }
    
    private func cleanSnippet(_ text: String) -> String {
        var clean = text.replacingOccurrences(of: "$", with: "")
        clean = clean.replacingOccurrences(of: "\\frac", with: "")
        clean = clean.replacingOccurrences(of: "\\pi", with: "π")
        clean = clean.replacingOccurrences(of: "\\cos", with: "cos")
        clean = clean.replacingOccurrences(of: "\\sin", with: "sin")
        clean = clean.replacingOccurrences(of: "\\tan", with: "tan")
        clean = clean.replacingOccurrences(of: "\\theta", with: "θ")
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func formattedTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "a h:mm"
            formatter.locale = Locale(identifier: "ko_KR")
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M월 d일"
            return formatter.string(from: date)
        }
    }
}
