import Foundation
import CryptoKit

public struct ProblemEpisodeTurn: Identifiable {
    public let number: Int
    public let userMessage: ChatMessage
    public let assistantMessages: [ChatMessage]

    public var id: Int { number }
    public var userText: String { userMessage.canonicalText ?? userMessage.text }
    public var assistantText: String {
        assistantMessages.compactMap(\.canonicalText).first
            ?? assistantMessages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    public var messageIDs: [UUID] { [userMessage.id] + assistantMessages.map(\.id) }
}

public struct ProblemEpisodeCandidate {
    public enum BuildError: LocalizedError {
        case messageNotFound
        case assistantResponseRequired
        case responseHasNoQuestion

        public var errorDescription: String? {
            switch self {
            case .messageNotFound: return "선택한 메시지를 대화 기록에서 찾을 수 없습니다."
            case .assistantResponseRequired: return "멘토의 답변에서만 문제 정리를 시작할 수 있습니다."
            case .responseHasNoQuestion: return "이 답변에 연결된 사용자 질문을 찾을 수 없습니다."
            }
        }
    }

    public let roomID: UUID
    public let endpointTurn: Int
    public let turns: [ProblemEpisodeTurn]

    public var automaticTurns: [ProblemEpisodeTurn] { Array(turns.suffix(60)) }
    public var initialWindow: [ProblemEpisodeTurn] { Array(automaticTurns.suffix(12)) }
    public var availableRange: ClosedRange<Int> {
        (turns.first?.number ?? endpointTurn)...endpointTurn
    }

    public static func build(
        roomID: UUID,
        messages: [ChatMessage],
        endingAt selectedMessageID: UUID
    ) throws -> ProblemEpisodeCandidate {
        guard let selectedIndex = messages.firstIndex(where: { $0.id == selectedMessageID }) else {
            throw BuildError.messageNotFound
        }
        guard messages[selectedIndex].sender == .sapiens else {
            throw BuildError.assistantResponseRequired
        }

        var logicalTurns: [ProblemEpisodeTurn] = []
        var index = 0
        var turnNumber = 0
        var endpoint: Int?

        while index < messages.count {
            let message = messages[index]
            guard message.sender == .user else {
                index += 1
                continue
            }

            turnNumber += 1
            var assistantMessages: [ChatMessage] = []
            var cursor = index + 1
            while cursor < messages.count, messages[cursor].sender == .sapiens {
                assistantMessages.append(messages[cursor])
                cursor += 1
            }

            let turn = ProblemEpisodeTurn(
                number: turnNumber,
                userMessage: message,
                assistantMessages: assistantMessages
            )
            logicalTurns.append(turn)
            if assistantMessages.contains(where: { $0.id == selectedMessageID }) {
                endpoint = turnNumber
                break
            }
            index = cursor
        }

        guard let endpoint else { throw BuildError.responseHasNoQuestion }
        return ProblemEpisodeCandidate(
            roomID: roomID,
            endpointTurn: endpoint,
            turns: logicalTurns
        )
    }

    public func turns(in range: ClosedRange<Int>) -> [ProblemEpisodeTurn] {
        turns.filter { range.contains($0.number) }
    }

    public func transcript(in range: ClosedRange<Int>) -> String {
        turns(in: range).flatMap { turn -> [String] in
            var lines = ["[\(turn.number)턴] 학습자: \(turn.userText)"]
            if let attachment = turn.userMessage.attachment {
                let label = attachment.type == .image ? "첨부이미지" : "첨부파일"
                lines.append("[\(turn.number)턴] [\(label): \(attachment.fileName)]")
            }
            if !turn.assistantText.isEmpty {
                lines.append("[\(turn.number)턴] 멘토: \(turn.assistantText)")
            }
            return lines
        }.joined(separator: "\n\n")
    }

    public func messageIDs(in range: ClosedRange<Int>, excluding turnsToOmit: Set<Int> = []) -> [UUID] {
        turns(in: range)
            .filter { !turnsToOmit.contains($0.number) }
            .flatMap(\.messageIDs)
    }

    public func attachments(
        in range: ClosedRange<Int>,
        excluding turnsToOmit: Set<Int> = []
    ) -> [(turn: Int, messageID: UUID, attachment: ChatAttachment)] {
        turns(in: range).compactMap { turn in
            guard !turnsToOmit.contains(turn.number), let attachment = turn.userMessage.attachment else { return nil }
            return (turn.number, turn.userMessage.id, attachment)
        }
    }

    public func episodeID(in range: ClosedRange<Int>, excluding turnsToOmit: Set<Int>) -> String {
        let ids = messageIDs(in: range, excluding: turnsToOmit).map(\.uuidString).joined(separator: ",")
        let omitted = turnsToOmit.sorted().map(String.init).joined(separator: ",")
        let source = "\(roomID.uuidString)|\(range.lowerBound)-\(range.upperBound)|\(omitted)|\(ids)"
        return SHA256.hash(data: Data(source.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ObsidianAIResponseParser {
    public enum ParseError: LocalizedError {
        case jsonObjectMissing
        case invalidJSON(Error)

        public var errorDescription: String? {
            switch self {
            case .jsonObjectMissing:
                return "AI 정리 응답에서 JSON 객체를 찾을 수 없습니다."
            case .invalidJSON:
                return "AI 정리 응답의 구조를 읽을 수 없습니다. 다시 정리해주세요."
            }
        }
    }

    public static func decode<T: Decodable>(_ raw: String, as type: T.Type = T.self) throws -> T {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start <= end else {
            throw ParseError.jsonObjectMissing
        }
        let json = String(raw[start...end])
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw ParseError.invalidJSON(error)
        }
    }
}

public struct EpisodeScopeResult: Codable, Equatable {
    public var startTurn: Int
    public var endTurn: Int
    public var confidence: Double
    public var relatedTurns: [Int]
    public var unrelatedTurns: [Int]
    public var needsEarlierContext: Bool
    public var reason: String

    public init(
        startTurn: Int,
        endTurn: Int,
        confidence: Double,
        relatedTurns: [Int],
        unrelatedTurns: [Int],
        needsEarlierContext: Bool,
        reason: String
    ) {
        self.startTurn = startTurn
        self.endTurn = endTurn
        self.confidence = confidence
        self.relatedTurns = relatedTurns
        self.unrelatedTurns = unrelatedTurns
        self.needsEarlierContext = needsEarlierContext
        self.reason = reason
    }
}

public struct TurnCoverage: Codable, Equatable, Identifiable {
    public enum Status: String, Codable, CaseIterable {
        case included
        case unrelated
        case merged

        public var displayName: String {
            switch self {
            case .included: return "포함"
            case .unrelated: return "무관하여 제외"
            case .merged: return "중복으로 통합"
            }
        }
    }

    public let turn: Int
    public let status: Status
    public let reason: String
    public var id: Int { turn }

    public init(turn: Int, status: Status, reason: String) {
        self.turn = turn
        self.status = status
        self.reason = reason
    }
}

public struct PreparedObsidianNote: Codable, Equatable {
    public var title: String
    public var problem: String
    public var givens: [String]
    public var ideas: [String]
    public var confusions: [String]
    public var solution: String
    public var answer: String
    public var concepts: [String]
    public var unresolved: [String]
    public var evidenceTurns: [Int]
    public var coverage: [TurnCoverage]

    public init(
        title: String,
        problem: String,
        givens: [String],
        ideas: [String],
        confusions: [String],
        solution: String,
        answer: String,
        concepts: [String],
        unresolved: [String],
        evidenceTurns: [Int],
        coverage: [TurnCoverage]
    ) {
        self.title = title
        self.problem = problem
        self.givens = givens
        self.ideas = ideas
        self.confusions = confusions
        self.solution = solution
        self.answer = answer
        self.concepts = concepts
        self.unresolved = unresolved
        self.evidenceTurns = evidenceTurns
        self.coverage = coverage
    }

    public func missingCoverage(in range: ClosedRange<Int>) -> [Int] {
        let covered = Set(coverage.map(\.turn))
        return range.filter { !covered.contains($0) }
    }
}

/// 화면 편집용 상태입니다. AI가 돌려준 근거/커버리지는 숨겨 둔 채 사용자가 보는
/// 각 섹션만 문자열로 고칠 수 있게 하며, 미리보기와 저장이 이 값을 함께 사용합니다.
public struct ObsidianNoteDraft: Equatable {
    public var title: String
    public var problem: String
    public var givensText: String
    public var ideasText: String
    public var confusionsText: String
    public var solution: String
    public var answer: String
    public var conceptsText: String
    public var unresolvedText: String

    private var evidenceTurns: [Int]
    private var coverage: [TurnCoverage]

    public init(prepared: PreparedObsidianNote) {
        title = prepared.title
        problem = prepared.problem
        givensText = prepared.givens.joined(separator: "\n")
        ideasText = prepared.ideas.joined(separator: "\n")
        confusionsText = prepared.confusions.joined(separator: "\n")
        solution = prepared.solution
        answer = prepared.answer
        conceptsText = prepared.concepts.joined(separator: "\n")
        unresolvedText = prepared.unresolved.joined(separator: "\n")
        evidenceTurns = prepared.evidenceTurns
        coverage = prepared.coverage
    }

    public var preparedNote: PreparedObsidianNote {
        PreparedObsidianNote(
            title: title,
            problem: problem,
            givens: Self.list(from: givensText),
            ideas: Self.list(from: ideasText),
            confusions: Self.list(from: confusionsText),
            solution: solution,
            answer: answer,
            concepts: Self.list(from: conceptsText),
            unresolved: Self.list(from: unresolvedText),
            evidenceTurns: evidenceTurns,
            coverage: coverage
        )
    }

    private static func list(from text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { raw in
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("- ") { value.removeFirst(2) }
            return value.isEmpty ? nil : value
        }
    }
}

public struct ObsidianInternalMetadata: Codable, Equatable {
    public let version: Int
    public let episodeID: String

    enum CodingKeys: String, CodingKey {
        case version
        case episodeID = "episode_id"
    }

    public init(version: Int = 2, episodeID: String) {
        self.version = version
        self.episodeID = episodeID
    }

    public var comment: String {
        let escaped = episodeID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "<!-- gagaodok-export: {\"version\":\(version),\"episode_id\":\"\(escaped)\"} -->"
    }

    public static func parse(from markdown: String) -> ObsidianInternalMetadata? {
        let pattern = #"<!--\s*gagaodok-export:\s*\{\s*\"version\"\s*:\s*(\d+)\s*,\s*\"episode_id\"\s*:\s*\"([^\"]+)\"\s*\}\s*-->"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)),
              let versionRange = Range(match.range(at: 1), in: markdown),
              let episodeRange = Range(match.range(at: 2), in: markdown),
              let version = Int(markdown[versionRange]) else { return nil }
        return ObsidianInternalMetadata(version: version, episodeID: String(markdown[episodeRange]))
    }
}

public struct ObsidianNoteMetadata {
    public let roomID: UUID
    public let roomName: String
    public let modelName: String
    public let startTurn: Int
    public let endTurn: Int
    public let messageIDs: [UUID]
    public let episodeID: String
    public let createdAt: Date

    public init(
        roomID: UUID,
        roomName: String,
        modelName: String,
        startTurn: Int,
        endTurn: Int,
        messageIDs: [UUID],
        episodeID: String,
        createdAt: Date = Date()
    ) {
        self.roomID = roomID
        self.roomName = roomName
        self.modelName = modelName
        self.startTurn = startTurn
        self.endTurn = endTurn
        self.messageIDs = messageIDs
        self.episodeID = episodeID
        self.createdAt = createdAt
    }
}

public enum ObsidianMarkdownFormatter {
    public static func render(
        note: PreparedObsidianNote,
        metadata: ObsidianNoteMetadata,
        attachmentPaths: [String],
        problemCardPath: String? = nil
    ) -> String {
        normalizeMath(renderFrontmatter(metadata: metadata) + "\n\n" + renderBody(
            note: note,
            attachmentPaths: attachmentPaths,
            problemCardPath: problemCardPath
        ))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    public static func renderFrontmatter(metadata: ObsidianNoteMetadata) -> String {
        [
            "---",
            "tags:",
            "  - 가가오독",
            "  - 수학문제",
            "---",
            ObsidianInternalMetadata(episodeID: metadata.episodeID).comment
        ]
        .joined(separator: "\n")
    }

    public static func renderBody(
        note: PreparedObsidianNote,
        attachmentPaths: [String],
        problemCardPath: String? = nil
    ) -> String {
        var lines = ["# \(note.title)", "", "## 문제"]
        if let problemCardPath {
            lines.append("")
            lines.append("![[\(relativeAttachmentPath(problemCardPath))]]")
            lines.append("")
            lines.append("> [!abstract]- 문제 원문 보기")
            lines.append(contentsOf: calloutLines(note.problem))
        } else {
            appendText(note.problem, to: &lines)
        }
        if !attachmentPaths.isEmpty {
            lines.append("")
            lines.append("> [!note]- 원본 첨부")
            lines.append(contentsOf: attachmentPaths.map { "> ![[\(relativeAttachmentPath($0))]]" })
        }
        appendList(title: "핵심 조건과 주어진 정보", values: note.givens, to: &lines)
        appendList(title: "시도한 아이디어", values: note.ideas, to: &lines)
        appendList(title: "헷갈린 포인트와 교정", values: note.confusions, to: &lines)
        lines.append(contentsOf: ["", "## 최종 해설"])
        appendText(note.solution, to: &lines)
        lines.append(contentsOf: ["", "## 최종 답"])
        appendText(note.answer, to: &lines)
        appendList(title: "알아두면 좋은 개념", values: note.concepts, to: &lines)

        if !note.unresolved.isEmpty {
            lines.append(contentsOf: ["", "> [!warning] 미해결"])
            lines.append(contentsOf: note.unresolved.map { "> - \($0)" })
        }
        if !note.coverage.isEmpty {
            lines.append(contentsOf: ["", "> [!info]- 정리 범위와 근거"])
            lines.append(contentsOf: note.coverage.sorted { $0.turn < $1.turn }.map {
                "> - \($0.turn)턴 · \($0.status.displayName) · \($0.reason)"
            })
        }
        return normalizeMath(lines.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizeMath(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var inFence = false
        var result: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            if isFence {
                inFence.toggle()
                result.append(line)
                continue
            }
            guard !inFence else {
                result.append(line)
                continue
            }
            let normalized = line
                .replacingOccurrences(of: "\\[", with: "$$\n")
                .replacingOccurrences(of: "\\]", with: "\n$$")
                .replacingOccurrences(of: "\\(", with: "$")
                .replacingOccurrences(of: "\\)", with: "$")
            result.append(normalized)
        }
        return result.joined(separator: "\n")
    }

    private static func relativeAttachmentPath(_ raw: String) -> String {
        if let range = raw.range(of: "attachments/") { return String(raw[range.lowerBound...]) }
        return raw
    }

    private static func calloutLines(_ source: String) -> [String] {
        source.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }
    }

    private static func appendText(_ value: String, to lines: inout [String]) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lines.append("\n_대화에서 확정되지 않음_")
            return
        }
        lines.append("")
        lines.append(value)
    }

    private static func appendList(title: String, values: [String], to lines: inout [String]) {
        lines.append(contentsOf: ["", "## \(title)"])
        if values.isEmpty {
            lines.append("\n_해당 내용 없음_")
        } else {
            lines.append("")
            lines.append(contentsOf: values.map { "- \($0)" })
        }
    }
}
