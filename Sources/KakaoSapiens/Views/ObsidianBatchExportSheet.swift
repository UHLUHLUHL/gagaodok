import SwiftUI
import AppKit

public struct ObsidianBatchExportSheet: View {
    @ObservedObject var coordinator: ObsidianBatchExportCoordinator
    let onClose: () -> Void

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 18)).foregroundColor(.purple)
                    .frame(width: 38, height: 38).background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Obsidian 여러 문제 정리").font(.custom("Pretendard-Bold", size: 17))
                    Text("대화에서 복습할 문제를 선별한 뒤 각각 독립된 노트로 저장합니다")
                        .font(.custom("Pretendard-Regular", size: 11.5)).foregroundColor(KakaoTheme.textSecondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 30, height: 30).background(KakaoTheme.sunken, in: Circle()) }.buttonStyle(.plain)
            }.padding(.horizontal, 20).padding(.vertical, 15)
            HairlineDivider()
            content
        }
        .frame(minWidth: 680, idealWidth: 900, minHeight: 620, idealHeight: 780)
        .background(KakaoTheme.surface)
    }

    @ViewBuilder private var content: some View {
        switch coordinator.phase {
        case .scanning: progress("헷갈린 문제를 선별하는 중…", "현재 멘토방의 로컬 원문을 20턴 단위로 살펴보고 있습니다.")
        case .preparing: progress("학습 노트를 만드는 중…", coordinator.progressText)
        case .saving: progress("Obsidian에 저장하는 중…", "문제별 Markdown, PNG와 첨부를 기록하고 있습니다.")
        case .selecting: selectionView
        case .ready: draftsView
        case .saved: savedView
        case .failed: errorView
        }
    }

    private func progress(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 14) { Spacer(); ProgressView().controlSize(.large); Text(title).font(.headline); Text(detail).foregroundColor(.secondary); Spacer() }
    }

    private var selectionView: some View {
        VStack(spacing: 0) {
            if coordinator.hasCommandAttachment {
                HStack {
                    Text("명령에 첨부된 파일").font(.custom("Pretendard-Bold", size: 12))
                    Picker("첨부 사용", selection: $coordinator.attachmentUse) {
                        ForEach(ObsidianBatchExportCoordinator.AttachedCommandUse.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 390)
                    Button("다시 선별") { coordinator.retry() }.buttonStyle(.bordered)
                    Spacer()
                }.padding(14).background(KakaoTheme.sunken)
            }
            if let error = coordinator.errorMessage { warning(error) }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if coordinator.candidates.isEmpty {
                        ContentUnavailableView("선별된 문제가 없습니다", systemImage: "checkmark.circle", description: Text("범위를 바꾸거나 우클릭 단일 정리를 이용해보세요."))
                    }
                    ForEach(coordinator.candidates) { item in
                        Button { coordinator.toggle(item.id) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: coordinator.selectedIDs.contains(item.id) ? "checkmark.square.fill" : "square")
                                    .foregroundColor(coordinator.selectedIDs.contains(item.id) ? .purple : .secondary).font(.system(size: 20))
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack { Text(item.title).font(.custom("Pretendard-Bold", size: 14)); Spacer(); Text("\(item.startTurn)~\(item.endTurn)턴 · 필요도 \(Int(item.score * 100))%") .font(.caption).foregroundColor(.secondary) }
                                    Text(item.reason).font(.custom("Pretendard-Regular", size: 12)).foregroundColor(KakaoTheme.textSecondary).multilineTextAlignment(.leading)
                                }
                            }.padding(14).background(KakaoTheme.surface, in: RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).stroke(KakaoTheme.border))
                        }.buttonStyle(.plain)
                    }
                }.padding(18)
            }.background(KakaoTheme.sunken.opacity(0.45))
            HairlineDivider()
            HStack { Button("닫기", action: onClose); Spacer(); Text("\(coordinator.selectedIDs.count)개 선택").foregroundColor(.secondary); Button("선택한 문제 정리") { coordinator.prepareSelected() }.buttonStyle(.borderedProminent).tint(.purple).disabled(coordinator.selectedIDs.isEmpty) }.padding(14)
        }
    }

    private var draftsView: some View {
        VStack(spacing: 0) {
            if let error = coordinator.errorMessage { warning(error) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(coordinator.drafts) { item in
                        draftCard(item)
                    }
                }.padding(20)
            }.background(KakaoTheme.sunken.opacity(0.45))
            HairlineDivider(); HStack { Button("닫기", action: onClose); Spacer(); Button("모두 Obsidian에 저장") { coordinator.saveAll() }.buttonStyle(.borderedProminent).tint(.purple) }.padding(14)
        }
    }

    private func draftCard(_ item: ObsidianBatchExportCoordinator.DraftItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(item.candidate.startTurn)~\(item.candidate.endTurn)턴").font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            TextField("제목", text: binding(item.id, \.title)).font(.headline).textFieldStyle(.roundedBorder)
            problemPreview(item)
            DisclosureGroup("문제와 해설 편집") {
                edit("문제", item.id, \.problem, 110)
                edit("헷갈린 포인트와 교정", item.id, \.confusionsText, 110)
                edit("최종 해설", item.id, \.solution, 170)
                edit("최종 답", item.id, \.answer, 75)
            }
        }
        .padding(16)
        .background(KakaoTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(KakaoTheme.border))
    }

    @ViewBuilder private func problemPreview(_ item: ObsidianBatchExportCoordinator.DraftItem) -> some View {
        if let png = item.png, let image = NSImage(data: png) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 300)
                .frame(maxWidth: .infinity).background(Color.white)
        } else {
            RenderedMarkdownBlock(content: item.draft.problem)
        }
    }

    private func edit(_ title: String, _ id: String, _ keyPath: WritableKeyPath<ObsidianNoteDraft, String>, _ height: CGFloat) -> some View {
        VStack(alignment: .leading) { Text(title).font(.caption.bold()); TextEditor(text: binding(id, keyPath)).frame(height: height).padding(6).background(KakaoTheme.sunken, in: RoundedRectangle(cornerRadius: 8)) }.padding(.top, 8)
    }
    private func binding(_ id: String, _ keyPath: WritableKeyPath<ObsidianNoteDraft, String>) -> Binding<String> {
        Binding(get: { coordinator.drafts.first(where: { $0.id == id })?.draft[keyPath: keyPath] ?? "" }, set: { coordinator.updateDraft(id: id, keyPath: keyPath, value: $0) })
    }
    private var savedView: some View { VStack(spacing: 14) { Spacer(); Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundColor(.green); Text("\(coordinator.savedURLs.count)개 문제를 저장했습니다").font(.headline); if coordinator.skippedDuplicates > 0 { Text("기존 노트 \(coordinator.skippedDuplicates)개는 중복이라 건너뛰었습니다.").foregroundColor(.secondary) }; if let error = coordinator.errorMessage { warning(error) }; Button("닫기", action: onClose).buttonStyle(.borderedProminent); Spacer() }.padding(30) }
    private var errorView: some View { VStack(spacing: 14) { Spacer(); Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 42)).foregroundColor(.orange); Text("문제를 선별하지 못했습니다").font(.headline); Text(coordinator.errorMessage ?? "알 수 없는 오류").multilineTextAlignment(.center).foregroundColor(.secondary); HStack { Button("닫기", action: onClose); Button("다시 시도") { coordinator.retry() }.buttonStyle(.borderedProminent) }; Spacer() }.padding(30) }
    private func warning(_ text: String) -> some View { Text(text).font(.caption).foregroundColor(.orange).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.09)) }
}
