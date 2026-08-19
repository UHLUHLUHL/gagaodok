import Foundation

public struct ObsidianNoteWriter {
    public enum WriteResult: Equatable {
        case written(URL)
        case duplicate(URL)
    }

    public enum WriterError: LocalizedError {
        case targetUnavailable

        public var errorDescription: String? {
            switch self {
            case .targetUnavailable: return "Obsidian 저장 폴더에 접근할 수 없습니다."
            }
        }
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func write(
        markdown: String,
        title: String,
        episodeID: String,
        targetFolder: URL,
        overwriteExisting: Bool
    ) throws -> WriteResult {
        let targetFolder = targetFolder.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: targetFolder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WriterError.targetUnavailable
        }

        if let existing = try existingNoteURL(episodeID: episodeID, in: targetFolder) {
            let existing = existing.standardizedFileURL
            guard overwriteExisting else { return .duplicate(existing) }
            try Data(markdown.utf8).write(to: existing, options: .atomic)
            return .written(existing)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let stem = "\(formatter.string(from: Date())) \(Self.sanitizedFilename(title))"
        var destination = targetFolder.appendingPathComponent(stem).appendingPathExtension("md")
        if fileManager.fileExists(atPath: destination.path) {
            let suffix = Self.sanitizedFilename(String(episodeID.prefix(8)))
            destination = targetFolder.appendingPathComponent("\(stem)-\(suffix)").appendingPathExtension("md")
        }
        try Data(markdown.utf8).write(to: destination, options: .atomic)
        return .written(destination.standardizedFileURL)
    }

    public static func sanitizedFilename(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t")
        let pieces = raw.components(separatedBy: forbidden)
        let joined = pieces.joined(separator: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let safe = joined.isEmpty ? "수학 문제" : joined
        return String(safe.prefix(80))
    }

    public func existingNoteURL(episodeID: String, in folder: URL) throws -> URL? {
        let marker = "episode_id: \"\(episodeID)\""
        let urls = try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls where url.pathExtension.lowercased() == "md" {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            let prefix = data.prefix(16 * 1024)
            if String(data: prefix, encoding: .utf8)?.contains(marker) == true { return url }
        }
        return nil
    }
}
