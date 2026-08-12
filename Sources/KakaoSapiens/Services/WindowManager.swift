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
            contentRect: NSRect(x: 100, y: 100, width: 330, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .white
        window.minSize = NSSize(width: 300, height: 420)
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
        
        guard let room = ChatRoomManager.shared.getRoom(id: roomId) else { return }
        
        let chatView = SingleChatRoomView(roomId: roomId)
        let hostingView = NSHostingView(rootView: chatView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 150, width: 380, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = NSColor(red: 0.729, green: 0.808, blue: 0.878, alpha: 1.0)
        window.minSize = NSSize(width: 340, height: 460)
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
