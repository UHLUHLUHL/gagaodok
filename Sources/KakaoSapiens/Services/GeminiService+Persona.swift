import Foundation

/// 말투를 찾고, 뽑고, 다듬고, 미리 들어 보는 길입니다.
///
/// 대화와 달리 캐시를 쓰지 않습니다. 방마다 한 번씩만 일어나는 일이라서입니다.
extension GeminiService {
    /// 캐릭터 이름이나 참고 링크만으로 말투를 조사한 결과입니다.
    public struct PersonaLookup {
        public let confidence: String   // 높음 / 보통 / 낮음
        public let note: String
        public let samples: [String]
        public let styleGuide: String
        public let sources: [String]
        /// 챗봇 방의 두 단계 조사에서만 채워집니다. 대사마다 확인한 출처입니다.
        public var evidence: [PersonaSampleEvidence] = []

        public var isUsable: Bool { !samples.isEmpty || !styleGuide.isEmpty }
    }

    /// 대사를 외우고 있지 않아도 되도록, 이름이나 링크만으로 말투를 조사합니다.
    ///
    /// 검색 그라운딩과 URL 읽기를 함께 켜므로 이름이든 링크든 같은 입구로 처리됩니다.
    /// 스크린샷을 넘기면 거기 적힌 대사도 함께 읽습니다.
    /// 모르는 인물이면 지어내지 않고 확신도를 '낮음'으로 돌려줍니다.
    /// - Parameter onProgress: 지금 무엇이 도착했는지를 알려 줍니다.
    ///   자세한 것은 `lookupProgressLabel(_:)`에 적었습니다.
    ///
    /// 챗봇 방에서 스크린샷 없이 찾으면 `lookupCompanionPersona`의 두 단계로 갑니다.
    /// 멘토 방과 스크린샷을 넘긴 경우는 예전처럼 한 번에 찾습니다(폰과 같습니다).
    public func lookupPersona(
        query: String,
        roomId: UUID,
        imageBase64: String? = nil,
        imageMimeType: String? = nil,
        mode: ChatMode = .mathMentor,
        onProgress: @Sendable @escaping (String) async -> Void = { _ in }
    ) async throws -> PersonaLookup {
        guard let apiKey = KeychainStore.geminiAPIKey else {
            throw serviceError("설정에서 Gemini API 키를 먼저 등록해주세요.")
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty || imageBase64 != nil else {
            throw serviceError("캐릭터 이름이나 참고 링크를 입력해주세요.")
        }
        if mode == .companion && imageBase64 == nil {
            return try await lookupCompanionPersona(
                query: trimmedQuery, roomId: roomId, apiKey: apiKey, onProgress: onProgress)
        }

        let baseInstruction = """
        너는 말투 조사관이다. 사용자가 지정한 인물의 말투를 조사해 정리한다.

        먼저 검색이나 주어진 링크·이미지에서 그 인물의 실제 대사를 찾는다. 그 다음 아래 형식으로만 출력한다.

        [확신도] 높음/보통/낮음 중 하나와 한 줄 근거.
        - 실제 대사를 여러 개 찾았으면 '높음'
        - 인물 설명은 찾았지만 대사가 적으면 '보통'
        - 인물을 특정하지 못했으면 '낮음'이라고 솔직히 적고 아래 두 절을 비운다

        [대사]
        찾은 실제 대사를 한 줄에 하나씩, 최대 20줄. 앞에 기호를 붙이지 않는다.
        지어내지 말고 실제로 찾은 것만 적는다. 찾지 못했으면 이 절을 비운다.

        [말투]
        - 문장 끝맺음:
        - 높임 수준:
        - 1인칭과 호칭:
        - 자주 쓰는 표현:
        - 문장 길이와 리듬:
        - 감정 표현:
        - 피해야 할 것:
        - 한 줄 요약:

        없는 사실을 지어내지 않는다. 확실하지 않으면 확신도를 낮춘다.
        """
        let instruction = mode == .companion
            ? baseInstruction + "\n\n" + Self.companionLookupSuffix
            : baseInstruction

        var parts: [[String: Any]] = []
        if !trimmedQuery.isEmpty { parts.append(["text": "인물 또는 참고 자료: \(trimmedQuery)"]) }
        if let imageBase64, let imageMimeType {
            parts.append(["text": "아래 이미지에 이 인물의 대사가 있다. 읽어서 활용한다."])
            parts.append(["inlineData": ["mimeType": imageMimeType, "data": imageBase64]])
        }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instruction]]],
            "contents": [["role": "user", "parts": parts]],
            // 이름이면 검색이, 링크가 섞여 있으면 URL 읽기가 각각 동작합니다.
            "tools": [["google_search": [:]], ["url_context": [:]]],
            "generationConfig": GeminiCachePolicy.personaStyleGeneration(bodyTokens: 4096)
        ]

        await onProgress("자료를 찾고 있습니다…")
        let result = try await streamGeminiText(body: body, apiKey: apiKey, roomId: roomId) { soFar in
            await onProgress(Self.lookupProgressLabel(soFar))
        }
        guard !result.text.isEmpty else {
            throw serviceError(geminiEmptyResponseMessage(finishReason: result.finishReason))
        }
        return Self.parsePersonaLookup(result.text, sources: result.sources)
    }

    // MARK: - 챗봇 방의 두 단계 조사

    static let companionLookupSuffix = """
    챗봇 말투를 위한 분석에서는 대표 문구를 암기시키지 않는다. 문장 구조와 리듬, 호칭, 감정 표현을 우선한다.
    표현마다 항상/자주/가끔/드물게의 빈도를 구분하고, 한 번만 나온 표현이나 중복 표본을 말버릇으로 단정하지 않는다.
    같은 시작 표현을 여러 대사에 반복해서 싣지 말고, 실제로 확인된 서로 다른 표본을 충분히 수집한다.
    """

    static let sourceDiscoveryInstruction = """
    너는 애니메이션 캐릭터 말투 조사의 원출처 탐색기다. 특정 작품이나 캐릭터를 우대하지 않는다.
    Google 검색 결과를 거꾸로 원출처까지 추적해 최대 8개만 고른다.

    우선순위:
    1. OFFICIAL_LOCALIZED_VIDEO: 한국 공식 배급사·제작사·방송사 영상과 공식 한국어 자막
    2. OFFICIAL_ORIGINAL_VIDEO: 원 제작사·공식 작품 채널의 원어 영상
    3. OFFICIAL_TEXT: 공식 사이트·출판물·대본·인터뷰
    4. REPUTABLE_SECONDARY: 신뢰 가능한 언론·데이터베이스의 직접 인용
    5. UNVERIFIED: 위키·커뮤니티·밈·원출처 불명 문구

    채널명에 '공식'이 있다는 이유만으로 공식 등급을 주지 말고 소유자·배급권 근거를 확인한다.
    동명이인, 작품·시즌·극장판/TV판, 더빙·자막 판본을 구분한다.
    공식 자료가 있으면 위키나 밈을 대사 증거로 채우지 않는다.

    아래 형식만 출력한다. 각 필드는 실제 탭 문자로 나눈다.
    [확신도] 높음/보통/낮음 - 한 줄 근거
    [출처]
    등급<TAB>전체 URL<TAB>게시자<TAB>제목<TAB>언어<TAB>판본<TAB>공식성 근거<TAB>영상 길이(초, 아니거나 모르면 빈칸)
    """

    static let evidenceExtractionInstruction = """
    너는 공식 자료에서 캐릭터의 실제 발화만 옮기는 증거 추출기다.
    목표는 서로 다른 대사 \(PersonaSourcePipeline.collectionTarget)개, 최대 \(PersonaSourcePipeline.collectionLimit)개이며 공식 자료가 부족하면 개수를 지어내지 않는다.

    - 영상에서는 지정된 인물이 실제로 말한 문장만 고르고 화자가 불명확하면 제외한다.
    - 한국 공식 영상은 음성을 새로 번역하지 말고 화면의 공식 한국어 자막을 최우선으로 읽는다.
    - 자막과 음성이 충돌하면 화면 자막을 보존한다.
    - 밈, 댓글, 요약문, 팬 번역, 다른 인물의 말은 실제 대사로 넣지 않는다.
    - 같은 자막 조각은 논리적인 한 발화로 합치고, 공백·문장부호만 다른 중복은 하나만 둔다.
    - 평상시·질문·동의·거절·장난·친밀함·분노·당황 등 서로 다른 상황을 넓게 고른다.

    아래 형식만 출력한다. 각 필드는 실제 탭 문자로 나누고 대사 안의 탭과 줄바꿈은 공백으로 바꾼다.
    [확신도] 높음/보통/낮음 - 한 줄 근거
    [대사]
    MM:SS<TAB>상황 태그<TAB>화자<TAB>대사 원문<TAB>출처 전체 URL<TAB>출처 제목<TAB>출처 등급<TAB>판본<TAB>언어<TAB>추출 확신도
    """

    /// 원출처를 먼저 찾고(1단계), 그 출처에서만 실제 대사를 뽑은 뒤(2단계), 그 대사로 규칙을 만듭니다.
    ///
    /// 한 번에 찾게 하면 위키·밈 문구가 대사로 섞이고, 같은 대표 문구가 여러 번 들어가
    /// 챗봇이 그 말버릇만 되풀이합니다. 폰 `lookupCompanionPersona`와 같은 흐름입니다.
    /// 출처나 대사를 확인하지 못하면 규칙을 만들지 않고 빈 결과를 돌려줍니다 — 기존 말투는 그대로 둡니다.
    private func lookupCompanionPersona(
        query: String,
        roomId: UUID,
        apiKey: String,
        onProgress: @Sendable @escaping (String) async -> Void
    ) async throws -> PersonaLookup {
        typealias Pipeline = PersonaSourcePipeline

        await onProgress("공식 출처를 찾고 있습니다…")
        let discoveryBody: [String: Any] = [
            "systemInstruction": ["parts": [["text": Self.sourceDiscoveryInstruction]]],
            "contents": [["role": "user", "parts": [["text": "조사할 인물 또는 참고 자료: \(query)"]]]],
            "tools": [["google_search": [:]], ["url_context": [:]]],
            "generationConfig": GeminiCachePolicy.personaStyleGeneration(bodyTokens: 3072)
        ]
        let discovery = try await postGemini(body: discoveryBody, apiKey: apiKey, roomId: roomId)
        let discoveryText = ((discovery["candidates"] as? [[String: Any]])?.first)
            .map(Self.candidateText) ?? ""
        let sources = Pipeline.parseSources(discoveryText)
        guard !sources.isEmpty else {
            return PersonaLookup(
                confidence: "낮음",
                note: "검증 가능한 원출처를 찾지 못했습니다. 기존 말투는 바꾸지 않습니다.",
                samples: [], styleGuide: "", sources: []
            )
        }

        // 공식 영상·공식 문서가 있으면 그중 가장 좋은 등급만 봅니다.
        let extractionSources: [Pipeline.SourceCandidate]
        if let best = sources.map(\.tier.priority).min(), best <= 2 {
            extractionSources = Array(sources.filter { $0.tier.priority == best }.prefix(8))
        } else {
            let verified = sources.filter { $0.tier != .unverified }
            extractionSources = Array((verified.isEmpty ? sources : verified).prefix(8))
        }
        await onProgress(Pipeline.videoUrls(extractionSources).isEmpty
            ? "공식 문서에서 대사를 확인하고 있습니다…"
            : "공식 영상 자막을 읽고 있습니다…")

        func extract(_ forSources: [Pipeline.SourceCandidate]) async throws -> TextStreamResult {
            var body: [String: Any] = [
                "systemInstruction": ["parts": [["text": Self.evidenceExtractionInstruction]]],
                "contents": [["role": "user", "parts": Pipeline.extractionParts(sources: forSources, query: query)]],
                "generationConfig": GeminiCachePolicy.personaStyleGeneration(bodyTokens: Self.geminiMaxOutputTokens)
            ]
            // 유튜브는 영상으로 넘기므로 URL 읽기가 필요 없습니다.
            if forSources.contains(where: { !$0.isYouTube }) {
                body["tools"] = [["url_context": [:]]]
            }
            return try await streamGeminiText(body: body, apiKey: apiKey, roomId: roomId) { soFar in
                await onProgress(Self.lookupProgressLabel(soFar))
            }
        }

        var textSources = extractionSources.filter { !$0.isYouTube }
        if textSources.isEmpty {
            textSources = Array(sources.filter {
                !$0.isYouTube && $0.tier.priority <= PersonaSourceTier.officialText.priority
            }.prefix(8))
        }
        var usedSources = extractionSources
        var extraction: TextStreamResult
        do {
            extraction = try await extract(usedSources)
        } catch {
            // 영상을 못 읽으면 공식 문서로 한 번 더 해 봅니다.
            if textSources.isEmpty || error is CancellationError { throw error }
            await onProgress("영상 대신 공식 문서를 확인하고 있습니다…")
            usedSources = textSources
            extraction = try await extract(usedSources)
        }

        func parsedEvidence() -> [PersonaSampleEvidence] {
            let accessible = Set(Pipeline.videoUrls(usedSources))
                .union(usedSources.filter { !$0.isYouTube }.map(\.url))
            return Pipeline.selectEvidence(Pipeline.parseEvidence(
                extraction.text, allowedSourceUrls: accessible, sourceCandidates: usedSources))
        }
        var evidence = parsedEvidence()
        if evidence.isEmpty && usedSources.contains(where: \.isYouTube) && !textSources.isEmpty {
            await onProgress("영상에서 대사를 확인하지 못해 공식 문서를 확인하고 있습니다…")
            usedSources = textSources
            extraction = try await extract(usedSources)
            evidence = parsedEvidence()
        }
        guard !evidence.isEmpty else {
            return PersonaLookup(
                confidence: "낮음",
                note: "원출처에서 해당 인물의 대사를 확인하지 못했습니다. 기존 말투는 바꾸지 않습니다.",
                samples: [], styleGuide: "",
                sources: Self.orderedUnique(usedSources.map(\.url))
            )
        }

        await onProgress("확인한 \(evidence.count)줄로 말투 규칙을 만들고 있습니다…")
        let guide = try await analyzePersonaStyle(
            roomId: roomId, description: query, samples: evidence.map(\.text),
            mode: .companion, evidence: evidence)

        let confidenceLine = extraction.text.components(separatedBy: .newlines)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[확신도]") } ?? ""
        let afterMark = confidenceLine.components(separatedBy: "[확신도]").dropFirst().joined(separator: "[확신도]")
            .trimmingCharacters(in: .whitespaces)
        let confidence = ["높음", "보통", "낮음"].first { afterMark.hasPrefix($0) } ?? "보통"
        let note = confidenceLine.range(of: confidence)
            .map { String(confidenceLine[$0.upperBound...]) }?
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—·")) ?? ""
        return PersonaLookup(
            confidence: confidence,
            note: note.trimmingCharacters(in: .whitespaces).isEmpty
                ? "원출처가 연결된 대사 \(evidence.count)줄을 확인했습니다." : note,
            samples: evidence.map(\.text),
            styleGuide: guide,
            sources: Self.orderedUnique(evidence.map(\.sourceUrl).filter { !$0.isEmpty }),
            evidence: evidence
        )
    }

    static func candidateText(_ candidate: [String: Any]) -> String {
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    struct TextStreamResult {
        let text: String
        let finishReason: String?
        let sources: [String]
    }

    /// 글 하나를 흘려 받습니다. 대화용 스트림과 달리 말풍선으로 가르지 않습니다.
    ///
    /// 지금은 말투 조사만 씁니다. 오래 걸리는 요청이라, 다 받을 때까지 기다리는 대신
    /// 도착하는 대로 넘겨 화면이 무엇을 하고 있는지 보여줄 수 있게 합니다.
    ///
    /// 예전에는 3.7로 고정되어 있었습니다. 방에서 3.8을 골라도 조사는 3.7로 나가 청구됐습니다.
    /// 폰(`9e92468`)과 같이 그 방의 모델을 씁니다(`auxiliaryModel`).
    func streamGeminiText(
        body: [String: Any],
        apiKey: String,
        roomId: UUID,
        onPartial: @Sendable (String) async -> Void
    ) async throws -> TextStreamResult {
        let model = await auxiliaryModel(for: roomId)
        guard let url = URL(string:
            "\(Self.geminiBaseURL)/models/\(model.rawValue):streamGenerateContent?alt=sse") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var text = ""
        var finishReason: String?
        var sources: [String] = []
        var reported: [String: Any] = [:]
        var serverResponded = false

        // 여기서도 빠져나가는 모든 길에서 적습니다. 도중에 끊겨도 서버는 이미 읽었습니다.
        defer {
            let snapshot = reported
            let responded = serverResponded
            Task {
                if !snapshot.isEmpty {
                    await self.recordGeminiUsage(snapshot, roomId: roomId, model: model)
                } else if responded {
                    await self.recordUnreported(roomId: roomId, model: model)
                }
            }
        }

        let (bytes, response) = try await resilientSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw serviceError("Gemini 응답을 읽을 수 없습니다.")
        }
        guard (200...299).contains(http.statusCode) else {
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            _ = try validatedJSON(data: raw, response: response, provider: "Gemini")
            throw serviceError(
                "Gemini 요청이 \(http.statusCode) 상태로 끝났습니다.",
                retryable: AIServiceError.retryable(http.statusCode)
            )
        }

        serverResponded = true
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let usage = json["usageMetadata"] as? [String: Any] { reported = usage }
            guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { continue }
            if let reason = candidate["finishReason"] as? String { finishReason = reason }
            if let grounding = candidate["groundingMetadata"] as? [String: Any],
               let chunks = grounding["groundingChunks"] as? [[String: Any]] {
                for chunk in chunks {
                    guard let title = (chunk["web"] as? [String: Any])?["title"] as? String,
                          !title.isEmpty, !sources.contains(title) else { continue }
                    sources.append(title)
                }
            }

            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            let piece = parts.compactMap { $0["text"] as? String }.joined()
            guard !piece.isEmpty else { continue }
            text += piece
            await onPartial(text)
        }

        return TextStreamResult(text: text, finishReason: finishReason, sources: sources.sorted())
    }

    /// 지금까지 도착한 글을 보고 무슨 일을 하고 있는지 한 줄로 옮깁니다.
    ///
    /// **진행률을 흉내 내지 않습니다.** 이 요청은 오래 걸리는데(검색 → 읽기 → 정리)
    /// 예전에는 "찾는 중" 한 줄만 떠서, 멈춘 것인지 되고 있는 것인지 알 수 없었습니다.
    ///
    /// 답변은 [확신도] → [대사] → [말투] 순서로 나오도록 지침에 적혀 있습니다.
    /// 마지막으로 열린 절이 곧 지금 하고 있는 일입니다. 대사는 몇 줄까지 왔는지
    /// 함께 셉니다 — 숫자가 늘어나는 것이 보여야 멈춘 것이 아님을 알 수 있습니다.
    /// 시간을 재서 지어낸 단계가 아니라 방금 받은 글자가 근거입니다.
    static func lookupProgressLabel(_ soFar: String) -> String {
        if soFar.contains("[말투]") { return "말투 규칙을 적고 있습니다…" }
        if soFar.contains("[대사]") {
            let section = soFar.components(separatedBy: "[대사]").dropFirst().joined()
                .components(separatedBy: "[말투]").first ?? ""
            let lines = section.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            return lines == 0 ? "대사를 모으고 있습니다…" : "대사를 모으고 있습니다… \(lines)줄"
        }
        if soFar.contains("[확신도]") { return "찾은 자료를 살펴보고 있습니다…" }
        return "자료를 찾고 있습니다…"
    }

    static func parsePersonaLookup(_ text: String, sources: [String]) -> PersonaLookup {
        var confidence = "보통"
        var note = ""
        var samples: [String] = []
        var guideLines: [String] = []

        enum Section { case none, samples, guide }
        var section = Section.none

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[확신도]") {
                let body = line.replacingOccurrences(of: "[확신도]", with: "").trimmingCharacters(in: .whitespaces)
                for level in ["높음", "보통", "낮음"] where body.hasPrefix(level) {
                    confidence = level
                    note = body.dropFirst(level.count)
                        .trimmingCharacters(in: CharacterSet(charactersIn: " -–—()·,"))
                    break
                }
                if note.isEmpty { note = body }
                section = .none
                continue
            }
            if line.hasPrefix("[대사]") { section = .samples; continue }
            if line.hasPrefix("[말투]") { section = .guide; continue }
            if line.isEmpty { continue }

            switch section {
            case .samples:
                let cleaned = line
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))
                    .trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty { samples.append(cleaned) }
            case .guide:
                guideLines.append(line)
            case .none:
                break
            }
        }

        return PersonaLookup(
            confidence: confidence,
            note: note,
            samples: samples,
            styleGuide: guideLines.joined(separator: "\n"),
            sources: Array(Set(sources)).sorted()
        )
    }

    /// 미리보기에서 던져볼 상황들입니다.
    ///
    /// 모드마다 다르게 묻습니다. 챗봇 방에 "미분이 뭐야"를 던져 놓고 결을 판단할 수는 없습니다.
    /// 멘토는 설명·지적·칭찬에서, 챗봇은 인사·감정·거리감에서 말투가 가장 크게 갈립니다.
    public static func previewPrompts(for mode: ChatMode) -> [(situation: String, message: String)] {
        switch mode {
        case .mathMentor:
            return [
                ("설명할 때", "미분이 뭔지 한두 문장으로 짧게 설명해줘."),
                ("틀렸다고 말할 때", "x²의 미분은 2라고 배웠어. 맞지?"),
                ("칭찬할 때", "고마워! 덕분에 이해했어.")
            ]
        case .companion:
            return [
                ("말 걸었을 때", "야, 뭐해?"),
                ("속마음을 물을 때", "너는 나를 어떻게 생각해?"),
                ("기분이 안 좋을 때", "오늘 진짜 최악이었어. 아무것도 하기 싫다.")
            ]
        }
    }

    /// 저장하기 전에 이 말투가 실제 그 캐릭터 같은지 확인할 수 있도록 짧은 답변을 만듭니다.
    /// 실제 대화와 똑같은 시스템 지침을 쓰므로, 여기서 보이는 결이 채팅방에서도 그대로 나옵니다.
    public func previewPersona(
        roomId: UUID,
        persona: PersonaStyle,
        botName: String,
        message: String,
        mode: ChatMode = .mathMentor
    ) async throws -> String {
        guard let apiKey = KeychainStore.geminiAPIKey else {
            throw serviceError("설정에서 Gemini API 키를 먼저 등록해주세요.")
        }
        var enabled = persona
        enabled.isEnabled = true
        let system = systemPrompt(botName: botName, persona: enabled, mode: mode)

        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": message]]]],
            "generationConfig": [
                "maxOutputTokens": 2048,
                "thinkingConfig": ["thinkingLevel": "low"]
            ]
        ]
        // 미리보기도 실제 대화와 같은 조건이어야 결을 판단할 수 있습니다.
        // 챗봇 방은 대화에서 필터를 내리는데 미리보기만 안 내리면, 여기서만 답이
        // 통째로 잘려 나가고 사용자는 말투가 잘못된 줄 압니다.
        if let safety = mode.geminiSafetySettings { body["safetySettings"] = safety }

        let json = try await postGemini(body: body, apiKey: apiKey, roomId: roomId)
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first,
              let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
            throw serviceError("미리보기를 읽을 수 없습니다.")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw serviceError(geminiEmptyResponseMessage(finishReason: candidate["finishReason"] as? String))
        }
        return text
    }

    /// 뽑아낸 말투 규칙을 사용자의 요청대로 손봅니다.
    ///
    /// 자동 추출은 관찰된 사실만 담기 때문에, 실제로 쓰다 보면
    /// "좀 더 딱딱하게", "이모지 빼줘", "존댓말로 바꿔줘" 같은 조정이 필요합니다.
    /// 원래 규칙을 통째로 다시 쓰지 않고 요청한 부분만 반영합니다.
    public func refinePersonaStyle(
        roomId: UUID,
        currentGuide: String,
        instruction: String,
        description: String,
        samples: [String]
    ) async throws -> String {
        guard let apiKey = KeychainStore.geminiAPIKey else {
            throw serviceError("설정에서 Gemini API 키를 먼저 등록해주세요.")
        }
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            throw serviceError("어떻게 고칠지 입력해주세요.")
        }
        let trimmedGuide = currentGuide.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuide.isEmpty else {
            throw serviceError("먼저 말투 규칙을 만들어주세요.")
        }

        let instructionPrompt = """
        너는 말투 규칙 편집자다. 주어진 말투 규칙을 사용자의 요청대로 고친다.

        규칙:
        - 요청과 관련된 항목만 고치고 나머지는 원래 문장을 그대로 둔다.
        - 원래와 같은 '- 항목: 내용' 목록 형식을 유지한다. 항목 이름을 바꾸지 않는다.
        - 요청이 기존 관찰과 충돌하면 요청을 따른다. 사용자가 원하는 방향이 우선이다.
        - 요청에 없는 내용을 새로 지어내지 않는다.
        - 마지막 '- 한 줄 요약:' 항목도 바뀐 내용에 맞게 갱신한다.

        설명이나 인사말 없이 고친 목록만 출력한다.
        """

        var userText = "현재 말투 규칙:\n\(trimmedGuide)\n\n"
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDescription.isEmpty { userText += "인물: \(trimmedDescription)\n\n" }
        if !samples.isEmpty {
            userText += "참고용 실제 대사:\n" + samples.prefix(20).joined(separator: "\n") + "\n\n"
        }
        userText += "고쳐줬으면 하는 방향:\n\(trimmedInstruction)"

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instructionPrompt]]],
            "contents": [["role": "user", "parts": [["text": userText]]]],
            // 말투를 다듬는 것은 판단이 들어가는 작업입니다 — 다만 그 판단이 예산을 다 쓰면
            // 교정 결과가 아예 안 나옵니다(`GeminiCachePolicy.personaStyleGeneration`).
            "generationConfig": GeminiCachePolicy.personaStyleGeneration(bodyTokens: 2560)
        ]
        let json = try await postGemini(body: body, apiKey: apiKey, roomId: roomId)
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first,
              let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
            throw serviceError("교정 결과를 읽을 수 없습니다.")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw serviceError(geminiEmptyResponseMessage(finishReason: candidate["finishReason"] as? String))
        }
        return text
    }

    /// 붙여넣은 대사에서 말투 규칙을 뽑아냅니다.
    ///
    /// 모델에게 "이 캐릭터처럼 말해"라고만 하면 흉내가 흐려집니다.
    /// 관찰 가능한 항목(문장 끝맺음, 호칭, 자주 쓰는 어휘, 문장 길이 등)을 짚어서 적게 하면
    /// 이후 대화에서 재현이 훨씬 안정적입니다.
    ///
    /// 챗봇 방은 대사를 먼저 추립니다. 거의 같은 대사가 여럿이면 그 말버릇이 규칙에서
    /// 부풀려지므로, 하나로 합치고 서로 다른 상황의 대사를 고릅니다(폰과 같습니다).
    /// 조사에서 확인한 출처가 있으면 등급·상황·중복 수를 함께 넘깁니다.
    public func analyzePersonaStyle(
        roomId: UUID,
        description: String,
        samples: [String],
        mode: ChatMode = .mathMentor,
        evidence: [PersonaSampleEvidence] = []
    ) async throws -> String {
        guard let apiKey = KeychainStore.geminiAPIKey else {
            throw serviceError("설정에서 Gemini API 키를 먼저 등록해주세요.")
        }
        typealias Pipeline = PersonaSourcePipeline
        let companion = mode == .companion
        let cleanedSamples: [String]
        if companion {
            let linked = Pipeline.reconcile(samples: samples, evidence: evidence)
            cleanedSamples = linked.isEmpty
                ? Pipeline.selectEvidence(samples.map { PersonaSampleEvidence(text: $0) },
                                          limit: Pipeline.analysisLimit).map(\.text)
                : Pipeline.selectAnalysisEvidence(linked).map(\.text)
        } else {
            cleanedSamples = samples
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let joined = cleanedSamples.joined(separator: "\n")
        guard !joined.isEmpty else {
            throw serviceError("말투를 분석할 대사를 먼저 입력해주세요.")
        }

        let instruction = companion ? Self.companionAnalyzeInstruction : """
        너는 말투 분석가다. 아래 대사를 읽고, 다른 사람이 이 인물의 말투를 그대로 재현할 수 있도록
        관찰된 특징만 한국어로 정리한다. 대사에 없는 특징은 지어내지 않는다.

        다음 항목을 각각 한 줄씩, '- 항목: 내용' 형태로 쓴다. 해당 없으면 그 줄은 생략한다.
        - 문장 끝맺음: 자주 쓰는 어미와 종결 형태를 실제 예와 함께
        - 높임 수준: 반말/존댓말/혼용 중 무엇이며 어떤 상황에서 바뀌는지
        - 1인칭과 호칭: 자기를 뭐라 부르고 상대를 뭐라 부르는지
        - 자주 쓰는 표현: 반복되는 단어·감탄사·말버릇을 원문 그대로
        - 문장 길이와 리듬: 짧게 끊는지 길게 이어붙이는지
        - 감정 표현: 이모지·물결·느낌표 사용 습관
        - 피해야 할 것: 이 인물이 절대 쓰지 않을 법한 말투

        마지막에 '- 한 줄 요약:'으로 전체를 한 문장으로 압축한다.
        설명이나 인사말 없이 목록만 출력한다.
        """

        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instruction]]],
            // 설명과 예시에서 말투를 뽑아내는 분석 작업입니다.
            // 예전의 2,048 + `high`는 사고만으로 예산이 찼습니다(`GeminiCachePolicy.personaStyleGeneration`).
            "generationConfig": GeminiCachePolicy.personaStyleGeneration(bodyTokens: 2048)
        ]
        var userText = ""
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDescription.isEmpty { userText += "인물 설명: \(trimmedDescription)\n\n" }
        userText += "대사:\n\(joined)"
        if companion && !evidence.isEmpty {
            let selected = Pipeline.selectAnalysisEvidence(
                Pipeline.reconcile(samples: cleanedSamples, evidence: evidence))
            userText += "\n\n표본 근거(등급 / 상황 / 유사표본 수 / 판본 / 출처):\n" + selected.map {
                [$0.sourceTier.rawValue,
                 $0.contextTag.isEmpty ? "미상" : $0.contextTag,
                 String($0.similarSampleCount),
                 $0.edition.isEmpty ? "미상" : $0.edition,
                 $0.sourceUrl].joined(separator: " / ")
            }.joined(separator: "\n")
        }
        body["contents"] = [["role": "user", "parts": [["text": userText]]]]

        let json = try await postGemini(body: body, apiKey: apiKey, roomId: roomId)
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first,
              let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
            throw serviceError("말투 분석 결과를 읽을 수 없습니다.")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw serviceError(geminiEmptyResponseMessage(finishReason: candidate["finishReason"] as? String))
        }
        return text
    }

    /// 챗봇 방의 말투 분석 지침입니다. 폰 `ANALYZE_INSTRUCTION`과 같습니다.
    /// 대표 문구보다 문장 구조와 리듬을 앞에 두고, 빈도를 근거와 함께 적게 합니다.
    static let companionAnalyzeInstruction = """
    너는 말투 분석가다. 아래 대사를 읽고, 다른 사람이 이 인물의 말투를 그대로 재현할 수 있도록
    관찰된 특징만 한국어로 정리한다. 대사에 없는 특징은 지어내지 않는다.

    다음 항목을 각각 한 줄씩, '- 항목: 내용' 형태로 쓴다. 해당 없으면 그 줄은 생략한다.
    - 문장 끝맺음: 항상/자주/가끔/드물게 중 빈도와 함께, 어미와 종결 형태를 실제 예와 함께
    - 높임 수준: 반말/존댓말/혼용 중 무엇이며 어떤 상황에서 바뀌는지
    - 1인칭과 호칭: 자기를 뭐라 부르고 상대를 뭐라 부르는지
    - 표현 빈도: 항상/자주/가끔/드물게로 구분하고, 표본에 한 번만 나온 것을 말버릇으로 단정하지 않기
    - 표본 중복: 같은 내용이 반복된 표본은 하나로 보고, 중복이 특징의 빈도를 부풀리지 않기
    - 문장 구조와 리듬: 절과 문장 길이, 끊는 위치, 반복되는 구조를 우선해 설명하기
    - 감정 표현: 이모지·물결·느낌표 사용 습관과 강도
    - 피해야 할 것: 이 인물이 절대 쓰지 않을 법한 말투

    마지막에 '- 한 줄 요약:'으로 전체를 한 문장으로 압축한다.
    빈도 판정은 관찰 횟수/관련 표본 수와 서로 다른 상황 수를 함께 쓴다. '항상'은 관련 표본 전부와 3개 이상 상황에서
    일관될 때만, '자주'는 절반 이상이면서 3개 이상 상황일 때만 쓴다. 한 상황에서만 보이면 '드물게'로 적는다.
    대표 문구 자체보다 문장 구조·호흡·리듬, 호칭·높임 전환, 감정별 표현 강도를 앞에 둔다.
    설명이나 인사말 없이 목록만 출력한다.
    """
}
