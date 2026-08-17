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
        // 저장된 화면 모드를 창을 만들기 전에 적용합니다. 동적 색이 이 값을 보고 갈라집니다.
        AppearanceManager.shared.apply()
        
        // 목록 창만 띄웁니다.
        //
        // 예전에는 여기서 rooms.first의 대화방 창도 같이 열었습니다. 방이 하나뿐이던
        // 시절에 만든 줄인데, 방이 여럿이 된 뒤로는 저장된 배열의 0번이 뜬금없이 열립니다.
        // 게다가 목록은 고정한 방을 위로 올려 보여주므로 화면 맨 위에 있는 방과
        // 열리는 방이 서로 다릅니다. 원본 카카오톡도 켤 때 목록만 띄웁니다.
        WindowManager.shared.openMainWindow()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // 메인 창이나 대화창 하나를 닫아도 앱 유지
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 대화 저장은 0.7초 모아서 처리하므로, 종료 직전에 남은 것을 확실히 기록합니다.
        ChatRoomManager.shared.flushPendingSaves()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            WindowManager.shared.openMainWindow()
        }
        return true
    }
}
