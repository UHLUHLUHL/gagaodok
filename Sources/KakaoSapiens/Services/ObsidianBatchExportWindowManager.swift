import SwiftUI
import AppKit

@MainActor
public final class ObsidianBatchExportWindowManager: NSObject, NSWindowDelegate {
    public static let shared = ObsidianBatchExportWindowManager()
    private var entries: [UUID: (NSWindowController, ObsidianBatchExportCoordinator)] = [:]

    public func present(messages: [ChatMessage], roomID: UUID, roomName: String, model: AIModel,
                        criterion: String, commandAttachment: ChatAttachment? = nil) {
        if let entry = entries[roomID], let window = entry.0.window {
            entry.1.begin(messages: messages, roomID: roomID, roomName: roomName, model: model,
                          criterion: criterion, commandAttachment: commandAttachment)
            window.makeKeyAndOrderFront(nil); return
        }
        let coordinator = ObsidianBatchExportCoordinator()
        let view = ObsidianBatchExportSheet(coordinator: coordinator) { [weak self] in self?.close(roomID) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: .init(width: 900, height: 780)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Obsidian 여러 문제 정리"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.minSize = .init(width: 680, height: 620); window.contentView = NSHostingView(rootView: view); window.delegate = self; window.center()
        let controller = NSWindowController(window: window); entries[roomID] = (controller, coordinator)
        coordinator.begin(messages: messages, roomID: roomID, roomName: roomName, model: model,
                          criterion: criterion, commandAttachment: commandAttachment)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    public func close(_ roomID: UUID) { entries[roomID]?.0.window?.performClose(nil) }
    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let found = entries.first(where: { $0.value.0.window === window }) else { return }
        found.value.1.close(); entries.removeValue(forKey: found.key)
    }
}
