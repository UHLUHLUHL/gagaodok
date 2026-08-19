import SwiftUI
import AppKit

public struct ObsidianExportSheet: View {
    enum Tab: String, CaseIterable { case preview = "미리보기"; case edit = "내용 편집" }

    @ObservedObject var coordinator: ObsidianExportCoordinator
    let onClose: () -> Void
    @State private var selectedTab: Tab = .preview

    public init(coordinator: ObsidianExportCoordinator, onClose: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            HairlineDivider()
            content
        }
        .frame(minWidth: 680, idealWidth: 900, minHeight: 620, idealHeight: 780)
        .background(KakaoTheme.surface)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up.on.square.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.purple)
                .frame(width: 38, height: 38)
                .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("Obsidian 문제 정리").font(.custom("Pretendard-Bold", size: 17))
                Text(headerDetail)
                    .font(.custom("Pretendard-Regular", size: 11.5))
                    .foregroundColor(KakaoTheme.textSecondary)
            }
            Spacer()
            if coordinator.isRenderingProblemCard {
                Label("문제 이미지와 시각자료 만드는 중", systemImage: "photo.badge.arrow.down")
                    .font(.custom("Pretendard-Medium", size: 10.5))
                    .foregroundColor(KakaoTheme.textSecondary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 30, height: 30)
                    .background(KakaoTheme.sunken, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(coordinator.phase == .saving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    private var headerDetail: String {
        switch coordinator.phase {
        case .detecting: return "문제의 시작 턴을 찾고 있습니다"
        case .preparing: return "여러 턴의 풀이 과정을 학습 노트로 정리하고 있습니다"
        case .saving: return "Markdown과 첨부 이미지를 안전하게 저장하고 있습니다"
        default: return "풀이 과정과 헷갈린 지점을 확인하고 다듬어 저장합니다"
        }
    }

    @ViewBuilder private var content: some View {
        switch coordinator.phase {
        case .detecting:
            progress(title: "문제의 시작 턴을 찾는 중…", detail: "12턴씩 역추적해 같은 문제 해결 과정을 구분하고 있습니다.")
        case .preparing:
            progress(title: "학습 노트를 정리하는 중…", detail: "아이디어, 오답과 교정, 최종 풀이를 근거 턴과 함께 구성하고 있습니다.")
        case .saving:
            progress(title: "Obsidian에 저장하는 중…", detail: "문제 카드와 Markdown 노트를 원자적으로 기록하고 있습니다.")
        case .ready: readyContent
        case .saved: savedContent
        case .failed: failedContent
        case .idle: EmptyView()
        }
    }

    private func progress(title: String, detail: String) -> some View {
        VStack(spacing: 15) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(title).font(.custom("Pretendard-Bold", size: 16))
            Text(detail)
                .font(.custom("Pretendard-Regular", size: 12))
                .foregroundColor(KakaoTheme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(34)
    }

    private var readyContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                rangeCard
                if let warning = coordinator.scopeWarning { warningCard(warning) }
                if let warning = coordinator.problemCardWarning { warningCard(warning) }
                if let warning = coordinator.visualWarning { warningCard(warning) }
                if coordinator.visualsStale { warningCard("문제 본문이 수정되어 시각자료를 다시 확인해주세요.") }
                if let error = coordinator.errorMessage { warningCard(error, isError: true) }
                if let duplicate = coordinator.duplicateURL { duplicateCard(duplicate) }
                Picker("표시 방식", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)
            HairlineDivider()
            Group {
                switch selectedTab { case .preview: previewContent; case .edit: editContent }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HairlineDivider()
            footer
        }
    }

    private var previewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                if let data = coordinator.problemCardPNG, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable().scaledToFit().frame(maxWidth: 760)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(KakaoTheme.border))
                        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                        .frame(maxWidth: .infinity)
                } else if coordinator.isRenderingProblemCard {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("흰 문제 카드를 만들고 있습니다…").font(.custom("Pretendard-Regular", size: 12))
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(KakaoTheme.sunken, in: RoundedRectangle(cornerRadius: 10))
                } else if let draft = coordinator.draft {
                    previewSection("문제", markdown: draft.problem)
                }

                if let draft = coordinator.draft {
                    previewSection("핵심 조건과 주어진 정보", markdown: bulletMarkdown(draft.givensText))
                    previewSection("시도한 아이디어", markdown: bulletMarkdown(draft.ideasText))
                    previewSection("헷갈린 포인트와 교정", markdown: bulletMarkdown(draft.confusionsText))
                    previewSection("최종 해설", markdown: draft.solution)
                    previewSection("최종 답", markdown: draft.answer)
                    previewSection("알아두면 좋은 개념", markdown: bulletMarkdown(draft.conceptsText))
                    if !draft.unresolvedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        previewSection("미해결", markdown: bulletMarkdown(draft.unresolvedText), warning: true)
                    }
                }
                if !coordinator.generatedVisuals.isEmpty {
                    visualSelectionSection
                }
            }
            .frame(maxWidth: 780).frame(maxWidth: .infinity)
            .padding(.horizontal, 24).padding(.vertical, 22)
        }
        .background(KakaoTheme.sunken.opacity(0.45))
    }

    private func previewSection(_ title: String, markdown: String, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.custom("Pretendard-Bold", size: 18))
                .foregroundColor(warning ? .orange : KakaoTheme.textPrimary)
            RenderedMarkdownBlock(content: markdown)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(KakaoTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(warning ? Color.orange.opacity(0.35) : KakaoTheme.border))
    }

    private var visualSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("시각자료").font(.custom("Pretendard-Bold", size: 18))
                Spacer()
                Text("필요한 자료만 첨부").font(.custom("Pretendard-Regular", size: 11)).foregroundColor(KakaoTheme.textSecondary)
            }
            ForEach(coordinator.generatedVisuals, id: \.id) { visual in
                HStack(alignment: .top, spacing: 12) {
                    Button { coordinator.toggleVisual(visual.id) } label: {
                        Image(systemName: coordinator.selectedVisualIDs.contains(visual.id) ? "checkmark.square.fill" : "square")
                            .font(.system(size: 20)).foregroundColor(.purple)
                    }.buttonStyle(.plain)
                    if let image = NSImage(data: visual.data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 250, height: 155).background(Color.white)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(visual.title).font(.custom("Pretendard-Bold", size: 13))
                        Text(visual.caption).font(.custom("Pretendard-Regular", size: 11)).foregroundColor(KakaoTheme.textSecondary)
                        if coordinator.visualsStale {
                            Text("본문 수정 후 재검토 필요").font(.custom("Pretendard-Medium", size: 10)).foregroundColor(.orange)
                        }
                    }
                    Spacer()
                }
                .padding(12)
                .background(KakaoTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(KakaoTheme.border))
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(KakaoTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(KakaoTheme.border))
    }

    private var editContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                editField("노트 제목", keyPath: \.title, height: 34, singleLine: true)
                editField("문제", keyPath: \.problem, height: 150)
                editField("핵심 조건과 주어진 정보", keyPath: \.givensText, height: 105, hint: "한 줄에 한 항목씩 입력")
                editField("시도한 아이디어", keyPath: \.ideasText, height: 120, hint: "한 줄에 한 항목씩 입력")
                editField("헷갈린 포인트와 교정", keyPath: \.confusionsText, height: 120, hint: "오답과 올바른 해석을 함께 기록")
                editField("최종 해설", keyPath: \.solution, height: 210)
                editField("최종 답", keyPath: \.answer, height: 90)
                editField("알아두면 좋은 개념", keyPath: \.conceptsText, height: 110, hint: "한 줄에 한 항목씩 입력")
                editField("미해결", keyPath: \.unresolvedText, height: 85, hint: "완전히 결론 나지 않은 내용")
            }
            .frame(maxWidth: 780).frame(maxWidth: .infinity)
            .padding(.horizontal, 24).padding(.vertical, 22)
        }
    }

    @ViewBuilder private func editField(
        _ title: String,
        keyPath: WritableKeyPath<ObsidianNoteDraft, String>,
        height: CGFloat,
        hint: String? = nil,
        singleLine: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.custom("Pretendard-Bold", size: 12.5))
                if let hint {
                    Text(hint).font(.custom("Pretendard-Regular", size: 10)).foregroundColor(KakaoTheme.textSecondary)
                }
            }
            if singleLine {
                TextField(title, text: draftBinding(keyPath)).textFieldStyle(.roundedBorder)
            } else {
                TextEditor(text: draftBinding(keyPath))
                    .font(.system(size: 12.5)).scrollContentBackground(.hidden)
                    .padding(8).frame(height: height)
                    .background(KakaoTheme.sunken, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(KakaoTheme.border))
            }
        }
    }

    private func draftBinding(_ keyPath: WritableKeyPath<ObsidianNoteDraft, String>) -> Binding<String> {
        Binding(get: { coordinator.draft?[keyPath: keyPath] ?? "" }, set: { coordinator.updateDraft(keyPath, $0) })
    }

    private var footer: some View {
        HStack {
            Button("닫기", action: onClose).buttonStyle(.bordered)
            Spacer()
            Button("이 범위로 다시 정리") { coordinator.regenerateForSelectedRange() }.buttonStyle(.bordered)
            if coordinator.duplicateURL != nil {
                Button("기존 노트 덮어쓰기") { coordinator.save(overwriteExisting: true) }
                    .buttonStyle(.borderedProminent).tint(.purple)
                    .disabled(coordinator.isRenderingProblemCard)
            } else {
                Button("Obsidian에 저장") { coordinator.save() }
                    .buttonStyle(.borderedProminent).tint(.purple)
                    .disabled(coordinator.isRenderingProblemCard)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
    }

    private var rangeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("포함 범위: \(coordinator.startTurn)~\(coordinator.endTurn)턴").font(.custom("Pretendard-Bold", size: 13))
                Spacer()
                if let confidence = coordinator.scope?.confidence {
                    Text("자동 판정 \(Int(confidence * 100))%")
                        .font(.custom("Pretendard-Medium", size: 10.5)).foregroundColor(KakaoTheme.textSecondary)
                }
            }
            HStack(spacing: 10) {
                turnPicker("시작", selection: coordinator.startTurn, onChange: coordinator.setStartTurn)
                turnPicker("끝", selection: coordinator.endTurn, onChange: coordinator.setEndTurn)
                if let suggestion = coordinator.selectedRangeSuggestion, suggestion != coordinator.selectedRange {
                    Button("선택 범위 \(suggestion.lowerBound)~\(suggestion.upperBound) 적용") { coordinator.applySelectedRangeSuggestion() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Spacer()
            }
            if let reason = coordinator.scope?.reason, !reason.isEmpty {
                Text(reason).font(.custom("Pretendard-Regular", size: 10.5))
                    .foregroundColor(KakaoTheme.textSecondary).lineLimit(2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(coordinator.availableTurns.filter { coordinator.selectedRange.contains($0.number) }) { turn in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(turn.number)턴").font(.custom("Pretendard-Bold", size: 10))
                            Text(coordinator.excerpt(for: turn).isEmpty ? "첨부 문제" : coordinator.excerpt(for: turn))
                                .font(.custom("Pretendard-Regular", size: 10)).foregroundColor(KakaoTheme.textSecondary).lineLimit(2)
                        }
                        .padding(8).frame(width: 190, alignment: .leading)
                        .background(KakaoTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(12).background(KakaoTheme.sunken, in: RoundedRectangle(cornerRadius: 11))
    }

    private func turnPicker(_ label: String, selection: Int, onChange: @escaping (Int) -> Void) -> some View {
        Picker(label, selection: Binding(get: { selection }, set: onChange)) {
            ForEach(coordinator.availableTurns) { turn in Text("\(turn.number)턴").tag(turn.number) }
        }
        .pickerStyle(.menu).frame(width: 135)
    }

    private func warningCard(_ text: String, isError: Bool = false) -> some View {
        Label(text, systemImage: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .font(.custom("Pretendard-Regular", size: 10.5)).foregroundColor(isError ? .red : .orange)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background((isError ? Color.red : Color.orange).opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }

    private func duplicateCard(_ url: URL) -> some View {
        Label("같은 문제 해결 기록이 있습니다: \(url.lastPathComponent)", systemImage: "doc.on.doc.fill")
            .font(.custom("Pretendard-Medium", size: 10.5)).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private var savedContent: some View {
        VStack(spacing: 15) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 45)).foregroundColor(.green)
            Text("Obsidian에 저장했습니다").font(.custom("Pretendard-Bold", size: 17))
            if let url = coordinator.savedURL {
                Text(url.path).font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(KakaoTheme.textSecondary).multilineTextAlignment(.center).textSelection(.enabled)
            }
            HStack {
                Button("닫기", action: onClose).buttonStyle(.bordered)
                Button("Obsidian에서 열기", action: coordinator.openSavedNote).buttonStyle(.borderedProminent).tint(.purple)
            }
            if let error = coordinator.errorMessage { warningCard(error, isError: true) }
            Spacer()
        }
        .padding(30)
    }

    private var failedContent: some View {
        VStack(spacing: 14) {
            if coordinator.candidate != nil { rangeCard.padding(.horizontal, 18).padding(.top, 16) }
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 38)).foregroundColor(.orange)
            Text("문제 정리를 완료하지 못했습니다").font(.custom("Pretendard-Bold", size: 16))
            Text(coordinator.errorMessage ?? "알 수 없는 오류입니다.")
                .font(.custom("Pretendard-Regular", size: 12)).foregroundColor(KakaoTheme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack {
                Button("닫기", action: onClose).buttonStyle(.bordered)
                Button("다시 시도", action: coordinator.retry).buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(.bottom, 24)
    }

    private func bulletMarkdown(_ source: String) -> String {
        source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .map { $0.hasPrefix("- ") ? $0 : "- \($0)" }.joined(separator: "\n")
    }
}

struct RenderedMarkdownBlock: View {
    let content: String
    @State private var height: CGFloat = 32
    @State private var messageID = UUID()

    var body: some View {
        LaTeXMarkdownView(
            messageID: messageID,
            content: content.isEmpty ? "_내용 없음_" : content,
            isUser: false,
            dynamicHeight: $height
        )
        .frame(maxWidth: .infinity).frame(height: max(24, height))
    }
}
