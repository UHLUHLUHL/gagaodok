import Foundation

@main
struct ObsidianBatchExportTests {
    static func main() {
        precondition(ObsidianCommandIntent.classify("이거 옵시디언에 정리해줘") == .single)
        precondition(ObsidianCommandIntent.classify("내가 헷갈린 문제들 모두 옵시디언에 올려줘") == .batch)
        precondition(ObsidianCommandIntent.classify("옵시디언 문법이 뭐야?") == .none)

        let a = ObsidianBatchCandidate(startTurn: 1, endTurn: 3, relatedTurns: [1,2,3], unrelatedTurns: [], title: "A", score: 0.7, confidence: 0.8, reason: "")
        let b = ObsidianBatchCandidate(startTurn: 1, endTurn: 3, relatedTurns: [1,2,3], unrelatedTurns: [], title: "B", score: 0.9, confidence: 0.9, reason: "")
        let c = ObsidianBatchCandidate(startTurn: 8, endTurn: 9, relatedTurns: [8,9], unrelatedTurns: [], title: "C", score: 0.8, confidence: 0.8, reason: "")
        let merged = ObsidianBatchCandidateMerger.merge([a,b,c])
        precondition(merged.count == 2 && merged.first?.title == "B")
        precondition(ObsidianBatchCorpus.windowSize == 20 && ObsidianBatchCorpus.overlap == 4)
    }
}
