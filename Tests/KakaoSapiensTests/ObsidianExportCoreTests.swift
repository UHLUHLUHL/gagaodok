import Foundation

@main
struct ObsidianExportCoreTests {
    static func main() throws {
        try testCandidateEndsAtSelectedSplitAssistantTurnAndUsesCanonicalText()
        try testCandidateKeepsAtMostSixtyUserTurnsEndingAtSelection()
        try testTranscriptHasTurnNumbersAndAttachmentMetadataWithoutBinaryPayload()
        try testObsidianMarkdownUsesPropertiesWikiEmbedsAndMathJaxDelimiters()
        try testObsidianV2OnlyExposesTagsAndKeepsEpisodeIDHidden()
        try testObsidianDraftRoundTripsPreparedSections()
        try testLegacyGeneratedNoteCanBeMigratedWithoutTouchingItsSolution()
        testMigratorRejectsUserNotesAndAlreadyMigratedNotes()
        testMathNormalizerDoesNotRewriteCodeFences()
        try testAIResponseParserAcceptsFencedJSON()
        try testEpisodeIDIsStableForSameMessages()
        try testVaultLocatorPrefersOpenVaultWithGagaodokFolder()
        testObsidianOpenURIEncodesAbsolutePath()
        try testWriterFindsSameEpisodeAndOnlyOverwritesWhenRequested()
        try testWriterFindsV2HiddenEpisodeMarker()
        try testStructuredOutputConfigsRequireProviderSchemas()
        print("ObsidianExportCoreTests passed")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func fail(_ message: String) -> Never {
        fatalError(message)
    }

    static func testCandidateEndsAtSelectedSplitAssistantTurnAndUsesCanonicalText() throws {
        let roomID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let firstTurnID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let finalTurnID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let selectedID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        let messages = [
            ChatMessage(sender: .user, text: "첫 문제"),
            ChatMessage(sender: .sapiens, text: "첫 답", turnId: firstTurnID, canonicalText: "첫 답 전체"),
            ChatMessage(sender: .user, text: "그런데 이 조건은 왜 필요해?"),
            ChatMessage(sender: .sapiens, text: "화면 첫 문단", turnId: finalTurnID, canonicalText: "분할 전 최종 답변 전체"),
            ChatMessage(id: selectedID, sender: .sapiens, text: "화면 둘째 문단", turnId: finalTurnID)
        ]

        let candidate = try ProblemEpisodeCandidate.build(
            roomID: roomID,
            messages: messages,
            endingAt: selectedID
        )

        check(candidate.endpointTurn == 2, "선택한 응답의 사용자 턴을 끝점으로 잡아야 합니다.")
        check(candidate.turns.map(\.number) == [1, 2], "끝점 이전 논리 턴을 순서대로 보존해야 합니다.")
        check(candidate.turns.last?.assistantText == "분할 전 최종 답변 전체", "분할 전 원문을 우선해야 합니다.")
        check(candidate.turns.last?.messageIDs.count == 3, "사용자 질문과 분할 답변 ID를 모두 보존해야 합니다.")
    }

    static func testCandidateKeepsAtMostSixtyUserTurnsEndingAtSelection() throws {
        var messages: [ChatMessage] = []
        var finalAssistantID = UUID()
        for number in 1...70 {
            messages.append(ChatMessage(sender: .user, text: "문제 \(number)"))
            finalAssistantID = UUID()
            messages.append(ChatMessage(id: finalAssistantID, sender: .sapiens, text: "답 \(number)", turnId: UUID()))
        }

        let candidate = try ProblemEpisodeCandidate.build(
            roomID: UUID(),
            messages: messages,
            endingAt: finalAssistantID
        )

        check(candidate.turns.count == 70, "수동 범위 보정을 위해 로컬 원문 전체를 보존해야 합니다.")
        check(candidate.automaticTurns.count == 60, "자동 탐색 후보만 최대 60턴이어야 합니다.")
        check(candidate.automaticTurns.first?.number == 11, "70턴의 자동 탐색 범위는 11턴부터여야 합니다.")
        check(candidate.turns.last?.number == 70, "선택한 70턴을 포함해야 합니다.")
        check(candidate.initialWindow.map(\.number) == Array(59...70), "첫 판정은 최근 12턴이어야 합니다.")
    }

    static func testTranscriptHasTurnNumbersAndAttachmentMetadataWithoutBinaryPayload() throws {
        let attachment = ChatAttachment(
            type: .image,
            fileName: "문제 사진.png",
            fileSize: 4,
            fileExtension: "png",
            dataBase64: "QUJDRA==",
            mimeType: "image/png"
        )
        let user = ChatMessage(sender: .user, text: "이 문제를 풀어줘", attachment: attachment)
        let assistant = ChatMessage(sender: .sapiens, text: "풀이", turnId: UUID())
        let candidate = try ProblemEpisodeCandidate.build(
            roomID: UUID(),
            messages: [user, assistant],
            endingAt: assistant.id
        )

        let transcript = candidate.transcript(in: 1...1)

        check(transcript.contains("[1턴] 학습자: 이 문제를 풀어줘"), "학습자 턴 번호가 필요합니다.")
        check(transcript.contains("[첨부이미지: 문제 사진.png]"), "판정용 입력에는 첨부 메타데이터가 필요합니다.")
        check(transcript.contains("[1턴] 멘토: 풀이"), "멘토 답변도 같은 턴 번호로 포함해야 합니다.")
        check(!transcript.contains("QUJDRA=="), "범위 판정에 바이너리 payload를 넣으면 안 됩니다.")
    }

    static func testObsidianMarkdownUsesPropertiesWikiEmbedsAndMathJaxDelimiters() throws {
        let note = PreparedObsidianNote(
            title: "역함수의 이계도함수",
            problem: "\\[ (f^{-1})''(y) = ? \\]",
            givens: ["$f(x)=y$"],
            ideas: ["역함수를 직접 미분한다. — 42턴"],
            confusions: ["분모 지수를 2로 착각했지만 3이 맞다. — 45턴"],
            solution: "\\(g=f^{-1}\\)라 두고 계산한다.",
            answer: "\\[ -\\frac{f''(x)}{[f'(x)]^3} \\]",
            concepts: ["역함수 미분법"],
            unresolved: [],
            evidenceTurns: [42, 45, 48],
            coverage: [
                TurnCoverage(turn: 42, status: .included, reason: "문제 제시"),
                TurnCoverage(turn: 43, status: .unrelated, reason: "무관한 잡담")
            ]
        )
        let metadata = ObsidianNoteMetadata(
            roomID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            roomName: "수학과외쌤",
            modelName: "Gemini 3.7 Flash",
            startTurn: 42,
            endTurn: 48,
            messageIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000000042")!],
            episodeID: "episode-42-48",
            createdAt: Date(timeIntervalSince1970: 1_776_297_600)
        )

        let markdown = ObsidianMarkdownFormatter.render(
            note: note,
            metadata: metadata,
            attachmentPaths: ["가가오독/attachments/problem-42.png"]
        )

        check(markdown.hasPrefix("---\n"), "Properties는 파일 첫 줄에서 시작해야 합니다.")
        check(markdown.contains("tags:\n  - 가가오독\n  - 수학문제"), "tags는 Obsidian 리스트 property여야 합니다.")
        check(markdown.contains("<!-- gagaodok-export: {\"version\":2,\"episode_id\":\"episode-42-48\"} -->"), "중복 검사용 episode ID는 숨은 메타데이터여야 합니다.")
        check(!markdown.contains("source_turns:"), "턴 범위를 Obsidian Properties에 노출하면 안 됩니다.")
        check(markdown.contains("![[attachments/problem-42.png]]"), "Vault 내부 첨부는 상대 Wikilink embed여야 합니다.")
        check(markdown.contains("$$\n (f^{-1})''(y) = ? \n$$"), "블록 수식은 MathJax 구분자를 써야 합니다.")
        check(markdown.contains("$g=f^{-1}$"), "인라인 수식은 dollar 구분자를 써야 합니다.")
        check(!markdown.contains("\\["), "Obsidian 출력에 bracket 블록 구분자를 남기면 안 됩니다.")
        check(!markdown.contains("\\("), "Obsidian 출력에 parenthesis 인라인 구분자를 남기면 안 됩니다.")
    }

    static func testObsidianV2OnlyExposesTagsAndKeepsEpisodeIDHidden() throws {
        let metadata = ObsidianNoteMetadata(
            roomID: UUID(), roomName: "수학과외쌤", modelName: "Gemini",
            startTurn: 3, endTurn: 7, messageIDs: [UUID()], episodeID: "episode-hidden"
        )

        let header = ObsidianMarkdownFormatter.renderFrontmatter(metadata: metadata)

        check(header == """
        ---
        tags:
          - 가가오독
          - 수학문제
        ---
        <!-- gagaodok-export: {\"version\":2,\"episode_id\":\"episode-hidden\"} -->
        """, "Properties에는 tags만 있고 내부 식별자는 HTML 주석에 있어야 합니다.")
        for forbidden in ["created:", "room:", "model:", "room_id:", "source_turns:", "source_message_ids:"] {
            check(!header.contains(forbidden), "불필요한 property \(forbidden)를 노출하면 안 됩니다.")
        }
        check(ObsidianInternalMetadata.parse(from: header)?.episodeID == "episode-hidden", "숨은 episode ID를 다시 읽을 수 있어야 합니다.")
    }

    static func testObsidianDraftRoundTripsPreparedSections() throws {
        let prepared = PreparedObsidianNote(
            title: "제목", problem: "$x$를 구하시오.", givens: ["$x>0$"], ideas: ["치환"],
            confusions: ["부호 교정"], solution: "계산한다.", answer: "$x=1$", concepts: ["치환"],
            unresolved: ["추가 확인"], evidenceTurns: [1],
            coverage: [TurnCoverage(turn: 1, status: .included, reason: "문제")]
        )

        var draft = ObsidianNoteDraft(prepared: prepared)
        draft.problem = "$y$를 구하시오."
        draft.givensText = "$y>0$\n정수"
        let rebuilt = draft.preparedNote

        check(rebuilt.problem == "$y$를 구하시오.", "문제 편집이 준비된 노트에 반영되어야 합니다.")
        check(rebuilt.givens == ["$y>0$", "정수"], "줄 단위 조건 편집을 배열로 복원해야 합니다.")
        check(rebuilt.coverage == prepared.coverage, "사용자에게 노출하지 않은 근거 상태는 보존해야 합니다.")
    }

    static func testLegacyGeneratedNoteCanBeMigratedWithoutTouchingItsSolution() throws {
        let legacy = """
        ---
        tags:
          - 가가오독
          - 수학문제
        created: 2026-08-19T08:01:55Z
        room: "수학과외쌤"
        episode_id: "legacy-episode"
        source_message_ids:
          - "message-id"
        ---

        # 역삼각함수 그래프

        ## 문제

        다음 함수의 그래프를 그리시오.
        $$y=\\arcsin(\\sin x)$$

        ## 최종 해설

        이 해설은 그대로 보존한다.
        """

        guard let candidate = ObsidianGeneratedNoteMigrator.inspect(markdown: legacy) else {
            fail("가가오독 legacy 노트를 인식해야 합니다.")
        }
        check(candidate.title == "역삼각함수 그래프", "기존 제목을 추출해야 합니다.")
        check(candidate.problem.contains("\\arcsin"), "문제 LaTeX를 원형대로 추출해야 합니다.")

        let migrated = candidate.renderMigratedMarkdown(problemCardPath: "attachments/problem-legacy-episode.png")
        check(migrated.hasPrefix("---\ntags:\n  - 가가오독\n  - 수학문제\n---\n"), "새 Properties는 tags만 남겨야 합니다.")
        check(migrated.contains("![[attachments/problem-legacy-episode.png]]"), "생성 문제 카드를 임베드해야 합니다.")
        check(migrated.contains("> [!abstract]- 문제 원문 보기"), "문제 원문은 접힌 callout에 보존해야 합니다.")
        check(migrated.contains("> $$y=\\arcsin(\\sin x)$$"), "callout 안에서도 LaTeX 원문을 보존해야 합니다.")
        check(migrated.contains("이 해설은 그대로 보존한다."), "문제 뒤의 사용자 내용은 바꾸면 안 됩니다.")
        check(!migrated.contains("source_message_ids:"), "legacy 내부 속성은 제거해야 합니다.")
    }

    static func testMigratorRejectsUserNotesAndAlreadyMigratedNotes() {
        let userNote = "---\ntags:\n  - 가가오독\n  - 수학문제\n---\n# 내가 쓴 노트\n\n## 문제\n본문"
        let migrated = "---\ntags:\n  - 가가오독\n  - 수학문제\n---\n<!-- gagaodok-export: {\"version\":2,\"episode_id\":\"done\"} -->\n# 완료"

        check(ObsidianGeneratedNoteMigrator.inspect(markdown: userNote) == nil, "episode ID가 없는 사용자 노트는 건드리면 안 됩니다.")
        check(ObsidianGeneratedNoteMigrator.inspect(markdown: migrated) == nil, "이미 v2인 노트는 다시 변환하면 안 됩니다.")
    }

    static func testMathNormalizerDoesNotRewriteCodeFences() {
        let source = """
        \\(x\\)
        ```latex
        \\(keep\\)
        \\[
        keep
        \\]
        ```
        \\[y\\]
        """

        let normalized = ObsidianMarkdownFormatter.normalizeMath(source)

        check(normalized.contains("$x$"), "일반 본문의 인라인 수식을 바꿔야 합니다.")
        check(normalized.contains("\\(keep\\)"), "코드 펜스 안은 바꾸면 안 됩니다.")
        check(normalized.contains("\\[\nkeep\n\\]"), "코드 펜스 안 블록도 보존해야 합니다.")
        check(normalized.contains("$$\ny\n$$"), "일반 본문의 블록 수식을 바꿔야 합니다.")
    }

    static func testAIResponseParserAcceptsFencedJSON() throws {
        let raw = """
        정리 결과입니다.
        ```json
        {"startTurn":42,"endTurn":48,"confidence":0.91,"relatedTurns":[42,43,45,48],"unrelatedTurns":[44],"needsEarlierContext":false,"reason":"같은 역함수 문제"}
        ```
        """

        let decoded: EpisodeScopeResult = try ObsidianAIResponseParser.decode(raw)

        check(decoded.startTurn == 42, "코드 펜스 안 JSON의 시작 턴을 읽어야 합니다.")
        check(decoded.endTurn == 48, "코드 펜스 안 JSON의 끝 턴을 읽어야 합니다.")
        check(decoded.unrelatedTurns == [44], "무관한 턴 분류를 보존해야 합니다.")
    }

    static func testEpisodeIDIsStableForSameMessages() throws {
        let first = ChatMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            sender: .user,
            text: "문제"
        )
        let second = ChatMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
            sender: .sapiens,
            text: "풀이",
            turnId: UUID()
        )
        let roomID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let candidate = try ProblemEpisodeCandidate.build(
            roomID: roomID,
            messages: [first, second],
            endingAt: second.id
        )

        let one = candidate.episodeID(in: 1...1, excluding: [])
        let two = candidate.episodeID(in: 1...1, excluding: [])
        let omitted = candidate.episodeID(in: 1...1, excluding: [1])

        check(one == two, "같은 방과 메시지는 항상 같은 episode ID여야 합니다.")
        check(one != omitted, "관련 턴 구성이 달라지면 episode ID도 달라져야 합니다.")
        check(one.count == 24, "episode ID는 파일에 쓰기 좋은 고정 길이여야 합니다.")
    }

    static func testVaultLocatorPrefersOpenVaultWithGagaodokFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsidianLocatorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let closedVault = root.appendingPathComponent("닫힌 보관함", isDirectory: true)
        let openVault = root.appendingPathComponent("Obsidian Vault Google Drive", isDirectory: true)
        let exportFolder = openVault.appendingPathComponent("가가오독", isDirectory: true)
        try FileManager.default.createDirectory(at: closedVault, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "vaults": [
                "closed": ["path": closedVault.path, "ts": 20, "open": false],
                "open": ["path": openVault.path, "ts": 10, "open": true]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        let located = ObsidianVaultLocator.preferredExportFolder(
            configurationData: data,
            folderName: "가가오독",
            fileManager: .default
        )

        check(located?.standardizedFileURL == exportFolder.standardizedFileURL, "열려 있는 Vault의 가가오독 폴더를 선택해야 합니다.")
    }

    static func testObsidianOpenURIEncodesAbsolutePath() {
        let noteURL = URL(fileURLWithPath: "/tmp/Obsidian Vault/가가오독/문제 1.md")

        let uri = ObsidianVaultLocator.openURI(for: noteURL)

        check(uri?.scheme == "obsidian", "Obsidian URI scheme을 사용해야 합니다.")
        check(uri?.host == "open", "open action을 사용해야 합니다.")
        check(uri?.absoluteString.contains("path=%2Ftmp%2FObsidian%20Vault") == true, "절대 경로와 공백을 퍼센트 인코딩해야 합니다.")
    }

    static func testWriterFindsSameEpisodeAndOnlyOverwritesWhenRequested() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsidianWriterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = ObsidianNoteWriter(fileManager: .default)

        let first = try writer.write(
            markdown: "---\nepisode_id: \"same-episode\"\n---\nold",
            title: "문제/제목:1",
            episodeID: "same-episode",
            targetFolder: root,
            overwriteExisting: false
        )
        guard case .written(let firstURL) = first else {
            fail("첫 저장은 새 파일이어야 합니다.")
        }
        check(firstURL.pathExtension == "md", "노트 확장자는 md여야 합니다.")
        check(!firstURL.lastPathComponent.contains("/"), "파일명에서 경로 구분자를 제거해야 합니다.")

        let duplicate = try writer.write(
            markdown: "---\nepisode_id: \"same-episode\"\n---\nnew",
            title: "다른 제목",
            episodeID: "same-episode",
            targetFolder: root,
            overwriteExisting: false
        )
        guard case .duplicate(let duplicateURL) = duplicate else {
            fail("같은 episode는 중복으로 감지해야 합니다.")
        }
        check(duplicateURL == firstURL, "기존 episode 파일을 찾아야 합니다.")
        let oldContents = try String(contentsOf: firstURL, encoding: .utf8)
        check(oldContents.contains("old"), "확인 전에는 기존 파일을 바꾸면 안 됩니다.")

        let replaced = try writer.write(
            markdown: "---\nepisode_id: \"same-episode\"\n---\nnew",
            title: "다른 제목",
            episodeID: "same-episode",
            targetFolder: root,
            overwriteExisting: true
        )
        guard case .written(let replacedURL) = replaced else {
            fail("덮어쓰기를 선택하면 기존 파일을 갱신해야 합니다.")
        }
        check(replacedURL == firstURL, "덮어쓰기는 같은 경로를 유지해야 합니다.")
        let newContents = try String(contentsOf: firstURL, encoding: .utf8)
        check(newContents.contains("new"), "승인 후 새 내용으로 교체해야 합니다.")
    }

    static func testWriterFindsV2HiddenEpisodeMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsidianWriterV2Tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = ObsidianNoteWriter(fileManager: .default)
        let url = root.appendingPathComponent("v2.md")
        try "<!-- gagaodok-export: {\"version\":2,\"episode_id\":\"hidden-episode\"} -->\n# 문제"
            .write(to: url, atomically: true, encoding: .utf8)

        let found = try writer.existingNoteURL(episodeID: "hidden-episode", in: root)

        check(found?.standardizedFileURL == url.standardizedFileURL, "v2 숨은 메타데이터에서도 중복 episode를 찾아야 합니다.")
    }

    static func testStructuredOutputConfigsRequireProviderSchemas() throws {
        let output = ObsidianStructuredOutput.preparedNote
        let gemini = output.geminiGenerationConfig(maxOutputTokens: 5_000)
        check(gemini["responseMimeType"] as? String == "application/json", "Gemini는 JSON MIME type을 강제해야 합니다.")
        guard let geminiSchema = gemini["responseSchema"] as? [String: Any],
              let geminiRequired = geminiSchema["required"] as? [String] else {
            fail("Gemini generationConfig에 responseSchema가 필요합니다.")
        }
        check(geminiRequired.contains("coverage") && geminiRequired.contains("problem"), "노트의 필수 필드를 스키마가 강제해야 합니다.")
        check(!containsKey("additionalProperties", in: geminiSchema),
              "Gemini responseSchema는 지원하지 않는 additionalProperties를 중첩 객체에서도 제거해야 합니다.")

        let openAI = output.openAITextConfig
        check(openAI["verbosity"] as? String == "low", "정리 요청은 낮은 verbosity를 유지해야 합니다.")
        guard let format = openAI["format"] as? [String: Any] else { fail("OpenAI text.format이 필요합니다.") }
        check(format["type"] as? String == "json_schema", "OpenAI는 json_schema Structured Outputs를 사용해야 합니다.")
        check(format["strict"] as? Bool == true, "OpenAI schema는 strict 모드여야 합니다.")
        guard let openAISchema = format["schema"] as? [String: Any] else {
            fail("OpenAI에도 JSON Schema를 전달해야 합니다.")
        }
        check(containsKey("additionalProperties", in: openAISchema),
              "OpenAI strict 스키마에는 additionalProperties: false를 유지해야 합니다.")
        check(ObsidianStructuredOutput.maximumAttempts == 2, "최초 요청과 제한 재시도 1회만 허용해야 합니다.")
    }

    static func containsKey(_ key: String, in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary[key] != nil { return true }
            return dictionary.values.contains { containsKey(key, in: $0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsKey(key, in: $0) }
        }
        return false
    }
}
