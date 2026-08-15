import SwiftUI
import AppKit

public class WindowManager: ObservableObject {
    public static let shared = WindowManager()
    
    private var openWindows: [UUID: NSWindowController] = [:]
    private var mainWindowController: NSWindowController?
    
    private init() {}
    
    // MARK: - 카카오톡 메인 윈도우 (채팅방 목록 & 탭바) 열기
    public func openMainWindow() {
        if let controller = mainWindowController, let window = controller.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let mainView = KakaoMainWindowView()
        let hostingView = NSHostingView(rootView: mainView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 420, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // 콘텐츠 영역(채팅 목록, 설정 카드 등)을 드래그해도 창이 움직이지 않게 합니다.
        // NSWindow의 실제 상단 제목 표시줄만 기본 macOS 방식으로 창 이동을 처리합니다.
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        // 창 배경도 화면 모드를 따라야 합니다. 흰색으로 굳혀 두면 반투명한
        // 구분선 뒤로 그 흰색이 비쳐 다크 모드에서 흰 줄로 남습니다.
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x1A/255, green: 0x1A/255, blue: 0x1A/255, alpha: 1)
                : .white
        }
        window.minSize = NSSize(width: 350, height: 480)
        window.contentView = hostingView
        window.center()
        
        let controller = NSWindowController(window: window)
        self.mainWindowController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - 개별 채팅방 독립 윈도우 열기 (카카오톡 오리지널 더블클릭 팝업 방식)
    public func openChatRoom(roomId: UUID) {
        if let controller = openWindows[roomId], let window = controller.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        guard ChatRoomManager.shared.getRoom(id: roomId) != nil else { return }
        
        let chatView = SingleChatRoomView(roomId: roomId)
        let hostingView = NSHostingView(rootView: chatView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 150, width: 405, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x11/255, green: 0x11/255, blue: 0x11/255, alpha: 1)
                : NSColor(srgbRed: 0.729, green: 0.808, blue: 0.878, alpha: 1)
        }
        window.minSize = NSSize(width: 350, height: 500)
        window.contentView = hostingView
        
        // 창 위치 분산
        let count = openWindows.count
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let xOffset = min(visibleFrame.maxX - 400, visibleFrame.midX + CGFloat(count * 30))
            let yOffset = max(visibleFrame.minY + 50, visibleFrame.midY - CGFloat(count * 30))
            window.setFrameOrigin(NSPoint(x: xOffset, y: yOffset))
        }
        
        let controller = NSWindowController(window: window)
        openWindows[roomId] = controller
        
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.openWindows.removeValue(forKey: roomId)
        }
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
