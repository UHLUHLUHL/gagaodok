import SwiftUI
import AppKit

public struct ChatHeaderView: View {
    let botName: String
    let customAvatar: NSImage?
    var onAvatarTapped: (() -> Void)? = nil
    @Binding var opacity: Double
    var onToggleSidebar: (() -> Void)?
    var onSearchTapped: (() -> Void)?
    var onCallTapped: (() -> Void)?
    var onVideoTapped: (() -> Void)?
    var onMenuTapped: (() -> Void)?
    /// 이 방이 쓰는 모델입니다. 모델은 방마다 따로 기억합니다.
    var activeModel: AIModel = .gemini37Flash
    var onModelSelected: ((AIModel) -> Void)? = nil
    
    public init(
        botName: String = "사피엔스",
        customAvatar: NSImage? = nil,
        onAvatarTapped: (() -> Void)? = nil,
        opacity: Binding<Double>,
        onToggleSidebar: (() -> Void)? = nil,
        onSearchTapped: (() -> Void)? = nil,
        onCallTapped: (() -> Void)? = nil,
        onVideoTapped: (() -> Void)? = nil,
        onMenuTapped: (() -> Void)? = nil,
        activeModel: AIModel = .gemini37Flash,
        onModelSelected: ((AIModel) -> Void)? = nil
    ) {
        self.activeModel = activeModel
        self.onModelSelected = onModelSelected
        self.botName = botName
        self.customAvatar = customAvatar
        self.onAvatarTapped = onAvatarTapped
        self._opacity = opacity
        self.onToggleSidebar = onToggleSidebar
        self.onSearchTapped = onSearchTapped
        self.onCallTapped = onCallTapped
        self.onVideoTapped = onVideoTapped
        self.onMenuTapped = onMenuTapped
    }
    
    public var body: some View {
        ZStack(alignment: .top) {
            // 창 이동용 영역입니다. 슬라이더가 있는 위쪽 띠에는 아예 깔지 않습니다.
            //
            // hitTest로 걸러 보고, mouseDown 위치를 검사해 보고, 슬라이더를 NSView로 바꿔
            // 봐도 창이 함께 끌려왔습니다. 겹쳐 두고 우선순위로 다투는 한 계속 새는 셈이라,
            // 아예 겹치지 않게 만듭니다. 이러면 다툴 일 자체가 없습니다.
            VStack(spacing: 0) {
                Color.clear.frame(height: 32)
                WindowDragArea()
            }
            
            VStack(spacing: 0) {
                // 1. 최상단 신호등 버튼 높이 라인 & 우상단 미니 슬라이더
                HStack(alignment: .center) {
                    Spacer()
                    
                    // 밝기 슬라이더는 타이틀바 액세서리로 올라가 있습니다.
                    // 이 자리는 신호등과 같은 높이를 확보하기 위한 빈 줄입니다.
                }
                .frame(height: 14)
                .padding(.top, 13)
                
                // 2. 프로필 및 액션 아이콘 라인 (오리지널 카카오톡 Y: 34px 완벽 매칭)
                HStack(alignment: .center, spacing: 10) {
                    // 좌측 스퀘어클 아바타 (42x42)
                    RoomAvatarView(image: customAvatar, size: 46)
                        .contentShape(Rectangle())
                        .onTapGesture { (onAvatarTapped ?? onCallTapped)?() }
                    
                    // 이름 및 인원수
                    VStack(alignment: .leading, spacing: 2) {
                        Text(botName)
                            .font(.custom("Pretendard-Bold", size: 15.5))
                            .foregroundColor(KakaoTheme.onChatHeader)
                            .onTapGesture {
                                onCallTapped?()
                            }
                        
                        HStack(spacing: 5) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 9))
                                .foregroundColor(KakaoTheme.onChatHeaderDim)
                            
                            Text("2")
                                .font(.custom("Pretendard-Regular", size: 11))
                                .foregroundColor(KakaoTheme.onChatHeaderDim)

                            Circle()
                                .fill(KakaoTheme.onChatHeaderDim.opacity(0.4))
                                .frame(width: 2.5, height: 2.5)

                            Menu {
                                ForEach(AIModel.allCases) { model in
                                    Button {
                                        onModelSelected?(model)
                                    } label: {
                                        if activeModel == model {
                                            Label(model.displayName, systemImage: "checkmark")
                                        } else {
                                            Text(model.displayName)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Circle()
                                        .fill(activeModel == .gemini37Flash
                                              ? Color(red: 0.26, green: 0.53, blue: 0.95)
                                              : Color(red: 0.39, green: 0.26, blue: 0.76))
                                        .frame(width: 5, height: 5)
                                    Text(activeModel.shortName)
                                        .font(.custom("Pretendard-Medium", size: 10.5))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 7, weight: .semibold))
                                }
                                .foregroundColor(KakaoTheme.onChatHeaderDim)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }
                    
                    Spacer()
                    
                    // 우측 아이콘 버튼 그룹 (돋보기, 전화기, 비디오, 햄버거 메뉴)
                    // 이 넷은 SF Symbols가 원본과 거의 같습니다. 직접 그려 봤더니
                    // 특히 수화기가 훨씬 조잡해져서, 모양이 정말 다른 것만 직접 그립니다.
                    HStack(spacing: 15) {
                        HeaderIconButton(systemName: "magnifyingglass", size: 15.5) { onSearchTapped?() }
                        HeaderIconButton(systemName: "phone", size: 15.5) { onCallTapped?() }
                        HeaderIconButton(systemName: "video", size: 15.5) { onVideoTapped?() }
                        HeaderIconButton(systemName: "line.3.horizontal", size: 16.5) { onMenuTapped?() }
                    }
                    .padding(.trailing, 1)
                }
                .padding(.horizontal, 14)
                .padding(.top, 7)
                .padding(.bottom, 8)
            }
        }
        .frame(height: 88)
        .background(KakaoTheme.chatHeader) // 카카오톡 상단 배경색 #BACEE0
    }
}

// MARK: - 포커스 링 없는 깔끔한 헤더 아이콘 버튼
private struct HeaderIconButton: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .foregroundColor(KakaoTheme.onChatHeader)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

// MARK: - Header Window Drag Area
/// 헤더를 잡고 창을 옮깁니다.
///
/// `excludedFromRight`만큼의 오른쪽 띠는 비워 둡니다. 그 자리에 투명도 슬라이더가 있는데,
/// 이 뷰가 헤더 전체를 덮고 있으면 슬라이더를 끌 때 AppKit이 창 이동을 먼저 잡아
/// 슬라이더는 안 움직이고 창만 따라옵니다.
public struct WindowDragArea: NSViewRepresentable {
    var excludedFromRight: CGFloat

    public init(excludedFromRight: CGFloat = 0) {
        self.excludedFromRight = excludedFromRight
    }

    public func makeNSView(context: Context) -> NSView {
        let view = CustomDragNSView()
        view.excludedFromRight = excludedFromRight
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CustomDragNSView)?.excludedFromRight = excludedFromRight
    }
}

class CustomDragNSView: NSView {
    var excludedFromRight: CGFloat = 0

    /// 비워 둔 띠 안쪽은 아예 이 뷰가 받지 않습니다. 그러면 그 위에 있는
    /// SwiftUI 컨트롤이 마우스를 정상적으로 가져갑니다.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard excludedFromRight > 0 else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        if local.x > bounds.maxX - excludedFromRight { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        // hitTest만으로는 막히지 않는 경우가 있어 받는 시점에서 한 번 더 확인합니다.
        // 여기서 막지 않으면 슬라이더를 끌 때 창까지 같이 끌려옵니다.
        let local = convert(event.locationInWindow, from: nil)
        if excludedFromRight > 0, local.x > bounds.maxX - excludedFromRight {
            super.mouseDown(with: event)
            return
        }
        window?.performDrag(with: event)
    }
}
