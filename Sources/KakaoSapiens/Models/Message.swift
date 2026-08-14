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
    
    /// 클립보드에 있는 이미지나 파일을 첨부로 바꿉니다.
    ///
    /// 붙여넣기 경로는 두 갈래입니다. Finder에서 파일을 복사하면 파일 URL이 올라오고,
    /// 화면을 캡처하거나 브라우저에서 이미지를 복사하면 이미지 데이터가 바로 올라옵니다.
    /// 뒤쪽은 파일 이름이 없으므로 형식에 맞는 이름을 붙여 줍니다.
    public static func fromPasteboard(_ pasteboard: NSPasteboard) -> ChatAttachment? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first, url.isFileURL,
           let attachment = fromURL(url) {
            return attachment
        }

        // 압축된 형식만 그대로 받습니다. 캡처 이미지는 png와 tiff가 같이 올라오는데
        // tiff는 무압축이라 그대로 쓰면 png의 세 배 가까이 부풉니다.
        // tiff뿐인 경우는 아래에서 png로 다시 인코딩해 받습니다.
        let candidates: [(NSPasteboard.PasteboardType, UTType)] = [
            (.png, .png),
            (.init("public.jpeg"), .jpeg),
            (.init("com.compuserve.gif"), .gif)
        ]

        for (pasteboardType, contentType) in candidates {
            guard let data = pasteboard.data(forType: pasteboardType), !data.isEmpty else { continue }
            return imageAttachment(data: data, contentType: contentType)
        }

        // 위 형식이 없으면 NSImage가 읽어낼 수 있는지 마지막으로 확인하고 png로 변환합니다.
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return imageAttachment(data: png, contentType: .png)
    }

    private static func imageAttachment(data: Data, contentType: UTType) -> ChatAttachment {
        let ext = contentType.preferredFilenameExtension ?? "png"
        return ChatAttachment(
            type: .image,
            fileName: "붙여넣은 이미지.\(ext)",
            fileSize: Int64(data.count),
            fileExtension: ext,
            dataBase64: data.base64EncodedString(),
            mimeType: contentType.preferredMIMEType ?? "image/png"
        )
    }

    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
    
    public var nsImage: NSImage? { AttachmentImageCache.image(for: self) }
}

/// 첨부 이미지를 첨부 id 기준으로 캐시합니다.
///
/// 예전에는 `nsImage`가 계산 프로퍼티라 SwiftUI가 본문을 다시 그릴 때마다
/// base64를 디코드하고 `NSImage`를 새로 만들었습니다. 답변이 말풍선 단위로 붙는 동안
/// 화면 전체가 반복해서 다시 그려지므로, 스크린샷 한 장이 초당 여러 번 디코드되면서
/// 이미지가 깜빡이고 스크롤이 끊겼습니다.
public enum AttachmentImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 80
        // 원본 해상도 스크린샷이 쌓여도 메모리를 물고 있지 않도록 상한을 둡니다.
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    public static func image(for attachment: ChatAttachment) -> NSImage? {
        guard attachment.type == .image else { return nil }
        let key = attachment.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = Data(base64Encoded: attachment.dataBase64),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key, cost: data.count)
        return image
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
        let hasInlineMarkdown = text.contains("```") || text.contains("**") || text.contains("*")
            || text.contains("##") || text.contains("|") || text.contains("> ")
        return hasMath || hasInlineMarkdown || Self.hasBlockMarkdown(text)
    }

    // 수평선(---)이나 제목·목록처럼 줄 단위로만 의미를 갖는 문법은 위 검사에 걸리지 않습니다.
    // 그래서 "---" 한 줄짜리 말풍선이 웹뷰 대신 일반 Text로 그려져 원문 그대로 보였습니다.
    private static func hasBlockMarkdown(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 3 {
                let characters = Set(trimmed)
                if characters.count == 1, let mark = characters.first, mark == "-" || mark == "_" {
                    return true
                }
            }
            return trimmed.hasPrefix("# ") || trimmed.hasPrefix("- ")
        }
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
