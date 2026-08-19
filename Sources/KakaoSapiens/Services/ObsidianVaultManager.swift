import SwiftUI
import AppKit

public struct ObsidianAttachmentItem {
    public let turn: Int
    public let messageID: UUID
    public let attachment: ChatAttachment

    public init(turn: Int, messageID: UUID, attachment: ChatAttachment) {
        self.turn = turn
        self.messageID = messageID
        self.attachment = attachment
    }
}

@MainActor
public final class ObsidianVaultManager: ObservableObject {
    public static let shared = ObsidianVaultManager()

    @Published public private(set) var targetFolderURL: URL?
    @Published public private(set) var statusMessage = "연결 확인 전"

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let writer: ObsidianNoteWriter
    private static let pathKey = "obsidianExportFolderPath"
    public static let defaultFolderName = "가가오독"

    public init(fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.writer = ObsidianNoteWriter(fileManager: fileManager)

        if let saved = defaults.string(forKey: Self.pathKey) {
            let url = URL(fileURLWithPath: saved, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                targetFolderURL = url
            }
        }
        if targetFolderURL == nil { targetFolderURL = Self.discover(fileManager: fileManager) }
        statusMessage = connectionMessage()
    }

    public var displayPath: String {
        targetFolderURL?.path ?? "연결된 폴더 없음"
    }

    public var isConnected: Bool {
        guard let folder = targetFolderURL else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.isWritableFile(atPath: folder.path)
    }

    public func refreshDiscovery() {
        if let discovered = Self.discover(fileManager: fileManager) {
            setTargetFolder(discovered)
        } else {
            statusMessage = "열린 Obsidian Vault에서 ‘가가오독’ 폴더를 찾지 못했습니다."
        }
    }

    public func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Obsidian 문제 저장 폴더 선택"
        panel.message = "Vault 안의 ‘가가오독’ 폴더를 선택하세요."
        panel.prompt = "선택"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let targetFolderURL { panel.directoryURL = targetFolderURL }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setTargetFolder(url)
    }

    public func verifyConnection() {
        statusMessage = connectionMessage()
    }

    public func attachmentPaths(for items: [ObsidianAttachmentItem]) -> [String] {
        guard let folder = targetFolderURL else { return [] }
        return items.map { item in
            let fileName = attachmentFileName(item)
            return "\(folder.lastPathComponent)/attachments/\(fileName)"
        }
    }

    public func save(
        markdown: String,
        title: String,
        episodeID: String,
        attachments: [ObsidianAttachmentItem],
        overwriteExisting: Bool
    ) throws -> ObsidianNoteWriter.WriteResult {
        guard let folder = targetFolderURL, isConnected else {
            throw ObsidianNoteWriter.WriterError.targetUnavailable
        }
        if let existing = try writer.existingNoteURL(episodeID: episodeID, in: folder), !overwriteExisting {
            return .duplicate(existing.standardizedFileURL)
        }

        try writeAttachments(attachments, targetFolder: folder)
        return try writer.write(
            markdown: markdown,
            title: title,
            episodeID: episodeID,
            targetFolder: folder,
            overwriteExisting: overwriteExisting
        )
    }

    public func openInObsidian(_ noteURL: URL) -> Bool {
        guard let uri = ObsidianVaultLocator.openURI(for: noteURL) else { return false }
        return NSWorkspace.shared.open(uri)
    }

    private static func discover(fileManager: FileManager) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let configuration = support.appendingPathComponent("obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: configuration) else { return nil }
        return ObsidianVaultLocator.preferredExportFolder(
            configurationData: data,
            folderName: defaultFolderName,
            fileManager: fileManager
        )
    }

    private func setTargetFolder(_ url: URL) {
        let normalized = url.standardizedFileURL
        targetFolderURL = normalized
        defaults.set(normalized.path, forKey: Self.pathKey)
        statusMessage = connectionMessage()
    }

    private func connectionMessage() -> String {
        guard let folder = targetFolderURL else { return "저장 폴더를 선택해주세요." }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "저장 폴더가 없거나 Google Drive가 오프라인입니다."
        }
        guard fileManager.isWritableFile(atPath: folder.path) else { return "저장 폴더가 읽기 전용입니다." }
        return "연결됨 · 문제 노트를 저장할 수 있습니다."
    }

    private func writeAttachments(_ items: [ObsidianAttachmentItem], targetFolder: URL) throws {
        guard !items.isEmpty else { return }
        let folder = targetFolder.appendingPathComponent("attachments", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for item in items {
            guard let data = Data(base64Encoded: item.attachment.dataBase64) else { continue }
            let url = folder.appendingPathComponent(attachmentFileName(item))
            if fileManager.fileExists(atPath: url.path) { continue }
            try data.write(to: url, options: .atomic)
        }
    }

    private func attachmentFileName(_ item: ObsidianAttachmentItem) -> String {
        let originalBase = URL(fileURLWithPath: item.attachment.fileName)
            .deletingPathExtension().lastPathComponent
        let base = ObsidianNoteWriter.sanitizedFilename(originalBase)
        let ext = item.attachment.fileExtension.isEmpty ? "bin" : item.attachment.fileExtension.lowercased()
        return "\(item.turn)-\(item.messageID.uuidString.prefix(8))-\(base).\(ext)"
    }
}
