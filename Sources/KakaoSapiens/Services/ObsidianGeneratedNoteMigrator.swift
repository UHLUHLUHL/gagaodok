import Foundation

public struct ObsidianLegacyNoteCandidate: Equatable {
    public let title: String
    public let problem: String
    public let episodeID: String
    private let suffix: String

    fileprivate init(title: String, problem: String, episodeID: String, suffix: String) {
        self.title = title
        self.problem = problem
        self.episodeID = episodeID
        self.suffix = suffix
    }

    public func renderMigratedMarkdown(problemCardPath: String) -> String {
        let metadata = ObsidianInternalMetadata(episodeID: episodeID)
        let callout = problem.components(separatedBy: "\n").map { line in
            line.isEmpty ? ">" : "> \(line)"
        }.joined(separator: "\n")
        var result = """
        ---
        tags:
          - 가가오독
          - 수학문제
        ---
        \(metadata.comment)

        # \(title)

        ## 문제

        ![[\(Self.relativeAttachmentPath(problemCardPath))]]

        > [!abstract]- 문제 원문 보기
        \(callout)
        """
        if !suffix.isEmpty {
            result += "\n\n" + suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func relativeAttachmentPath(_ raw: String) -> String {
        if let range = raw.range(of: "attachments/") { return String(raw[range.lowerBound...]) }
        return raw
    }
}

public enum ObsidianGeneratedNoteMigrator {
    public static func looksLikeLegacyGeneratedNote(_ markdown: String) -> Bool {
        ObsidianInternalMetadata.parse(from: markdown) == nil
            && markdown.contains("  - 가가오독")
            && markdown.contains("  - 수학문제")
            && firstCapture(#"(?m)^episode_id:\s*\"([^\"]+)\"\s*$"#, in: markdown) != nil
    }

    public static func inspect(markdown: String) -> ObsidianLegacyNoteCandidate? {
        guard looksLikeLegacyGeneratedNote(markdown),
              let episodeID = firstCapture(#"(?m)^episode_id:\s*\"([^\"]+)\"\s*$"#, in: markdown),
              let body = bodyAfterFrontmatter(markdown),
              let title = firstCapture(#"(?m)^#\s+(.+?)\s*$"#, in: body),
              let problemHeading = body.range(of: "## 문제") else { return nil }

        let problemStart = problemHeading.upperBound
        let remaining = body[problemStart...]
        let nextHeading = remaining.range(of: #"\n##\s+"#, options: .regularExpression)
        let problemEnd = nextHeading?.lowerBound ?? body.endIndex
        let problem = body[problemStart..<problemEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !problem.isEmpty else { return nil }
        let suffix = nextHeading.map { String(body[$0.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return ObsidianLegacyNoteCandidate(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            problem: problem,
            episodeID: episodeID,
            suffix: suffix
        )
    }

    private static func bodyAfterFrontmatter(_ markdown: String) -> String? {
        guard markdown.hasPrefix("---"),
              let close = markdown.range(of: "\n---", range: markdown.index(markdown.startIndex, offsetBy: 3)..<markdown.endIndex) else {
            return nil
        }
        return String(markdown[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstCapture(_ pattern: String, in source: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }
}
