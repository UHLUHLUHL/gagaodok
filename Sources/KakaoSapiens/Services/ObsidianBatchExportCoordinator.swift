import SwiftUI

@MainActor
public final class ObsidianBatchExportCoordinator: ObservableObject {
    public enum Phase: Equatable { case scanning, selecting, preparing, ready, saving, saved, failed }
    public enum AttachedCommandUse: String, CaseIterable, Identifiable {
        case reference = "선별 참고자료로 사용"
        case newCandidate = "새 문제 후보로 추가"
        public var id: String { rawValue }
    }
    public struct DraftItem: Identifiable {
        public let candidate: ObsidianBatchCandidate
        public var draft: ObsidianNoteDraft
        public var png: Data?
        public var visuals: [ObsidianGeneratedVisual]
        public var selectedVisualIDs: Set<String>
        public var visualsStale: Bool
        public var visualWarning: String?
        public var id: String { candidate.id }
    }

    @Published public private(set) var phase: Phase = .scanning
    @Published public private(set) var candidates: [ObsidianBatchCandidate] = []
    @Published public var selectedIDs: Set<String> = []
    @Published public private(set) var drafts: [DraftItem] = []
    @Published public var attachmentUse: AttachedCommandUse = .reference
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var progressText = "대화를 살펴보는 중…"
    @Published public private(set) var savedURLs: [URL] = []
    @Published public private(set) var skippedDuplicates = 0

    private var messages: [ChatMessage] = []
    private var roomID = UUID()
    private var roomName = ""
    private var model: AIModel = .gemini37Flash
    private var criterion = "헷갈린 문제들"
    private var commandAttachment: ChatAttachment?
    private var fullCandidate: ProblemEpisodeCandidate?
    private var task: Task<Void, Never>?
    private var cardTasks: [String: Task<Void, Never>] = [:]
    private static let cachePrefix = "obsidian.batch.scan."

    public var hasCommandAttachment: Bool { commandAttachment != nil }

    public func begin(messages: [ChatMessage], roomID: UUID, roomName: String, model: AIModel,
                      criterion: String, commandAttachment: ChatAttachment?) {
        task?.cancel(); self.messages = messages; self.roomID = roomID; self.roomName = roomName
        self.model = model; self.criterion = criterion; self.commandAttachment = commandAttachment
        candidates = []; selectedIDs = []; drafts = []; savedURLs = []; skippedDuplicates = 0
        phase = .scanning; errorMessage = nil
        task = Task { @MainActor [weak self] in await self?.scan() }
    }

    public func close() { task?.cancel(); cardTasks.values.forEach { $0.cancel() }; task = nil; cardTasks = [:] }
    public func retry() { phase = .scanning; errorMessage = nil; task = Task { @MainActor [weak self] in await self?.scan() } }
    public func toggle(_ id: String) { if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) } }

    public func prepareSelected() {
        guard !selectedIDs.isEmpty else { errorMessage = "정리할 문제를 하나 이상 선택해주세요."; return }
        phase = .preparing; errorMessage = nil
        task = Task { @MainActor [weak self] in await self?.prepare() }
    }

    public func updateDraft(id: String, keyPath: WritableKeyPath<ObsidianNoteDraft, String>, value: String) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let oldTitle = drafts[index].draft.title, oldProblem = drafts[index].draft.problem
        drafts[index].draft[keyPath: keyPath] = value
        if oldTitle != drafts[index].draft.title || oldProblem != drafts[index].draft.problem {
            drafts[index].visualsStale = !drafts[index].draft.preparedNote.visuals.isEmpty
            drafts[index].png = nil
            let title = drafts[index].draft.title, problem = drafts[index].draft.problem
            cardTasks[id]?.cancel()
            cardTasks[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, let self else { return }
                let png = try? await ObsidianProblemCardRenderer.shared.render(title: title, problem: problem)
                guard !Task.isCancelled, let latest = self.drafts.firstIndex(where: { $0.id == id }),
                      self.drafts[latest].draft.title == title, self.drafts[latest].draft.problem == problem else { return }
                self.drafts[latest].png = png
            }
        }
    }

    public func toggleVisual(draftID: String, visualID: String) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        if drafts[index].selectedVisualIDs.contains(visualID) {
            drafts[index].selectedVisualIDs.remove(visualID)
        } else {
            drafts[index].selectedVisualIDs.insert(visualID)
        }
    }

    public func saveAll() {
        guard let fullCandidate else { return }
        phase = .saving; errorMessage = nil; savedURLs = []; skippedDuplicates = 0
        for item in drafts {
            do {
                let range = item.candidate.startTurn...item.candidate.endTurn
                let unrelated = Set(item.candidate.unrelatedTurns)
                let episodeID = fullCandidate.episodeID(in: range, excluding: unrelated)
                let attachmentItems = fullCandidate.attachments(in: range, excluding: unrelated).map {
                    ObsidianAttachmentItem(turn: $0.turn, messageID: $0.messageID, attachment: $0.attachment)
                }
                let metadata = ObsidianNoteMetadata(roomID: roomID, roomName: roomName, modelName: model.displayName,
                    startTurn: range.lowerBound, endTurn: range.upperBound,
                    messageIDs: fullCandidate.messageIDs(in: range, excluding: unrelated), episodeID: episodeID)
                let attachmentPaths = ObsidianVaultManager.shared.attachmentPaths(for: attachmentItems)
                let cardPath = item.png == nil ? nil : ObsidianVaultManager.shared.problemCardPath(episodeID: episodeID)
                let selectedVisuals = item.visuals.filter { item.selectedVisualIDs.contains($0.id) }
                let visualReferences = selectedVisuals.map { visual in
                    ObsidianVisualReference(
                        id: visual.id,
                        title: visual.title,
                        caption: visual.caption,
                        path: ObsidianVaultManager.shared.visualPath(episodeID: episodeID, visualID: visual.id)
                    )
                }
                let markdown = ObsidianMarkdownFormatter.render(note: item.draft.preparedNote, metadata: metadata,
                    attachmentPaths: attachmentPaths, problemCardPath: cardPath,
                    visualAttachments: visualReferences)
                switch try ObsidianVaultManager.shared.save(markdown: markdown, title: item.draft.title,
                    episodeID: episodeID, attachments: attachmentItems, problemCardPNG: item.png,
                    generatedVisuals: selectedVisuals, overwriteExisting: false) {
                case .written(let url): savedURLs.append(url)
                case .duplicate: skippedDuplicates += 1
                }
            } catch { errorMessage = (errorMessage.map { $0 + "\n" } ?? "") + "\(item.draft.title): \(error.localizedDescription)" }
        }
        phase = .saved
    }

    private func scan() async {
        do {
            var source = messages
            if let commandAttachment, attachmentUse == .newCandidate {
                source.append(ChatMessage(sender: .user, text: "첨부된 새 문제", attachment: commandAttachment, turnId: UUID(), canonicalText: "첨부된 새 문제"))
                source.append(ChatMessage(sender: .sapiens, text: "내보내기용 첨부 문제", turnId: UUID(), canonicalText: "내보내기용 첨부 문제"))
            }
            let built = try ProblemEpisodeCandidate.buildEntireRoom(roomID: roomID, messages: source)
            fullCandidate = built
            let reference = commandAttachment.map { " 첨부 참고자료: \($0.fileName), \($0.mimeType)." } ?? ""
            let effectiveCriterion = criterion + (attachmentUse == .reference ? reference : "")
            let lastID = source.last?.id ?? roomID
            let cacheKey = Self.cachePrefix + ObsidianBatchCacheKey.make(
                roomID: roomID, lastMessageID: lastID, model: model, criterion: effectiveCriterion
            )
            let found: [ObsidianBatchCandidate]
            if let data = UserDefaults.standard.data(forKey: cacheKey),
               let cached = try? JSONDecoder().decode([ObsidianBatchCandidate].self, from: data) {
                found = cached
            } else {
                found = try await GeminiService.shared.scanObsidianProblemEpisodes(candidate: built,
                    criterion: effectiveCriterion, model: model, roomId: roomID)
                if let data = try? JSONEncoder().encode(found) { UserDefaults.standard.set(data, forKey: cacheKey) }
            }
            try Task.checkCancellation()
            candidates = found
            selectedIDs = Set(found.filter { $0.score >= 0.65 }.map(\.id))
            phase = .selecting
        } catch is CancellationError { return }
        catch { phase = .failed; errorMessage = error.localizedDescription }
    }

    private func prepare() async {
        guard let fullCandidate else { return }
        drafts = []
        let chosen = candidates.filter { selectedIDs.contains($0.id) }
        do {
            for (offset, candidate) in chosen.enumerated() {
                progressText = "\(offset + 1)/\(chosen.count) · \(candidate.title) 정리 중"
                let range = candidate.startTurn...candidate.endTurn
                let note = try await GeminiService.shared.prepareObsidianNote(candidate: fullCandidate, range: range,
                    unrelatedTurns: Set(candidate.unrelatedTurns), model: model, roomId: roomID)
                var png: Data?
                do { png = try await ObsidianProblemCardRenderer.shared.render(title: note.title, problem: note.problem) } catch { png = nil }
                var visuals: [ObsidianGeneratedVisual] = []
                var visualErrors: [String] = []
                for spec in note.visuals {
                    do {
                        let data = try await MathVisualRenderer.shared.render(spec: spec)
                        visuals.append(ObsidianGeneratedVisual(spec: spec, data: data))
                    } catch {
                        visualErrors.append("\(spec.title): \(error.localizedDescription)")
                    }
                }
                drafts.append(DraftItem(
                    candidate: candidate,
                    draft: ObsidianNoteDraft(prepared: note),
                    png: png,
                    visuals: visuals,
                    selectedVisualIDs: Set(visuals.map(\.id)),
                    visualsStale: false,
                    visualWarning: visualErrors.isEmpty ? nil : visualErrors.joined(separator: "\n")
                ))
            }
            phase = .ready
        } catch is CancellationError { return }
        catch { phase = drafts.isEmpty ? .failed : .ready; errorMessage = error.localizedDescription }
    }
}
