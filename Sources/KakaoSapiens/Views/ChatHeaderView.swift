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
    @ObservedObject private var modelManager = ModelSelectionManager.shared
    
    public init(
        botName: String = "사피엔스",
        customAvatar: NSImage? = nil,
        onAvatarTapped: (() -> Void)? = nil,
        opacity: Binding<Double>,
        onToggleSidebar: (() -> Void)? = nil,
        onSearchTapped: (() -> Void)? = nil,
        onCallTapped: (() -> Void)? = nil,
        onVideoTapped: (() -> Void)? = nil,
        onMenuTapped: (() -> Void)? = nil
    ) {
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
            // 상단 헤더 영역만 마우스 드래그로 창 이동 가능
            WindowDragArea()
            
            VStack(spacing: 0) {
                // 1. 최상단 신호등 버튼 높이 라인 & 우상단 미니 슬라이더
                HStack(alignment: .center) {
                    Spacer()
                    
                    // 우상단 카카오톡 특유의 미니멀 슬림 슬라이더 (신호등과 완벽 동일한 수평선)
                    KakaoSlimSlider(value: $opacity)
                        .padding(.trailing, 14)
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
                            .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.1))
                            .onTapGesture {
                                onCallTapped?()
                            }
                        
                        HStack(spacing: 5) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 9))
                                .foregroundColor(Color.black.opacity(0.45))
                            
                            Text("2")
                                .font(.custom("Pretendard-Regular", size: 11))
                                .foregroundColor(Color.black.opacity(0.45))

                            Circle()
                                .fill(Color.black.opacity(0.18))
                                .frame(width: 2.5, height: 2.5)

                            Menu {
                                ForEach(AIModel.allCases) { model in
                                    Button {
                                        modelManager.selectedModel = model
                                    } label: {
                                        if modelManager.selectedModel == model {
                                            Label(model.displayName, systemImage: "checkmark")
                                        } else {
                                            Text(model.displayName)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Circle()
                                        .fill(modelManager.selectedModel == .gemini37Flash
                                              ? Color(red: 0.26, green: 0.53, blue: 0.95)
                                              : Color(red: 0.39, green: 0.26, blue: 0.76))
                                        .frame(width: 5, height: 5)
                                    Text(modelManager.selectedModel.shortName)
                                        .font(.custom("Pretendard-Medium", size: 10.5))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 7, weight: .semibold))
                                }
                                .foregroundColor(Color.black.opacity(0.55))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }
                    
                    Spacer()
                    
                    // 우측 아이콘 버튼 그룹 (돋보기, 전화기, 비디오, 햄버거 메뉴)
                    HStack(spacing: 15) {
                        HeaderIconButton(systemName: "magnifyingglass", size: 15) {
                            onSearchTapped?()
                        }
                        
                        HeaderIconButton(systemName: "phone", size: 15) {
                            onCallTapped?()
                        }
                        
                        HeaderIconButton(systemName: "video", size: 15) {
                            onVideoTapped?()
                        }
                        
                        HeaderIconButton(systemName: "line.3.horizontal", size: 16) {
                            onMenuTapped?()
                        }
                    }
                    .padding(.trailing, 1)
                }
                .padding(.horizontal, 14)
                .padding(.top, 7)
                .padding(.bottom, 8)
            }
        }
        .frame(height: 88)
        .background(Color(red: 0.729, green: 0.808, blue: 0.878)) // 카카오톡 상단 배경색 #BACEE0
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
                .foregroundColor(Color.black.opacity(0.75))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

// MARK: - 카카오톡 초슬림 투명도 슬라이더
public struct KakaoSlimSlider: View {
    @Binding var value: Double
    
    public init(value: Binding<Double>) {
        self._value = value
    }
    
    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.2))
                    .frame(height: 2)
                
                Capsule()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: max(0, CGFloat((value - 0.35) / (1.0 - 0.35)) * geo.size.width), height: 2)
                
                Circle()
                    .fill(Color.white)
                    .frame(width: 8.5, height: 8.5)
                    .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 0.5)
                    .offset(x: max(0, min(geo.size.width - 8.5, CGFloat((value - 0.35) / (1.0 - 0.35)) * (geo.size.width - 8.5))))
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let progress = max(0, min(1, gesture.location.x / geo.size.width))
                        value = 0.35 + (1.0 - 0.35) * Double(progress)
                    }
            )
        }
        .frame(width: 58, height: 12)
    }
}

// MARK: - Header Window Drag Area
public struct WindowDragArea: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> NSView {
        let view = CustomDragNSView()
        return view
    }
    public func updateNSView(_ nsView: NSView, context: Context) {}
}

class CustomDragNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
