import SwiftUI
import AppKit

public struct KakaoMainWindowView: View {
    @ObservedObject var roomManager = ChatRoomManager.shared
    @ObservedObject var tokenManager = TokenUsageManager.shared
    
    @State private var selectedNavTab: Int = 1 // 0: 친구, 1: 채팅, 2: 더보기
    @State private var activeHeaderTab: String = "채팅" // "채팅" or "오픈채팅"
    @State private var selectedFilter: String = "전체"
    @State private var searchText: String = ""
    @State private var isSettingsPresented: Bool = false
    
    let filters = ["전체", "안읽음", "ChatGPT", "지인", "학교/모임"]
    
    public init() {}
    
    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                // 창 크기가 달라져도 카카오톡 특유의 좌측 레일 비율을 유지합니다.
                VStack(spacing: 22) {
                    // 신호등 아래 안전 마진
                    Spacer().frame(height: 30)
                    
                    // 친구 탭
                    TabIconButton(systemName: "person.fill", size: 19, isSelected: selectedNavTab == 0)
                        .onTapGesture { selectedNavTab = 0 }
                    
                    // 채팅 탭 (빨간 알림 뱃지)
                    ZStack(alignment: .topTrailing) {
                        TabIconButton(systemName: "bubble.left.fill", size: 19, isSelected: selectedNavTab == 1)
                            .onTapGesture { selectedNavTab = 1 }
                        
                        if roomManager.rooms.count > 0 {
                            Text("\(roomManager.rooms.count)")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color(red: 0.94, green: 0.32, blue: 0.25)))
                                .offset(x: 8, y: -4)
                        }
                    }
                    
                    // 더보기 탭 (오렌지 알림 점)
                    ZStack(alignment: .topTrailing) {
                        TabIconButton(systemName: "ellipsis", size: 18, isSelected: selectedNavTab == 2)
                            .onTapGesture { selectedNavTab = 2 }
                        
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 5, height: 5)
                            .offset(x: 6, y: -2)
                    }
                    
                    Spacer()
                    
                    // 하단 알림 & 설정 아이콘
                    TabIconButton(systemName: "bell", size: 17, isSelected: false)
                    
                    Button(action: {
                        isSettingsPresented = true
                    }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17))
                            .foregroundColor(isSettingsPresented ? Color(red: 0.15, green: 0.15, blue: 0.15) : Color.black.opacity(0.38))
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("설정 및 실시간 API 사용량")
                    .padding(.bottom, 16)
                }
                .frame(width: 76)
                .background(Color(red: 0.955, green: 0.955, blue: 0.955))
                .overlay(
                    Rectangle().fill(Color.black.opacity(0.08)).frame(width: 0.5), alignment: .trailing
                )
                
                // 2. 우측 채팅방 목록 본체 (스크린샷 4 1:1 완벽 재현)
                VStack(spacing: 0) {
                    // 상단 타이틀 & 툴바 ("• 채팅 ▾", "오픈채팅", 돋보기, 새 대화방 추가)
                    HStack(alignment: .center, spacing: 14) {
                        // "• 채팅 ▾"
                        Button(action: {
                            activeHeaderTab = "채팅"
                        }) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color(red: 0.96, green: 0.30, blue: 0.25))
                                    .frame(width: 5, height: 5)
                                
                                Text("채팅")
                                    .font(.custom("Pretendard-Bold", size: 17))
                                    .foregroundColor(activeHeaderTab == "채팅" ? .black : Color.black.opacity(0.45))
                                
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Color.black.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        
                        // "오픈채팅"
                        Button(action: {
                            activeHeaderTab = "오픈채팅"
                        }) {
                            Text("오픈채팅")
                                .font(.custom(activeHeaderTab == "오픈채팅" ? "Pretendard-Bold" : "Pretendard-Medium", size: 16))
                                .foregroundColor(activeHeaderTab == "오픈채팅" ? .black : Color.black.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        
                        Spacer()
                        
                        // 돋보기 검색
                        Button(action: {}) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 15, weight: .regular))
                                .foregroundColor(Color.black.opacity(0.75))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        
                        // 새 채팅방 만들기
                        Button(action: {
                            let newName = "새로운 챗봇 \(roomManager.rooms.count + 1)"
                            let newRoom = roomManager.createNewRoom(name: newName, status: "수학 파트너")
                            WindowManager.shared.openChatRoom(roomId: newRoom.id)
                        }) {
                            Image(systemName: "bubble.right")
                                .font(.system(size: 15.5, weight: .regular))
                                .foregroundColor(Color.black.opacity(0.75))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .help("새로운 챗봇 생성 및 대화창 열기")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                    
                    // 상단 필터 칩 바
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            // "전체"
                            FilterChipButton(
                                title: "전체",
                                isSelected: selectedFilter == "전체",
                                action: { selectedFilter = "전체" }
                            )
                            
                            // "💬 안읽음 3" (파란 말풍선 + 뱃지)
                            Button(action: { selectedFilter = "안읽음" }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "bubble.left.fill")
                                        .font(.system(size: 9.5))
                                        .foregroundColor(Color(red: 0.22, green: 0.53, blue: 0.94))
                                    
                                    Text("안읽음")
                                        .font(.custom("Pretendard-Regular", size: 11.5))
                                        .foregroundColor(Color.black.opacity(0.8))
                                    
                                    Text("\(roomManager.rooms.count)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 4.5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color(red: 0.94, green: 0.32, blue: 0.25)))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4.5)
                                .background(
                                    Capsule().fill(selectedFilter == "안읽음" ? Color.black.opacity(0.12) : Color.black.opacity(0.04))
                                )
                                .overlay(
                                    Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            
                            // "ChatGPT"
                            FilterChipButton(
                                title: "ChatGPT",
                                isSelected: selectedFilter == "ChatGPT",
                                action: { selectedFilter = "ChatGPT" }
                            )
                            
                            // "지인"
                            FilterChipButton(
                                title: "지인",
                                isSelected: selectedFilter == "지인",
                                action: { selectedFilter = "지인" }
                            )
                            
                            // "학교/모임 >"
                            FilterChipButton(
                                title: "학교/모임 >",
                                isSelected: selectedFilter == "학교/모임",
                                action: { selectedFilter = "학교/모임" }
                            )
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 9)
                    }
                    
                    Divider()
                    
                    // 채팅방 목록
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(roomManager.rooms) { room in
                                KakaoChatRoomRow(
                                    room: room,
                                    avatarImage: roomManager.loadAvatarForRoom(profile: room.profile),
                                    onOpen: {
                                        WindowManager.shared.openChatRoom(roomId: room.id)
                                    },
                                    onDelete: {
                                        roomManager.deleteRoom(id: room.id)
                                    }
                                )
                                
                                Divider()
                                    .padding(.leading, 68)
                            }
                        }
                    }
                    .background(Color.white)
                }
                .background(Color.white)
            }
            
            // 100% 카카오톡 macOS 네이티브 스타일 설정 모달
            if isSettingsPresented {
                KakaoUsageSettingsView(onClose: {
                    isSettingsPresented = false
                })
                .transition(.opacity)
            }
        }
        .frame(minWidth: 350, idealWidth: 420, minHeight: 480, idealHeight: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all)
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

// MARK: - 필터 칩 캡슐 버튼
private struct FilterChipButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.custom(isSelected ? "Pretendard-Bold" : "Pretendard-Regular", size: 11.5))
                .foregroundColor(isSelected ? .white : Color.black.opacity(0.8))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isSelected ? Color(red: 0.16, green: 0.16, blue: 0.16) : Color.black.opacity(0.04))
                )
                .overlay(
                    Capsule().stroke(isSelected ? Color.clear : Color.black.opacity(0.08), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

// MARK: - 탭 아이콘 버튼
private struct TabIconButton: View {
    let systemName: String
    let size: CGFloat
    let isSelected: Bool
    
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size))
            .foregroundColor(isSelected ? Color(red: 0.15, green: 0.15, blue: 0.15) : Color.black.opacity(0.38))
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
    }
}

// MARK: - 카카오톡 채팅방 Row
private struct KakaoChatRoomRow: View {
    let room: ChatRoom
    let avatarImage: NSImage?
    let onOpen: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        HStack(spacing: 12) {
            // 스퀘어클 아바타 (44x44)
            RoomAvatarView(image: avatarImage, size: 44)
            
            VStack(alignment: .leading, spacing: 3.5) {
                HStack {
                    Text(room.title)
                        .font(.custom("Pretendard-Bold", size: 14))
                        .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.1))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(formattedTime(room.lastMessageTime))
                        .font(.custom("Pretendard-Regular", size: 10.5))
                        .foregroundColor(Color.black.opacity(0.4))
                }
                
                HStack {
                    Text(cleanSnippet(room.lastMessageText))
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
