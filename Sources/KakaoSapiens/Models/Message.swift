import Foundation
import AppKit
import UniformTypeIdentifiers

public enum MessageSender: String, Codable {
    case user
    case sapiens
}

public enum AttachmentType: String, Codable {
    case image
    case file
}

public struct ChatAttachment: Identifiable, Codable {
    public let id: UUID
    public let type: AttachmentType
    public let fileName: String
    public let fileSize: Int64
    public let fileExtension: String
    public let dataBase64: String
    public let mimeType: String
    
    public init(
        id: UUID = UUID(),
        type: AttachmentType,
        fileName: String,
        fileSize: Int64,
        fileExtension: String = "jpg",
        dataBase64: String,
        mimeType: String = "image/jpeg"
    ) {
        self.id = id
        self.type = type
        self.fileName = fileName
        self.fileSize = fileSize
        self.fileExtension = fileExtension
        self.dataBase64 = dataBase64
        self.mimeType = mimeType
    }
    
    public static func fromURL(_ url: URL) -> ChatAttachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let isImage = ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext)
        let mime = isImage ? "image/\(ext == "jpg" ? "jpeg" : ext)" : "application/octet-stream"
        
        return ChatAttachment(
            type: isImage ? .image : .file,
            fileName: url.lastPathComponent,
            fileSize: Int64(data.count),
            fileExtension: ext,
            dataBase64: data.base64EncodedString(),
            mimeType: mime
        )
    }
    
    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
    
    public var nsImage: NSImage? {
        guard type == .image, let data = Data(base64Encoded: dataBase64) else { return nil }
        return NSImage(data: data)
    }
}

public struct ChatMessage: Identifiable, Codable {
    public let id: UUID
    public let sender: MessageSender
    public var text: String
    public let timestamp: Date
    public var attachment: ChatAttachment?
    public var isUnread: Bool
    
    public init(id: UUID = UUID(), sender: MessageSender, text: String, timestamp: Date = Date(), attachment: ChatAttachment? = nil, isUnread: Bool = false) {
        self.id = id
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
        self.attachment = attachment
        self.isUnread = isUnread
    }
    
    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "a h:mm"
        return formatter.string(from: timestamp)
    }
    
    public var containsLaTeXOrMarkdown: Bool {
        let hasMath = text.contains("$") || text.contains("\\(") || text.contains("\\[") || text.contains("\\frac") || text.contains("\\sqrt")
        let hasMarkdown = text.contains("```") || text.contains("**") || text.contains("*") || text.contains("##") || text.contains("|") || text.contains("> ")
        return hasMath || hasMarkdown
    }
}
