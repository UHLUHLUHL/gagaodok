import Foundation

/// 챗봇 방 말투 조사의 출처·대사 선별 규칙을 확인합니다.
///
/// 폰 `PersonaSourcePipelineTest.kt`를 옮겼습니다. 폰의 대화용 대사 고르기(런타임 8개·900토큰)는
/// 맥에 옮기지 않았으므로 그 검사는 없습니다.
///
/// 실행:
///   swiftc -parse-as-library Tests/KakaoSapiensTests/PersonaSourcePipelineTests.swift \
///     Sources/KakaoSapiens/Services/PersonaSourcePipeline.swift \
///     Sources/KakaoSapiens/Models/PersonaEvidence.swift -o /tmp/persona-tests && /tmp/persona-tests
@main
struct PersonaSourcePipelineTests {
    typealias P = PersonaSourcePipeline

    static func main() {
        officialSourcesComeFirst()
        officialEvidenceExcludesUnverifiedAndCaps()
        bestOfficialTierOnly()
        nearDuplicatesDoNotInflate()
        differentEditionsStaySeparate()
        identicalTextMergesAcrossEditions()
        analysisCapsAtForty()
        officialYouTubeBecomesFileData()
        videosCapAtFiveAndFifteenMinutes()
        unknownLengthVideoIsClipped()
        duplicateKeepsObservationCount()
        evidenceParserKeepsUrlAndTimestamp()
        unlistedUrlIsRejected()
        discoveryValuesOverrideExtraction()
        youtubeUrlVariantsMerge()
        editedSampleDropsEvidence()
        punctuationEditDropsEvidence()
        documentLineWithoutTimestampSurvives()
        evidenceDecodesLeniently()
        print("PersonaSourcePipelineTests: 모두 통과")
    }

    static func evidence(
        _ text: String,
        tier: PersonaSourceTier = .officialLocalizedVideo,
        source: String = "https://youtube.com/watch?v=official",
        edition: String = "한국 공식 자막",
        context: String = "평상시"
    ) -> PersonaSampleEvidence {
        PersonaSampleEvidence(
            text: text, speaker: "인물", sourceUrl: source, sourceTitle: "공식 영상",
            sourceTier: tier, edition: edition, language: "ko", timestampSeconds: 12,
            contextTag: context, confidence: "높음"
        )
    }

    static func candidate(_ url: String, duration: Int? = nil) -> P.SourceCandidate {
        P.SourceCandidate(tier: .officialLocalizedVideo, url: url, publisher: "공식 채널",
                          title: "공식 영상", language: "ko", edition: "한국 자막",
                          officialityReason: "공식 채널", durationSeconds: duration)
    }

    static func officialSourcesComeFirst() {
        let parsed = P.parseSources("""
        [출처]
        UNVERIFIED\thttps://wiki.example/a\t팬 위키\t위키\tko\t\t출처 불명
        OFFICIAL_ORIGINAL_VIDEO\thttps://youtube.com/watch?v=jp\t제작사\t공식 PV\tja\t원어\t공식 채널
        OFFICIAL_LOCALIZED_VIDEO\thttps://youtube.com/watch?v=kr\t배급사\t한국 공식 예고편\tko\t한국 자막\t공식 채널
        """)
        precondition(parsed.map(\.tier) == [.officialLocalizedVideo, .officialOriginalVideo, .unverified],
                     "공식 한국 영상 → 공식 원어 영상 → 비공식: \(parsed.map(\.tier))")
    }

    static func officialEvidenceExcludesUnverifiedAndCaps() {
        let official = (1...55).map { evidence("공식 대사 \($0)") }
        let meme = evidence("밈 대사", tier: .unverified, source: "https://wiki.example/a")
        let selected = P.selectEvidence(official + [meme])
        precondition(selected.count == 48, "최대 48개: \(selected.count)")
        precondition(!selected.contains { $0.text == "밈 대사" }, "공식이 있으면 비공식을 섞지 않는다")
    }

    static func bestOfficialTierOnly() {
        let selected = P.selectEvidence([
            evidence("한국 공식 자막 대사"),
            evidence("원어 영상 대사", tier: .officialOriginalVideo),
            evidence("공식 문서 대사", tier: .officialText)
        ])
        precondition(selected.map(\.text) == ["한국 공식 자막 대사"], "\(selected.map(\.text))")
    }

    static func nearDuplicatesDoNotInflate() {
        let selected = P.selectEvidence([
            evidence("덴지 군은 말이야, 오늘은 괜찮아."),
            evidence("덴지 군은 말이야 오늘은 괜찮아!"),
            evidence("덴지 군은 말이야, 오늘은 정말 괜찮아."),
            evidence("오늘은 네가 먼저 말해 줘.", context: "부탁")
        ])
        precondition(selected.count <= 3, "유사 표본은 합친다: \(selected.count)")
        precondition(selected.contains { $0.text == "오늘은 네가 먼저 말해 줘." })
    }

    static func differentEditionsStaySeparate() {
        let selected = P.selectEvidence([
            evidence("같이 학교에 가자.", edition: "극장판 한국 자막"),
            evidence("우리 학교에 같이 가자.", edition: "TV판 한국 자막")
        ])
        precondition(selected.count == 2, "판본별 번역 차이는 보존한다")
    }

    static func identicalTextMergesAcrossEditions() {
        let selected = P.selectEvidence([
            evidence("완전히 같은 대사.", edition: "극장판"),
            evidence("완전히 같은 대사!", edition: "TV판")
        ])
        precondition(selected.count == 1, "문장이 같으면 판본이 달라도 하나")
    }

    static func analysisCapsAtForty() {
        let contexts = ["평상시", "질문", "거절", "장난", "분노"]
        let all = (1...48).map { i in
            evidence("\(i)번째 상황에서 서로 다른 길이와 종결을 가진 대사 " + String(repeating: "가", count: i * 2),
                     source: "https://youtube.com/watch?v=\(i)", context: contexts[i % 5])
        }
        precondition(P.selectAnalysisEvidence(all).count == 40, "분석은 최대 40개")
    }

    static func officialYouTubeBecomesFileData() {
        let source = candidate("https://www.youtube.com/watch?v=abc")
        precondition(P.videoUrls([source]) == ["https://www.youtube.com/watch?v=abc"])
        let parts = P.extractionParts(sources: [source], query: "인물")
        let fileUri = (parts.first?["fileData"] as? [String: Any])?["fileUri"] as? String
        precondition(fileUri == "https://www.youtube.com/watch?v=abc", "영상은 fileData로 넘긴다")
        precondition(parts.last?["text"] is String, "마지막 조각은 출처 목록 글")
    }

    static func videosCapAtFiveAndFifteenMinutes() {
        let sources = (1...6).map { candidate("https://youtube.com/watch?v=\($0)", duration: 240) }
        let inputs = P.videoInputs(sources)
        precondition(inputs.count <= 5, "영상은 최대 5개")
        precondition(inputs.map(\.analysisSeconds).reduce(0, +) <= 900, "합계 15분")
        precondition(inputs.last?.isClipped == true, "남은 시간만큼 잘린 영상은 잘렸다고 표시한다")
    }

    static func unknownLengthVideoIsClipped() {
        let input = P.videoInputs([candidate("https://youtu.be/unknown")])
        precondition(input.count == 1 && input[0].analysisSeconds == 900 && input[0].isClipped)
        let part = P.extractionParts(sources: [candidate("https://youtu.be/unknown")], query: "인물").first
        let end = (part?["videoMetadata"] as? [String: Any])?["endOffset"] as? String
        precondition(end == "900s", "잘린 영상은 끝 시각을 적는다: \(String(describing: end))")
    }

    static func duplicateKeepsObservationCount() {
        let selected = P.selectEvidence([
            evidence("덴지 군은 말이야, 오늘은 괜찮아."),
            evidence("덴지 군은 말이야 오늘은 괜찮아!"),
            evidence("다른 방식으로 대답할게.")
        ])
        precondition(selected.first { $0.text.hasPrefix("덴지") }?.similarSampleCount == 2, "관찰 횟수는 남긴다")
    }

    static func evidenceParserKeepsUrlAndTimestamp() {
        let parsed = P.parseEvidence("""
        [확신도] 높음 - 공식 자막 확인
        [대사]
        00:12\t평상시\t인물\t안녕, 오늘은 어때?\thttps://youtube.com/watch?v=a\t공식 영상\tOFFICIAL_LOCALIZED_VIDEO\t한국 자막\tko\t높음
        """)
        precondition(parsed.count == 1)
        precondition(parsed[0].timestampSeconds == 12 && parsed[0].sourceUrl == "https://youtube.com/watch?v=a")
        precondition(parsed[0].text == "안녕, 오늘은 어때?" && parsed[0].confidence == "높음")
    }

    static func unlistedUrlIsRejected() {
        let parsed = P.parseEvidence("""
        [대사]
        00:12\t평상시\t인물\t확인되지 않은 문장\thttps://unknown.example/a\t미상\tUNVERIFIED\t\tko\t낮음
        """, allowedSourceUrls: ["https://youtube.com/watch?v=official"])
        precondition(parsed.isEmpty, "탐색에서 확인하지 않은 URL은 받지 않는다")
    }

    // 폰 테스트는 모델이 탭 대신 `\t` 글자를 적은 경우입니다. 그 경우도 받아야 합니다.
    static func discoveryValuesOverrideExtraction() {
        let source = P.SourceCandidate(tier: .officialText, url: "https://official.example/script",
                                       publisher: "제작사", title: "공식 대본", language: "ko",
                                       edition: "공식판", officialityReason: "공식 사이트")
        let parsed = P.parseEvidence(#"""
        [대사]
        \t평상시\t인물\t확인된 문장\thttps://official.example/script\t가짜 제목\tOFFICIAL_LOCALIZED_VIDEO\t가짜판\tja\t높음
        """#, sourceCandidates: [source])
        precondition(parsed.count == 1, "글자 \\t도 칸 구분으로 읽는다")
        precondition(parsed[0].sourceTier == .officialText && parsed[0].sourceTitle == "공식 대본"
                     && parsed[0].edition == "공식판", "등급·제목·판본은 탐색 단계 값")
    }

    static func youtubeUrlVariantsMerge() {
        let parsed = P.parseSources("""
        [출처]
        OFFICIAL_LOCALIZED_VIDEO\thttps://youtu.be/abc123?t=3\t공식\t영상\tko\t자막\t공식\t30
        OFFICIAL_LOCALIZED_VIDEO\thttps://www.youtube.com/watch?v=abc123&utm_source=x\t공식\t영상\tko\t자막\t공식\t30
        """)
        precondition(parsed.count == 1, "같은 영상은 한 출처")
        precondition(parsed[0].durationSeconds == 30)
    }

    static func editedSampleDropsEvidence() {
        let kept = evidence("그대로인 대사")
        let edited = evidence("수정 전 대사")
        precondition(P.reconcile(samples: ["그대로인 대사", "수정된 대사"], evidence: [kept, edited]) == [kept])
    }

    static func punctuationEditDropsEvidence() {
        precondition(P.reconcile(samples: ["공식 원문이야!"], evidence: [evidence("공식 원문이야.")]).isEmpty)
    }

    // 문서에서 뽑은 대사는 시각 칸이 비어 줄이 진짜 탭으로 시작합니다. 폰은 이 줄을 버립니다.
    static func documentLineWithoutTimestampSurvives() {
        let source = P.SourceCandidate(tier: .officialText, url: "https://official.example/script",
                                       publisher: "제작사", title: "공식 대본", language: "ko",
                                       edition: "공식판", officialityReason: "공식 사이트")
        let parsed = P.parseEvidence(
            "[대사]\n\t평상시\t인물\t문서의 대사\thttps://official.example/script\t공식 대본\tOFFICIAL_TEXT\t공식판\tko\t보통",
            sourceCandidates: [source])
        precondition(parsed.count == 1, "앞의 탭을 지우면 칸이 밀려 버려진다")
        precondition(parsed[0].text == "문서의 대사" && parsed[0].timestampSeconds == nil)
        precondition(parsed[0].contextTag == "평상시" && parsed[0].confidence == "보통")
    }

    static func evidenceDecodesLeniently() {
        let json = #"{"text":"안녕","sourceTier":"SOMETHING_NEW"}"#
        let decoded = try! JSONDecoder().decode(PersonaSampleEvidence.self, from: Data(json.utf8))
        precondition(decoded.text == "안녕" && decoded.sourceTier == .unverified, "모르는 등급은 가장 낮게")
        precondition(decoded.similarSampleCount == 1 && decoded.timestampSeconds == nil, "빠진 칸은 기본값")
        let tier = try! JSONEncoder().encode([PersonaSourceTier.officialText])
        precondition(String(decoding: tier, as: UTF8.self) == #"["OFFICIAL_TEXT"]"#, "저장 글자는 폰과 같다")
    }
}
