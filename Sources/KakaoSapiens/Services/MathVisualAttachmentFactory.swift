import Foundation

public enum MathVisualAttachmentFactory {
    public static func make(title: String, png: Data) -> ChatAttachment {
        ChatAttachment(
            type: .image,
            fileName: sanitized(title) + ".png",
            fileSize: Int64(png.count),
            fileExtension: "png",
            dataBase64: png.base64EncodedString(),
            mimeType: "image/png"
        )
    }

    private static func sanitized(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t")
        let joined = raw.components(separatedBy: forbidden)
            .joined(separator: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String((joined.isEmpty ? "수학 그래프" : joined).prefix(80))
    }
}
