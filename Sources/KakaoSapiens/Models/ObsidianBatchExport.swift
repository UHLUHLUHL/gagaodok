import Foundation
import CryptoKit

public enum ObsidianCommandIntent: Equatable {
    case none, single, batch

    public static func classify(_ text: String) -> Self {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains("옵시디언") else { return .none }
        let verbs = ["올려", "저장", "정리", "내보내"]
        guard verbs.contains(where: normalized.contains) else { return .none }
        let plural = ["문제들", "여러", "모두", "전부", "헷갈린", "틀렸던", "어려웠던"]
        return plural.contains(where: normalized.contains) ? .batch : .single
    }
}

public struct ObsidianBatchCandidate: Codable, Identifiable, Equatable {
    public var id: String { "\(startTurn)-\(endTurn)-\(title)" }
    public let startTurn: Int
    public let endTurn: Int
    public let relatedTurns: [Int]
    public let unrelatedTurns: [Int]
    public let title: String
    public let score: Double
    public let confidence: Double
    public let reason: String

    public init(startTurn: Int, endTurn: Int, relatedTurns: [Int], unrelatedTurns: [Int], title: String, score: Double, confidence: Double, reason: String) {
        self.startTurn = startTurn; self.endTurn = endTurn
        self.relatedTurns = relatedTurns; self.unrelatedTurns = unrelatedTurns
        self.title = title; self.score = score; self.confidence = confidence; self.reason = reason
    }
}

public struct ObsidianBatchCandidateResponse: Codable { public let candidates: [ObsidianBatchCandidate] }

public enum ObsidianBatchCandidateMerger {
    public static func merge(_ candidates: [ObsidianBatchCandidate]) -> [ObsidianBatchCandidate] {
        var result: [ObsidianBatchCandidate] = []
        for candidate in candidates.sorted(by: { ($0.endTurn, $0.startTurn) < ($1.endTurn, $1.startTurn) }) {
            if let index = result.firstIndex(where: { sameEpisode($0, candidate) }) {
                if candidate.score > result[index].score { result[index] = candidate }
            } else { result.append(candidate) }
        }
        return result.sorted { $0.endTurn < $1.endTurn }
    }

    private static func sameEpisode(_ lhs: ObsidianBatchCandidate, _ rhs: ObsidianBatchCandidate) -> Bool {
        if lhs.endTurn == rhs.endTurn { return true }
        let a = Set(lhs.relatedTurns), b = Set(rhs.relatedTurns)
        guard !a.isEmpty || !b.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(a.union(b).count) >= 0.6
    }
}

public enum ObsidianBatchCorpus {
    public static let windowSize = 20
    public static let overlap = 4

    public static func windows(turns: [ProblemEpisodeTurn]) -> [[ProblemEpisodeTurn]] {
        guard !turns.isEmpty else { return [] }
        var output: [[ProblemEpisodeTurn]] = [], start = 0
        while start < turns.count {
            let end = min(start + windowSize, turns.count)
            output.append(Array(turns[start..<end]))
            if end == turns.count { break }
            start += windowSize - overlap
        }
        return output
    }

    public static func classificationTranscript(_ turns: [ProblemEpisodeTurn]) -> String {
        turns.map { turn in
            let user = clipped(turn.userText, limit: 800)
            let assistant = clipped(turn.assistantText, limit: 1_200)
            let attachment = turn.userMessage.attachment.map { "\n[첨부 메타데이터: \($0.fileName), \($0.mimeType), \($0.fileSize) bytes]" } ?? ""
            return "[\(turn.number)턴] 학습자: \(user)\(attachment)\n[\(turn.number)턴] 멘토: \(assistant)"
        }.joined(separator: "\n\n")
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

public enum ObsidianBatchCacheKey {
    public static func make(roomID: UUID, lastMessageID: UUID, model: AIModel, criterion: String, classifierVersion: Int = 1) -> String {
        let source = "\(roomID.uuidString)|\(lastMessageID.uuidString)|\(model.rawValue)|\(criterion)|\(classifierVersion)"
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
