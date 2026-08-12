import SwiftUI
import AppKit

@main
struct KakaoSapiensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        // 1. 카카오톡 메인 윈도우(채팅방 목록 & 탭바) 실행
        WindowManager.shared.openMainWindow()
        
        // 2. 첫 번째 활성 채팅방 창도 함께 띄우기
        if let firstRoom = ChatRoomManager.shared.rooms.first {
            WindowManager.shared.openChatRoom(roomId: firstRoom.id)
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // 메인 창이나 대화창 하나를 닫아도 앱 유지
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            WindowManager.shared.openMainWindow()
        }
        return true
    }
}
