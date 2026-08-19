import SwiftUI

public struct ObsidianExportSheet: View {
    @ObservedObject var coordinator: ObsidianExportCoordinator

    public init(coordinator: ObsidianExportCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.38).ignoresSafeArea().onTapGesture {
                if coordinator.phase != .saving { coordinator.close() }
            }
            VStack(spacing: 0) {
                header
                HairlineDivider()
                content
            }
            .frame(minWidth: 500, idealWidth: 620, maxWidth: 720, minHeight: 520, idealHeight: 680, maxHeight: 780)
            .background(KakaoTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 28, y: 12)
            .padding(18)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up.on.square.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.purple)
                .frame(width: 34, height: 34)
                .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text("Obsidian 문제 정리")
                    .font(.custom("Pretendard-Bold", size: 15))
                Text("여러 턴의 풀이 과정과 헷갈린 지점을 한 노트로 만듭니다")
                    .font(.custom("Pretendard-Regular", size: 10.5))
                    .foregroundColor(KakaoTheme.textSecondary)
            }
            Spacer()
            Button(action: coordinator.close) {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
                    .background(KakaoTheme.sunken, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(coordinator.phase == .saving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .detecting:
            progress(title: "문제의 시작 턴을 찾는 중…", detail: "12턴씩 역추적해 같은 문제 해결 과정을 구분하고 있습니다.")
        case .preparing:
            progress(title: "학습 노트를 정리하는 중…", detail: "아이디어, 오답과 교정, 최종 풀이를 근거 턴과 함께 구성하고 있습니다.")
        case .saving:
            progress(title: "Obsidian에 저장하는 중…", detail: "Markdown 노트와 관련 첨부를 안전하게 기록하고 있습니다.")
        case .ready:
            readyContent
        case .saved:
            savedContent
        case .failed:
            failedContent
        case .idle:
            EmptyView()
        }
    }

    private func progress(title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(title).font(.custom("Pretendard-Bold", size: 15))
            Text(detail)
                .font(.custom("Pretendard-Regular", size: 11.5))
                .foregroundColor(KakaoTheme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(30)
    }

    private var readyContent: some View {
        VStack(spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    rangeCard
                    if let warning = coordinator.scopeWarning {
                        warningCard(warning)
                    }
                    if let error = coordinator.errorMessage {
                        warningCard(error, isError: true)
                    }
                    if let duplicate = coordinator.duplicateURL {
                        duplicateCard(duplicate)
                    }

                    Text("노트 제목")
                        .font(.custom("Pretendard-Bold", size: 12))
                    TextField("문제 제목", text: Binding(
                        get: { coordinator.draftTitle },
                        set: { coordinator.updateTitle($0) }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Text("저장될 본문")
                        .font(.custom("Pretendard-Bold", size: 12))
                    TextEditor(text: $coordinator.draftBody)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 280)
                        .background(KakaoTheme.sunken, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(KakaoTheme.border))
                }
                .padding(16)
            }
            HairlineDivider()
            HStack {
                Button("취소", action: coordinator.close).buttonStyle(.bordered)
                Spacer()
                Button("이 범위로 다시 정리") { coordinator.regenerateForSelectedRange() }
                    .buttonStyle(.bordered)
                if coordinator.duplicateURL != nil {
                    Button("기존 노트 덮어쓰기") { coordinator.save(overwriteExisting: true) }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                } else {
                    Button("Obsidian에 저장") { coordinator.save() }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    private var rangeCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("포함 범위: \(coordinator.startTurn)~\(coordinator.endTurn)턴")
                    .font(.custom("Pretendard-Bold", size: 12.5))
                Spacer()
                if let confidence = coordinator.scope?.confidence {
                    Text("자동 판정 \(Int(confidence * 100))%")
                        .font(.custom("Pretendard-Medium", size: 10))
                        .foregroundColor(KakaoTheme.textSecondary)
                }
            }
            HStack(spacing: 8) {
                turnPicker("시작", selection: coordinator.startTurn, onChange: coordinator.setStartTurn)
                turnPicker("끝", selection: coordinator.endTurn, onChange: coordinator.setEndTurn)
                if let suggestion = coordinator.selectedRangeSuggestion,
                   suggestion != coordinator.selectedRange {
                    Button("선택 범위 \(suggestion.lowerBound)~\(suggestion.upperBound) 적용") {
                        coordinator.applySelectedRangeSuggestion()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if let reason = coordinator.scope?.reason, !reason.isEmpty {
                Text(reason)
                    .font(.custom("Pretendard-Regular", size: 10.5))
                    .foregroundColor(KakaoTheme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(coordinator.availableTurns.filter { coordinator.selectedRange.contains($0.number) }) { turn in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(turn.number)턴")
                            .font(.custom("Pretendard-Bold", size: 10))
                            .frame(width: 38, alignment: .trailing)
                        Text(coordinator.excerpt(for: turn).isEmpty ? "첨부 문제" : coordinator.excerpt(for: turn))
                            .font(.custom("Pretendard-Regular", size: 10.5))
                            .foregroundColor(KakaoTheme.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(9)
            .background(KakaoTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .background(KakaoTheme.sunken, in: RoundedRectangle(cornerRadius: 11))
    }

    private func turnPicker(_ label: String, selection: Int, onChange: @escaping (Int) -> Void) -> some View {
        Picker(label, selection: Binding(get: { selection }, set: onChange)) {
            ForEach(coordinator.availableTurns) { turn in
                Text("\(turn.number)턴").tag(turn.number)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 115)
    }

    private func warningCard(_ text: String, isError: Bool = false) -> some View {
        Label(text, systemImage: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .font(.custom("Pretendard-Regular", size: 10.5))
            .foregroundColor(isError ? .red : .orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((isError ? Color.red : Color.orange).opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }

    private func duplicateCard(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("같은 문제 해결 기록이 이미 있습니다.", systemImage: "doc.on.doc.fill")
                .font(.custom("Pretendard-Bold", size: 11))
            Text(url.lastPathComponent)
                .font(.custom("Pretendard-Regular", size: 10))
                .foregroundColor(KakaoTheme.textSecondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private var savedContent: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
                .foregroundColor(.green)
            Text("Obsidian에 저장했습니다")
                .font(.custom("Pretendard-Bold", size: 16))
            if let url = coordinator.savedURL {
                Text(url.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(KakaoTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            HStack {
                Button("닫기", action: coordinator.close).buttonStyle(.bordered)
                Button("Obsidian에서 열기", action: coordinator.openSavedNote)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
            }
            if let error = coordinator.errorMessage { warningCard(error, isError: true) }
            Spacer()
        }
        .padding(24)
    }

    private var failedContent: some View {
        VStack(spacing: 13) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text("문제 정리를 완료하지 못했습니다")
                .font(.custom("Pretendard-Bold", size: 15))
            Text(coordinator.errorMessage ?? "알 수 없는 오류입니다.")
                .font(.custom("Pretendard-Regular", size: 11.5))
                .foregroundColor(KakaoTheme.textSecondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("닫기", action: coordinator.close).buttonStyle(.bordered)
                Button("다시 시도", action: coordinator.retry)
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(28)
    }
}
