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
        guard url.isFileURL, !url.hasDirectoryPath else { return nil }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let contentType = UTType(filenameExtension: ext)
        let isImage = contentType?.conforms(to: .image) == true
        let mime = contentType?.preferredMIMEType ?? "application/octet-stream"
        
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
    // 같은 AI 응답에서 분리된 화면 말풍선들은 하나의 turnId를 공유합니다.
    // Optional로 두어 기존 JSON도 별도 디코더 없이 그대로 마이그레이션할 수 있습니다.
    public var turnId: UUID?
    // API에는 분리 전 원문을 한 번만 보냅니다. AI 턴의 첫 말풍선에만 저장합니다.
    public var canonicalText: String?
    
    public init(
        id: UUID = UUID(),
        sender: MessageSender,
        text: String,
        timestamp: Date = Date(),
        attachment: ChatAttachment? = nil,
        isUnread: Bool = false,
        turnId: UUID? = nil,
        canonicalText: String? = nil
    ) {
        self.id = id
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
        self.attachment = attachment
        self.isUnread = isUnread
        self.turnId = turnId
        self.canonicalText = canonicalText
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

// 화면 말풍선과 분리된 API용 논리 대화 턴입니다.
public struct ConversationTurn: Identifiable {
    public let id: UUID
    public let sender: MessageSender
    public let text: String
    public let attachment: ChatAttachment?

    public init(id: UUID, sender: MessageSender, text: String, attachment: ChatAttachment? = nil) {
        self.id = id
        self.sender = sender
        self.text = text
        self.attachment = attachment
    }

    public static func from(messages: [ChatMessage]) -> [ConversationTurn] {
        var result: [ConversationTurn] = []
        var index = 0

        while index < messages.count {
            let first = messages[index]
            let turnId = first.turnId ?? first.id

            if first.sender == .user {
                result.append(ConversationTurn(
                    id: turnId,
                    sender: .user,
                    text: first.canonicalText ?? first.text,
                    attachment: first.attachment
                ))
                index += 1
                continue
            }

            var group: [ChatMessage] = [first]
            var cursor = index + 1
            while cursor < messages.count {
                let next = messages[cursor]
                guard next.sender == .sapiens else { break }
                if let firstTurn = first.turnId, let nextTurn = next.turnId, firstTurn != nextTurn { break }
                group.append(next)
                cursor += 1
            }

            let canonical = group.compactMap(\.canonicalText).first
                ?? group.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            result.append(ConversationTurn(
                id: turnId,
                sender: .sapiens,
                text: canonical,
                attachment: group.compactMap(\.attachment).first
            ))
            index = cursor
        }
        return result
    }
}
