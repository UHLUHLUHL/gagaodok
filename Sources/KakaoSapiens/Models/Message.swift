import Foundation
import AppKit
import UniformTypeIdentifiers

public enum MessageSender: String, Codable {
    case user
    case sapiens
}

/// 이 말풍선이 인물이 입 밖으로 낸 말인지, 상황 묘사인지입니다.
///
/// 상황극에서 묘사를 대사와 같은 말풍선에 넣으면 인물이 자기 행동을 소리 내어
/// 읊는 꼴이 됩니다. 카카오톡에는 이미 가운데 정렬된 안내문 자리가 있으므로
/// 묘사는 그 자리를 씁니다. 새 시각 언어를 만들지 않아도 "말이 아닌 것"으로 읽힙니다.
public enum MessageKind: String, Codable {
    case speech
    case narration
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

        guard isImage else {
            return ChatAttachment(
                type: .file,
                fileName: url.lastPathComponent,
                fileSize: Int64(data.count),
                fileExtension: ext,
                dataBase64: data.base64EncodedString(),
                mimeType: mime
            )
        }

        // 사진은 타일 격자에 맞춰 줄여 담습니다. 줄일 것이 없으면 원본 그대로입니다.
        let shrunk = ImageBudget.shrink(data)
        let payload = shrunk?.data ?? data
        let name = shrunk == nil
            ? url.lastPathComponent
            : url.deletingPathExtension().lastPathComponent + "." + shrunk!.fileExtension
        return ChatAttachment(
            type: .image,
            fileName: name,
            fileSize: Int64(payload.count),
            fileExtension: shrunk?.fileExtension ?? ext,
            dataBase64: payload.base64EncodedString(),
            mimeType: shrunk?.mimeType ?? mime
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
        // 붙여넣는 것은 대개 화면 캡처입니다. 레티나 맥에서는 그대로 두면 3천 토큰이
        // 넘고, 그 값을 그 사진이 대화창에 있는 내내 매 턴 다시 냅니다.
        let shrunk = ImageBudget.shrink(data)
        let payload = shrunk?.data ?? data
        let ext = shrunk?.fileExtension ?? (contentType.preferredFilenameExtension ?? "png")
        return ChatAttachment(
            type: .image,
            fileName: "붙여넣은 이미지.\(ext)",
            fileSize: Int64(payload.count),
            fileExtension: ext,
            dataBase64: payload.base64EncodedString(),
            mimeType: shrunk?.mimeType ?? (contentType.preferredMIMEType ?? "image/png")
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
    // 답변을 받지 못한 내 메시지에만 씁니다. 기본값이 있어 기존 JSON도 그대로 읽힙니다.
    public var deliveryFailed: Bool
    // 상황극에서만 갈립니다. 기존 JSON에는 없으므로 없으면 대사로 읽습니다.
    public var kind: MessageKind

    public init(
        id: UUID = UUID(),
        sender: MessageSender,
        text: String,
        timestamp: Date = Date(),
        attachment: ChatAttachment? = nil,
        isUnread: Bool = false,
        turnId: UUID? = nil,
        canonicalText: String? = nil,
        deliveryFailed: Bool = false,
        kind: MessageKind = .speech
    ) {
        self.id = id
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
        self.attachment = attachment
        self.isUnread = isUnread
        self.turnId = turnId
        self.canonicalText = canonicalText
        self.deliveryFailed = deliveryFailed
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sender = try c.decode(MessageSender.self, forKey: .sender)
        text = try c.decode(String.self, forKey: .text)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        attachment = try c.decodeIfPresent(ChatAttachment.self, forKey: .attachment)
        isUnread = try c.decodeIfPresent(Bool.self, forKey: .isUnread) ?? false
        turnId = try c.decodeIfPresent(UUID.self, forKey: .turnId)
        canonicalText = try c.decodeIfPresent(String.self, forKey: .canonicalText)
        deliveryFailed = try c.decodeIfPresent(Bool.self, forKey: .deliveryFailed) ?? false
        kind = try c.decodeIfPresent(MessageKind.self, forKey: .kind) ?? .speech
    }
    
    /// 말풍선마다 매 프레임 불립니다.
    ///
    /// 예전에는 부를 때마다 `DateFormatter`를 새로 만들고 로케일까지 다시
    /// 붙였습니다. 만드는 값이 비싸기로 유명한 물건인데 화면에 보이는 말풍선 수만큼
    /// 프레임마다 만들고 있었습니다. 실기기 sample에서 이 속성이 상위에 잡혔습니다.
    ///
    /// 하나를 만들어 돌려 씁니다. 형식과 로케일이 고정이라 상태가 바뀌지 않고,
    /// `string(from:)`은 포매터를 바꾸지 않으므로 여러 곳에서 읽어도 됩니다.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "a h:mm"
        return formatter
    }()

    public var formattedTime: String { Self.timeFormatter.string(from: timestamp) }
    
    /// 이 말풍선을 웹뷰로 그려야 하는가.
    ///
    /// **스트리밍 중에 말풍선마다 매 프레임 불립니다.** 예전에는 여기서
    /// `text.contains(_:)`를 열한 번 불렀는데, 그것이 로케일을 보는 유니코드
    /// 검색이라 `"$"` 하나 찾는 데도 대소문자 접기까지 돌았습니다. 실기기 sample에서
    /// 메인 스레드 앱 심볼 1위가 이 속성이었고, 그 아래가 전부 문자열 검색이었습니다.
    ///
    /// 지금은 UTF-8 바이트를 **한 번만** 훑습니다. 찾는 표시가 전부 ASCII라
    /// 결과는 예전과 같습니다 — ASCII에는 정규화로 갈라지는 표현이 없습니다.
    public var containsLaTeXOrMarkdown: Bool {
        Self.hasInlineMarkup(text) || Self.hasBlockMarkdown(text)
    }

    /// `$ * | > # \` 같은 한 줄 안의 표시를 한 번의 순회로 찾습니다.
    ///
    /// 예전 판정과 짝이 맞습니다. `**`는 `*` 하나로 이미 걸리므로 따로 보지 않습니다.
    static func hasInlineMarkup(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "$"), UInt8(ascii: "*"), UInt8(ascii: "|"):
                return true
            case UInt8(ascii: ">"):
                // 인용은 "> " 입니다. 부등호로 쓴 ">" 는 아닙니다.
                if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: " ") { return true }
            case UInt8(ascii: "#"):
                if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "#") { return true }
            case UInt8(ascii: "`"):
                if index + 2 < bytes.count,
                   bytes[index + 1] == UInt8(ascii: "`"), bytes[index + 2] == UInt8(ascii: "`") { return true }
            case UInt8(ascii: "\\"):
                if index + 1 < bytes.count {
                    let next = bytes[index + 1]
                    if next == UInt8(ascii: "(") || next == UInt8(ascii: "[") { return true }
                    if matches(bytes, at: index + 1, "frac") || matches(bytes, at: index + 1, "sqrt") { return true }
                }
            default:
                break
            }
            index += 1
        }
        return false
    }

    private static func matches(_ bytes: [UInt8], at start: Int, _ word: String) -> Bool {
        let needle = Array(word.utf8)
        guard start + needle.count <= bytes.count else { return false }
        for offset in 0..<needle.count where bytes[start + offset] != needle[offset] { return false }
        return true
    }

    // 수평선(---)이나 제목·목록처럼 줄 단위로만 의미를 갖는 문법은 위 검사에 걸리지 않습니다.
    // 그래서 "---" 한 줄짜리 말풍선이 웹뷰 대신 일반 Text로 그려져 원문 그대로 보였습니다.
    /// 줄 단위로만 의미를 갖는 문법(수평선, 제목·목록 접두사)을 찾습니다.
    ///
    /// 판정은 예전과 같고 할당만 없앴습니다. 예전에는 줄마다 `trimmingCharacters`로
    /// 새 문자열을, `Set(trimmed)`로 새 집합을 만들었습니다. 평문 말풍선마다 매
    /// 프레임 그렇게 했습니다. 지금은 자리만 옮겨 가며 셉니다.
    static func hasBlockMarkdown(_ text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var start = line.startIndex
            var end = line.endIndex
            while start < end, isTrimmable(line[start]) { start = line.index(after: start) }
            while start < end, isTrimmable(line[line.index(before: end)]) { end = line.index(before: end) }
            let trimmed = line[start..<end]
            if trimmed.isEmpty { continue }

            // 수평선: 세 글자 이상이 전부 같은 '-' 또는 '_'
            let first = trimmed[trimmed.startIndex]
            if first == "-" || first == "_" {
                var count = 0
                var uniform = true
                for character in trimmed {
                    if character != first { uniform = false; break }
                    count += 1
                }
                if uniform && count >= 3 { return true }
            }

            if trimmed.hasPrefix("# ") || trimmed.hasPrefix("- ") { return true }
        }
        return false
    }

    /// `CharacterSet.whitespaces`와 같은 판정입니다. 줄바꿈은 이미 갈라낸 뒤라 없습니다.
    private static func isTrimmable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
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
