import SwiftUI

@MainActor
public final class ObsidianExportCoordinator: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case detecting
        case preparing
        case ready
        case saving
        case saved
        case failed
    }

    @Published public var isPresented = false
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var candidate: ProblemEpisodeCandidate?
    @Published public private(set) var scope: EpisodeScopeResult?
    @Published public var startTurn = 1
    @Published public var endTurn = 1
    @Published public var draft: ObsidianNoteDraft?
    @Published public private(set) var preparedNote: PreparedObsidianNote?
    @Published public private(set) var problemCardPNG: Data?
    @Published public private(set) var isRenderingProblemCard = false
    @Published public private(set) var problemCardWarning: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var savedURL: URL?
    @Published public private(set) var duplicateURL: URL?
    @Published public private(set) var selectedRangeSuggestion: ClosedRange<Int>?

    private var roomID: UUID?
    private var roomName = ""
    private var model: AIModel = .gemini37Flash
    private var task: Task<Void, Never>?
    private var problemCardTask: Task<Void, Never>?
    private let vault = ObsidianVaultManager.shared

    public var selectedRange: ClosedRange<Int> { startTurn...max(startTurn, endTurn) }
    public var availableTurns: [ProblemEpisodeTurn] { candidate?.turns ?? [] }
    public var scopeWarning: String? {
        if scope?.needsEarlierContext == true {
            return "자동 탐색 한도보다 앞에서 시작한 문제일 수 있습니다. 시작 턴을 확인해주세요."
        }
        if let note = draft?.preparedNote, !note.unresolved.isEmpty {
            return "미해결 또는 근거 확인이 필요한 항목이 \(note.unresolved.count)개 있습니다. 저장 전에 본문을 확인해주세요."
        }
        return nil
    }

    public func begin(
        messages: [ChatMessage],
        endingAt message: ChatMessage,
        selectedMessageIDs: Set<UUID>,
        roomID: UUID,
        roomName: String,
        model: AIModel
    ) {
        task?.cancel()
        resetDraft()
        do {
            let candidate = try ProblemEpisodeCandidate.build(
                roomID: roomID,
                messages: messages,
                endingAt: message.id
            )
            self.candidate = candidate
            self.roomID = roomID
            self.roomName = roomName
            self.model = model
            self.startTurn = candidate.initialWindow.first?.number ?? candidate.endpointTurn
            self.endTurn = candidate.endpointTurn
            self.selectedRangeSuggestion = selectionRange(candidate: candidate, selectedIDs: selectedMessageIDs)
            self.isPresented = true
            self.phase = .detecting
            task = Task { @MainActor [weak self] in await self?.detectAndPrepare() }
        } catch {
            isPresented = true
            phase = .failed
            errorMessage = error.localizedDescription
        }
    }

    public func close() {
        task?.cancel()
        problemCardTask?.cancel()
        task = nil
        problemCardTask = nil
        isPresented = false
        phase = .idle
    }

    public func retry() {
        guard candidate != nil else { return }
        errorMessage = nil
        phase = .detecting
        task?.cancel()
        task = Task { @MainActor [weak self] in await self?.detectAndPrepare() }
    }

    public func applySelectedRangeSuggestion() {
        guard let suggestion = selectedRangeSuggestion else { return }
        startTurn = suggestion.lowerBound
        endTurn = suggestion.upperBound
    }

    public func setStartTurn(_ turn: Int) {
        guard let candidate else { return }
        startTurn = min(max(turn, candidate.availableRange.lowerBound), endTurn)
    }

    public func setEndTurn(_ turn: Int) {
        guard let candidate else { return }
        endTurn = max(min(turn, candidate.availableRange.upperBound), startTurn)
    }

    public func regenerateForSelectedRange() {
        guard candidate != nil else { return }
        errorMessage = nil
        duplicateURL = nil
        problemCardTask?.cancel()
        problemCardPNG = nil
        phase = .preparing
        task?.cancel()
        task = Task { @MainActor [weak self] in await self?.prepareCurrentRange() }
    }

    public func updateDraft<Value>(_ keyPath: WritableKeyPath<ObsidianNoteDraft, Value>, _ value: Value) {
        guard var changed = draft else { return }
        let oldTitle = changed.title
        let oldProblem = changed.problem
        changed[keyPath: keyPath] = value
        draft = changed
        if changed.title != oldTitle || changed.problem != oldProblem {
            scheduleProblemCard()
        }
    }

    public func save(overwriteExisting: Bool = false) {
        guard let candidate, let roomID, let draft else { return }
        guard !isRenderingProblemCard else {
            errorMessage = "문제 카드 미리보기를 갱신하는 중입니다. 잠시 후 다시 저장해주세요."
            return
        }
        phase = .saving
        errorMessage = nil
        do {
            let unrelated = currentUnrelatedTurns()
            let range = selectedRange
            let episodeID = candidate.episodeID(in: range, excluding: unrelated)
            let messageIDs = candidate.messageIDs(in: range, excluding: unrelated)
            let items = candidate.attachments(in: range, excluding: unrelated).map {
                ObsidianAttachmentItem(turn: $0.turn, messageID: $0.messageID, attachment: $0.attachment)
            }
            let metadata = ObsidianNoteMetadata(
                roomID: roomID,
                roomName: roomName,
                modelName: model.displayName,
                startTurn: range.lowerBound,
                endTurn: range.upperBound,
                messageIDs: messageIDs,
                episodeID: episodeID
            )
            let attachmentPaths = vault.attachmentPaths(for: items)
            let problemCardPath = problemCardPNG == nil ? nil : vault.problemCardPath(episodeID: episodeID)
            let markdown = ObsidianMarkdownFormatter.render(
                note: draft.preparedNote,
                metadata: metadata,
                attachmentPaths: attachmentPaths,
                problemCardPath: problemCardPath
            )
            let result = try vault.save(
                markdown: markdown,
                title: draft.title,
                episodeID: episodeID,
                attachments: items,
                problemCardPNG: problemCardPNG,
                overwriteExisting: overwriteExisting
            )
            switch result {
            case .duplicate(let url):
                duplicateURL = url
                phase = .ready
            case .written(let url):
                duplicateURL = nil
                savedURL = url
                phase = .saved
            }
        } catch {
            phase = .ready
            errorMessage = error.localizedDescription
        }
    }

    public func openSavedNote() {
        guard let savedURL else { return }
        if !vault.openInObsidian(savedURL) {
            errorMessage = "Obsidian을 열 수 없습니다. Obsidian이 설치되어 있는지 확인해주세요."
        }
    }

    public func excerpt(for turn: ProblemEpisodeTurn) -> String {
        let text = turn.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 90 ? String(text.prefix(90)) + "…" : text
    }

    private func detectAndPrepare() async {
        guard let candidate, let roomID else { return }
        do {
            let result = try await GeminiService.shared.detectProblemEpisode(
                candidate: candidate,
                model: model,
                roomId: roomID
            )
            try Task.checkCancellation()
            scope = result
            startTurn = result.startTurn
            endTurn = result.endTurn
            phase = .preparing
            await prepareCurrentRange()
        } catch is CancellationError {
            return
        } catch {
            // A failed regeneration must not discard or hide the last editable draft.
            phase = draft == nil ? .failed : .ready
            errorMessage = error.localizedDescription
        }
    }

    private func prepareCurrentRange() async {
        guard let candidate, let roomID else { return }
        do {
            let range = selectedRange
            let note = try await GeminiService.shared.prepareObsidianNote(
                candidate: candidate,
                range: range,
                unrelatedTurns: currentUnrelatedTurns(),
                model: model,
                roomId: roomID
            )
            try Task.checkCancellation()
            preparedNote = note
            draft = ObsidianNoteDraft(prepared: note)
            phase = .ready
            scheduleProblemCard(immediate: true)
        } catch is CancellationError {
            return
        } catch {
            // Keep the previous range and edits visible when regeneration fails.
            phase = draft == nil ? .failed : .ready
            errorMessage = error.localizedDescription
        }
    }

    private func currentUnrelatedTurns() -> Set<Int> {
        guard let scope else { return [] }
        return Set(scope.unrelatedTurns.filter { selectedRange.contains($0) })
    }

    private func selectionRange(candidate: ProblemEpisodeCandidate, selectedIDs: Set<UUID>) -> ClosedRange<Int>? {
        let selectedTurns = candidate.turns.compactMap { turn in
            turn.messageIDs.contains(where: selectedIDs.contains) ? turn.number : nil
        }
        guard let first = selectedTurns.min(), let last = selectedTurns.max() else { return nil }
        return first...last
    }

    private func resetDraft() {
        phase = .idle
        candidate = nil
        scope = nil
        draft = nil
        preparedNote = nil
        problemCardTask?.cancel()
        problemCardTask = nil
        problemCardPNG = nil
        isRenderingProblemCard = false
        problemCardWarning = nil
        errorMessage = nil
        savedURL = nil
        duplicateURL = nil
        selectedRangeSuggestion = nil
    }

    private func scheduleProblemCard(immediate: Bool = false) {
        guard let draft else { return }
        let title = draft.title
        let problem = draft.problem
        problemCardTask?.cancel()
        problemCardPNG = nil
        isRenderingProblemCard = true
        problemCardWarning = nil
        problemCardTask = Task { @MainActor [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled, let self else { return }
            do {
                let data = try await ObsidianProblemCardRenderer.shared.render(title: title, problem: problem)
                try Task.checkCancellation()
                self.problemCardPNG = data
                self.problemCardWarning = nil
            } catch is CancellationError {
                return
            } catch {
                self.problemCardPNG = nil
                self.problemCardWarning = "문제 이미지를 만들지 못해 Markdown 원문으로 저장합니다: \(error.localizedDescription)"
            }
            self.isRenderingProblemCard = false
        }
    }
}
