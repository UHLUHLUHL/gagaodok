import Foundation

/// 챗봇 방의 말투 조사에서 출처를 고르고 대사를 추립니다.
///
/// 폰 `PersonaSourcePipeline.kt`를 옮겼습니다. 규칙이 같아야 두 기기에서 같은 인물을 조사했을 때
/// 같은 대사가 남습니다. 모델을 부르지 않는 순수한 계산만 둡니다 — 부르는 쪽은
/// `GeminiService+Persona.swift`의 `lookupCompanionPersona`입니다.
///
/// 폰은 여기서 대화할 때 넣을 대사도 고릅니다(`selectRuntimePersonaSamples`). 맥은 그 부분을
/// 옮기지 않았습니다. 대화 지침이 바뀌어 캐시와 말투에 함께 영향을 주므로 따로 다룹니다.
enum PersonaSourcePipeline {
    static let collectionTarget = 40
    static let collectionLimit = 48
    static let analysisLimit = 40
    /// 한 번에 넘길 영상 수와 합계 길이입니다.
    static let videoLimit = 5
    static let videoSecondsLimit = 15 * 60
    static let sourceLimit = 8

    struct SourceCandidate: Equatable {
        var tier: PersonaSourceTier
        var url: String
        var publisher: String
        var title: String
        var language: String
        var edition: String
        var officialityReason: String
        var durationSeconds: Int? = nil

        var isYouTube: Bool {
            let lower = url.lowercased()
            return lower.contains("youtube.com/") || lower.contains("youtu.be/")
        }
    }

    struct VideoInput: Equatable {
        let url: String
        let analysisSeconds: Int
        let isClipped: Bool
    }

    // MARK: - 해석

    static func parseSources(_ text: String) -> [SourceCandidate] {
        var seen = Set<String>()
        let parsed = sectionLines(text, after: "[출처]").compactMap { raw -> SourceCandidate? in
            let fields = splitFields(raw)
            guard fields.count >= 3,
                  let tier = PersonaSourceTier(rawValue: fields[0].trimmed) else { return nil }
            let url = fields[1].trimmed
            guard url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
            return SourceCandidate(
                tier: tier,
                url: url,
                publisher: field(fields, 2),
                title: field(fields, 3),
                language: field(fields, 4),
                edition: field(fields, 5),
                officialityReason: field(fields, 6),
                durationSeconds: fields.count > 7 ? Int(fields[7].trimmed) : nil
            )
        }
        .filter { seen.insert(canonicalSourceUrl($0.url)).inserted }
        return stableSorted(parsed) { a, b in
            a.tier.priority != b.tier.priority ? a.tier.priority < b.tier.priority : a.url < b.url
        }
        .prefix(sourceLimit).map { $0 }
    }

    static func parseEvidence(
        _ text: String,
        allowedSourceUrls: Set<String> = [],
        sourceCandidates: [SourceCandidate] = []
    ) -> [PersonaSampleEvidence] {
        let allowedCanonical = Set(allowedSourceUrls.map(canonicalSourceUrl))
        return sectionLines(text, after: "[대사]").compactMap { raw in
            let fields = splitFields(raw)
            guard fields.count >= 4 else { return nil }
            let quote = fields[3].trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」"))
            let sourceUrl = field(fields, 4)
            guard !quote.isEmpty, quote != "대사 원문" else { return nil }
            let canonical = canonicalSourceUrl(sourceUrl)
            let source = sourceCandidates.first { canonicalSourceUrl($0.url) == canonical }
            if !allowedCanonical.isEmpty && !allowedCanonical.contains(canonical) { return nil }
            if !sourceCandidates.isEmpty && source == nil { return nil }
            return PersonaSampleEvidence(
                text: quote,
                speaker: field(fields, 2),
                sourceUrl: sourceUrl,
                // 등급·제목·판본은 모델이 이번에 적은 값이 아니라 탐색 단계에서 확인한 값을 씁니다.
                sourceTitle: source?.title ?? field(fields, 5),
                sourceTier: source?.tier ?? PersonaSourceTier(rawValue: field(fields, 6)) ?? .unverified,
                edition: source?.edition ?? field(fields, 7),
                language: source?.language ?? field(fields, 8),
                timestampSeconds: parseTimestampSeconds(fields[0]),
                contextTag: field(fields, 1),
                confidence: field(fields, 9)
            )
        }
    }

    static func parseTimestampSeconds(_ value: String) -> Int? {
        let pieces = value.trimmed.components(separatedBy: ":").compactMap { Int($0) }
        switch pieces.count {
        case 2: return pieces[0] * 60 + pieces[1]
        case 3: return pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
        default: return nil
        }
    }

    // MARK: - 요청 조립

    /// 공식 유튜브는 URL 읽기가 아니라 영상 자체(`fileData`)로 넘깁니다.
    static func extractionParts(sources: [SourceCandidate], query: String) -> [[String: Any]] {
        let videos = videoInputs(sources)
        let videoUrls = Set(videos.map(\.url))
        var parts: [[String: Any]] = videos.map { video in
            var part: [String: Any] = ["fileData": ["fileUri": video.url]]
            if video.isClipped {
                part["videoMetadata"] = ["endOffset": "\(video.analysisSeconds)s"]
            }
            return part
        }
        let ledger = sources
            .filter { !$0.isYouTube || videoUrls.contains($0.url) }
            .map { [$0.tier.rawValue, $0.url, $0.publisher, $0.title, $0.language, $0.edition].joined(separator: "\t") }
            .joined(separator: "\n")
        parts.append([
            "text": "인물: \(query.trimmed)\n\n검증할 출처:\n\(ledger)\n\n"
                + "공식 한국 영상에서는 음성을 임의 번역하지 말고 화면의 공식 한국어 자막을 우선한다."
        ])
        return parts
    }

    /// 영상은 최대 5개, 합계 15분까지만 봅니다. 길이를 모르면 남은 시간만큼 잘라서 봅니다.
    static func videoInputs(_ sources: [SourceCandidate]) -> [VideoInput] {
        let eligible = stableSorted(sources.filter {
            $0.isYouTube && $0.tier.priority <= PersonaSourceTier.officialText.priority
        }) { $0.tier.priority < $1.tier.priority }
        var seen = Set<String>()
        var remaining = videoSecondsLimit
        var inputs: [VideoInput] = []
        for source in eligible where seen.insert(canonicalSourceUrl(source.url)).inserted {
            if inputs.count >= videoLimit || remaining <= 0 { continue }
            let duration = source.durationSeconds.flatMap { $0 > 0 ? $0 : nil }
            let seconds = min(duration ?? remaining, remaining)
            inputs.append(VideoInput(url: source.url, analysisSeconds: seconds,
                                     isClipped: duration == nil || duration! > seconds))
            remaining -= seconds
        }
        return inputs
    }

    static func videoUrls(_ sources: [SourceCandidate]) -> [String] {
        videoInputs(sources).map(\.url)
    }

    // MARK: - 선별

    /// 가장 좋은 공식 등급만 남기고, 거의 같은 대사는 하나로 합치며, 다양하게 고릅니다.
    static func selectEvidence(
        _ evidence: [PersonaSampleEvidence],
        limit: Int = collectionLimit
    ) -> [PersonaSampleEvidence] {
        let cleaned = evidence.filter { !$0.text.trimmed.isEmpty }
        let bestOfficial = cleaned.map(\.sourceTier.priority).min().flatMap { $0 <= 2 ? $0 : nil }
        let eligible = bestOfficial.map { best in cleaned.filter { $0.sourceTier.priority == best } } ?? cleaned
        let ordered = stableSorted(eligible) { a, b in
            if a.sourceTier.priority != b.sourceTier.priority { return a.sourceTier.priority < b.sourceTier.priority }
            let ra = confidenceRank(a.confidence), rb = confidenceRank(b.confidence)
            if ra != rb { return ra > rb }
            if a.sourceUrl != b.sourceUrl { return a.sourceUrl < b.sourceUrl }
            return (a.timestampSeconds ?? Int.max) < (b.timestampSeconds ?? Int.max)
        }
        var selected: [PersonaSampleEvidence] = []
        for candidate in ordered where selected.count < limit {
            if let index = selected.firstIndex(where: { isDuplicateLine($0, candidate) }) {
                selected[index].similarSampleCount += max(1, candidate.similarSampleCount)
            } else {
                selected.append(candidate)
            }
        }
        return diversify(selected, limit: limit)
    }

    static func selectAnalysisEvidence(_ evidence: [PersonaSampleEvidence]) -> [PersonaSampleEvidence] {
        diversify(selectEvidence(evidence), limit: analysisLimit)
    }

    /// 사용자가 편집 칸에서 고친 대사는 원문이 아니므로 출처 연결을 끊습니다.
    static func reconcile(samples: [String], evidence: [PersonaSampleEvidence]) -> [PersonaSampleEvidence] {
        let current = Set(samples.map(\.trimmed))
        return evidence.filter { current.contains($0.text.trimmed) }
    }

    private static func diversify(_ evidence: [PersonaSampleEvidence], limit: Int) -> [PersonaSampleEvidence] {
        guard evidence.count > 1 else { return Array(evidence.prefix(limit)) }
        var remaining = evidence
        var selected: [PersonaSampleEvidence] = []
        while !remaining.isEmpty && selected.count < limit {
            // 점수가 같으면 앞의 것을 고릅니다(폰의 `maxBy`와 같습니다).
            var best = 0
            var bestScore = diversityScore(remaining[0], selected)
            for index in remaining.indices.dropFirst() {
                let score = diversityScore(remaining[index], selected)
                if score > bestScore { best = index; bestScore = score }
            }
            selected.append(remaining.remove(at: best))
        }
        return selected
    }

    private static func diversityScore(_ candidate: PersonaSampleEvidence, _ selected: [PersonaSampleEvidence]) -> Int {
        if selected.isEmpty { return 100 - candidate.sourceTier.priority }
        let normalized = normalizeLine(candidate.text)
        let sourceNovelty = selected.contains { $0.sourceUrl == candidate.sourceUrl } ? 0 : 12
        let contextNovelty = !candidate.contextTag.isEmpty
            && !selected.contains { $0.contextTag == candidate.contextTag } ? 10 : 0
        let ending = String(normalized.suffix(4))
        let endingNovelty = selected.contains { String(normalizeLine($0.text).suffix(4)) == ending } ? 0 : 6
        let bucket = candidate.text.utf16.count / 20
        let lengthNovelty = selected.contains { $0.text.utf16.count / 20 == bucket } ? 0 : 4
        let start = String(normalized.prefix(8))
        let startNovelty = selected.contains { String(normalizeLine($0.text).prefix(8)) == start } ? 0 : 8
        return sourceNovelty + contextNovelty + endingNovelty + lengthNovelty + startNovelty
            - candidate.sourceTier.priority
    }

    private static func isDuplicateLine(_ a: PersonaSampleEvidence, _ b: PersonaSampleEvidence) -> Bool {
        let left = normalizeLine(a.text)
        let right = normalizeLine(b.text)
        if left == right { return true }
        if !a.edition.isEmpty && !b.edition.isEmpty && a.edition != b.edition { return false }
        if max(left.count, right.count) < 14 || left.prefix(8) != right.prefix(8) { return false }
        return bigramJaccard(left, right) >= 0.62
    }

    private static func bigramJaccard(_ left: String, _ right: String) -> Double {
        func bigrams(_ s: String) -> Set<String> {
            let chars = Array(s)
            guard chars.count >= 2 else { return [] }
            return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
        }
        let a = bigrams(left), b = bigrams(right)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    // 폰의 `[\s\p{Punct}·…‘’“”「」『』]+`입니다. 자바의 \p{Punct}는 ASCII 문장부호만 뜻합니다.
    private static let separators = try! NSRegularExpression(
        pattern: "[\\s!-/:-@\\[-`{-~·…‘’“”「」『』]+")

    static func normalizeLine(_ value: String) -> String {
        let lower = value.lowercased()
        let range = NSRange(lower.startIndex..., in: lower)
        return separators.stringByReplacingMatches(in: lower, range: range, withTemplate: "")
    }

    static func canonicalSourceUrl(_ value: String) -> String {
        let lower = value.trimmed.lowercased()
        var youtubeId = ""
        if let range = lower.range(of: "youtu.be/") {
            youtubeId = before(before(String(lower[range.upperBound...]), "?"), "/")
        } else if lower.contains("youtube.com/watch") {
            if let range = lower.range(of: "v=") {
                youtubeId = before(String(lower[range.upperBound...]), "&")
            }
        }
        if !youtubeId.isEmpty { return "youtube:\(youtubeId)" }
        var result = before(before(lower, "#"), "?")
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private static func confidenceRank(_ confidence: String) -> Int {
        switch confidence {
        case "높음": return 2
        case "보통": return 1
        default: return 0
        }
    }

    // MARK: - 글자 다루기

    /// 머리말 다음 줄부터 다음 `[`로 시작하는 줄 전까지입니다.
    private static func sectionLines(_ text: String, after header: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmed.hasPrefix(header) }) else { return [] }
        var result: [String] = []
        for line in lines[(start + 1)...] {
            if line.trimmed.hasPrefix("[") { break }
            result.append(line)
        }
        return result
    }

    /// 앞뒤의 목록 기호를 떼고 탭으로 나눕니다. 모델이 탭 대신 `\t` 글자를 적어도 받습니다.
    ///
    /// **탭은 떼지 않습니다.** 문서에서 뽑은 대사는 시각 칸이 비어 줄이 탭으로 시작합니다.
    /// 폰은 `trim()`이 그 탭까지 지워 칸이 하나씩 밀리고, 그 줄이 통째로 버려집니다.
    private static func splitFields(_ raw: String) -> [String] {
        var edges = CharacterSet.whitespacesAndNewlines
        edges.remove("\t")
        edges.insert(charactersIn: "-•")
        return raw
            .trimmingCharacters(in: edges)
            .replacingOccurrences(of: "\\t", with: "\t")
            .components(separatedBy: "\t")
    }

    private static func field(_ fields: [String], _ index: Int) -> String {
        index < fields.count ? fields[index].trimmed : ""
    }

    private static func before(_ value: String, _ separator: String) -> String {
        value.range(of: separator).map { String(value[..<$0.lowerBound]) } ?? value
    }

    /// 표준 정렬은 안정성을 약속하지 않습니다. 같은 값이면 원래 순서를 지킵니다.
    private static func stableSorted<T>(_ items: [T], by less: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
