import SwiftUI
import AppKit

@MainActor
public final class ObsidianExportWindowManager: NSObject, NSWindowDelegate {
    public static let shared = ObsidianExportWindowManager()
    public static let defaultSize = NSSize(width: 900, height: 780)
    public static let minimumSize = NSSize(width: 680, height: 620)

    private struct Entry {
        let controller: NSWindowController
        let coordinator: ObsidianExportCoordinator
    }
    private var entries: [UUID: Entry] = [:]

    public func present(
        messages: [ChatMessage],
        endingAt message: ChatMessage,
        selectedMessageIDs: Set<UUID>,
        roomID: UUID,
        roomName: String,
        model: AIModel
    ) {
        if let entry = entries[roomID], let window = entry.controller.window {
            entry.coordinator.begin(
                messages: messages,
                endingAt: message,
                selectedMessageIDs: selectedMessageIDs,
                roomID: roomID,
                roomName: roomName,
                model: model
            )
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let coordinator = ObsidianExportCoordinator()
        let rootView = ObsidianExportSheet(coordinator: coordinator) { [weak self] in
            self?.close(roomID: roomID)
        }
        let hostingView = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("obsidian-export-\(roomID.uuidString)")
        window.title = "Obsidian 문제 정리"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = Self.minimumSize
        window.contentView = hostingView
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        entries[roomID] = Entry(controller: controller, coordinator: coordinator)
        coordinator.begin(
            messages: messages,
            endingAt: message,
            selectedMessageIDs: selectedMessageIDs,
            roomID: roomID,
            roomName: roomName,
            model: model
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close(roomID: UUID) {
        entries[roomID]?.controller.window?.performClose(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let match = entries.first(where: { $0.value.controller.window === window }) else { return }
        match.value.coordinator.close()
        entries.removeValue(forKey: match.key)
    }
}
