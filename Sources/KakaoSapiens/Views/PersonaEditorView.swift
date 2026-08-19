import SwiftUI
import AppKit

/// 방마다 다른 말투를 설정하는 화면입니다.
///
/// 말투는 "설명"보다 "실제 대사"가 훨씬 잘 먹힙니다. 그래서 대사를 모아두고,
/// Gemini가 거기서 관찰 가능한 규칙을 뽑아내면 그 규칙과 원문을 함께 들고 다닙니다.
///
/// 레이아웃 주의: 대화창은 405pt이고 최소 350pt까지 줄어듭니다.
/// 고정 폭을 쓰면 창 밖으로 잘리므로 항상 사용 가능한 폭에 맞춰 접습니다.
public struct PersonaEditorView: View {
    let roomId: UUID
    let onClose: () -> Void

    @ObservedObject private var roomManager = ChatRoomManager.shared

    @State private var description: String
    @State private var samplesText: String
    @State private var styleGuide: String
    @State private var isEnabled: Bool
    @State private var isAnalyzing = false
    @State private var status: String = ""

    @State private var lookupQuery: String = ""
    @State private var isLookingUp = false
    /// 말투 조사에서 지금 무엇이 도착했는지. 답변 글자가 근거인 값입니다.
    @State private var lookupProgress: String = ""
    @State private var lookupConfidence: String = ""
    @State private var lookupNote: String = ""
    @State private var lookupSources: [String] = []
    @State private var attachedShot: (base64: String, mime: String, name: String)?

    /// 상황별로 받아 둔 답변입니다. 누른 것만 채워집니다.
    @State private var previewAnswers: [String: String] = [:]
    /// 지금 답을 기다리는 상황. 한 번에 하나만 보냅니다.
    @State private var previewAsking: String?
    @State private var customQuestion: String = ""

    /// 직접 쓴 질문의 답을 담을 자리 이름입니다. 상황 이름과 겹치지 않게 둡니다.
    private let customSituation = "\u{0}직접"

    @State private var refineInstruction: String = ""
    @State private var isRefining = false
    @State private var guideBeforeRefine: String = ""
    @State private var canUndoRefine = false

    // 카카오톡 팔레트
    private let kakaoYellow = Color(red: 0.996, green: 0.898, blue: 0.0)
    private let pageBackground = Color(red: 0.949, green: 0.953, blue: 0.961)
    private let cardBackground = Color.white
    private let inkPrimary = KakaoTheme.textPrimary
    private let inkSecondary = KakaoTheme.textSecondary
    private let hairline = KakaoTheme.hairline

    public init(roomId: UUID, onClose: @escaping () -> Void) {
        self.roomId = roomId
        self.onClose = onClose
        let persona = ChatRoomManager.shared.getRoom(id: roomId)?.profile.persona ?? PersonaStyle()
        _description = State(initialValue: persona.description)
        _samplesText = State(initialValue: persona.samples.joined(separator: "\n"))
        _styleGuide = State(initialValue: persona.styleGuide)
        _isEnabled = State(initialValue: persona.isEnabled)
    }

    private var sampleLines: [String] {
        samplesText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public var body: some View {
        GeometryReader { geo in
            // 창이 좁아져도 잘리지 않도록 항상 남는 공간 안에서만 자랍니다.
            let sheetWidth = min(max(geo.size.width - 20, 300), 420)
            let sheetHeight = min(max(geo.size.height - 28, 360), 660)

            ZStack {
                KakaoTheme.textSecondary
                    .ignoresSafeArea()
                    .onTapGesture { save(); onClose() }

                VStack(spacing: 0) {
                    header
                    HairlineDivider()

                    ScrollView { sections }
                        .background(pageBackground)

                    HairlineDivider()
                    footer
                }
                .frame(width: sheetWidth, height: sheetHeight)
                .background(pageBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.32), radius: 22, x: 0, y: 10)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // 앱 전체가 라이트 전용이라 시스템이 다크여도 밝게 고정합니다.
        // 이게 없으면 입력란만 시스템을 따라 까맣게 나옵니다.
        
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 14) {
            applyCard
            stepLabel("1", "캐릭터 찾기")
            lookupCard
            stepLabel("2", "말투 다듬기")
            styleCard
            stepLabel("3", "확인하기")
            previewCard
            tipCard
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    // MARK: - 조각

    private func stepLabel(_ number: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Text(number)
                .font(.custom("Pretendard-Bold", size: 9.5))
                .foregroundColor(inkPrimary)
                .frame(width: 15, height: 15)
                .background(kakaoYellow, in: Circle())
            Text(title)
                .font(.custom("Pretendard-Bold", size: 11.5))
                .foregroundColor(inkSecondary)
            Spacer()
        }
        .padding(.leading, 2)
        .padding(.top, 2)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.custom("Pretendard-Regular", size: 10))
            .foregroundColor(inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 다크 모드에서 시스템 배경이 새어나오지 않도록 직접 그린 입력란입니다.
    private func inputField(_ placeholder: String, text: Binding<String>, onSubmit: (() -> Void)? = nil) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundColor(inkPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(pageBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(hairline))
            .onSubmit { onSubmit?() }
    }

    private func inputArea(text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(size: 11.5))
            .foregroundColor(inkPrimary)
            // TextEditor는 자체 배경이 있어 이걸 숨기지 않으면 다크 모드에서 까맣게 보입니다.
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(pageBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(hairline))
    }

    private func primaryButton(_ title: String, systemName: String, busy: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: systemName).font(.system(size: 10.5)) }
                Text(title).font(.custom("Pretendard-Bold", size: 11.5))
            }
            .foregroundColor(inkPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(disabled ? kakaoYellow.opacity(0.35) : kakaoYellow,
                        in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func secondaryButton(_ title: String, systemName: String, busy: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: systemName).font(.system(size: 10.5)) }
                Text(title).font(.custom("Pretendard-Medium", size: 11.5))
            }
            .foregroundColor(disabled ? inkSecondary : inkPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(pageBackground, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(hairline))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - 영역

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("말투 설정").font(.custom("Pretendard-Bold", size: 14)).foregroundColor(inkPrimary)
                Text(roomManager.getRoom(id: roomId)?.profile.name ?? "이 방")
                    .font(.custom("Pretendard-Regular", size: 10.5))
                    .foregroundColor(inkSecondary)
            }
            Spacer(minLength: 8)
            Button(action: { save(); onClose() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(inkSecondary)
                    .frame(width: 24, height: 24)
                    .background(pageBackground, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(cardBackground)
    }

    private var applyCard: some View {
        card {
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("말투 적용").font(.custom("Pretendard-Bold", size: 12.5)).foregroundColor(inkPrimary)
                    Text("끄면 기본 말투로 돌아갑니다")
                        .font(.custom("Pretendard-Regular", size: 10))
                        .foregroundColor(inkSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(kakaoYellow)
        }
    }

    private var lookupCard: some View {
        card {
            inputField("예) 짱구는 못말려의 짱구", text: $lookupQuery) { lookup() }

            HStack(spacing: 7) {
                secondaryButton(attachedShot == nil ? "사진" : "첨부됨",
                                systemName: attachedShot == nil ? "photo" : "checkmark.circle.fill",
                                busy: false, disabled: false, action: pickScreenshot)
                    .frame(width: 84)
                primaryButton(isLookingUp ? "찾는 중" : "찾기", systemName: "magnifyingglass",
                              busy: isLookingUp,
                              disabled: isLookingUp || (lookupQuery.trimmingCharacters(in: .whitespaces).isEmpty && attachedShot == nil),
                              action: lookup)
            }

            if let shot = attachedShot {
                HStack(spacing: 4) {
                    Image(systemName: "paperclip").font(.system(size: 9))
                    Text(shot.name).font(.custom("Pretendard-Regular", size: 10)).lineLimit(1).truncationMode(.middle)
                    Button(action: { attachedShot = nil }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundColor(inkSecondary)
            }

            // 검색 → 읽기 → 정리로 오래 걸리는 요청입니다. 진행률을 흉내 내지 않고,
            // 답변에 실제로 도착한 절을 그대로 보여줍니다.
            if isLookingUp, !lookupProgress.isEmpty {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 11, height: 11)
                    Text(lookupProgress)
                        .font(.custom("Pretendard-Regular", size: 10.5))
                        .foregroundColor(inkSecondary)
                }
            }

            if !lookupConfidence.isEmpty { confidenceBadge }

            hint("이름·위키 링크·대사가 담긴 사진 중 아무거나 넣으면 됩니다. 못 찾으면 지어내지 않고 알려줍니다.")
        }
    }

    private var confidenceBadge: some View {
        let color: Color = lookupConfidence == "높음"
            ? Color(red: 0.16, green: 0.62, blue: 0.35)
            : (lookupConfidence == "보통" ? Color(red: 0.85, green: 0.55, blue: 0.10)
                                          : Color(red: 0.80, green: 0.25, blue: 0.25))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text("확신도 \(lookupConfidence)")
                    .font(.custom("Pretendard-Bold", size: 10.5))
                    .foregroundColor(color)
                Spacer(minLength: 0)
            }
            if !lookupNote.isEmpty {
                Text(lookupNote)
                    .font(.custom("Pretendard-Regular", size: 10))
                    .foregroundColor(inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !lookupSources.isEmpty {
                Text("출처 " + lookupSources.prefix(3).joined(separator: ", "))
                    .font(.custom("Pretendard-Regular", size: 9.5))
                    .foregroundColor(inkSecondary.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
    }

    private var styleCard: some View {
        card {
            Text("인물").font(.custom("Pretendard-Bold", size: 11.5)).foregroundColor(inkPrimary)
            inputField("예) 무뚝뚝하지만 챙겨주는 검도부 선배", text: $description)

            HStack(spacing: 5) {
                Text("실제 대사").font(.custom("Pretendard-Bold", size: 11.5)).foregroundColor(inkPrimary)
                Spacer()
                Text("\(sampleLines.count)줄")
                    .font(.custom("Pretendard-Bold", size: 10))
                    .foregroundColor(sampleLines.count >= 12
                                     ? Color(red: 0.16, green: 0.62, blue: 0.35)
                                     : Color(red: 0.85, green: 0.55, blue: 0.10))
            }
            .padding(.top, 2)
            inputArea(text: $samplesText, height: 130)
            hint("한 줄에 하나씩. 15~20줄이면 재현이 눈에 띄게 좋아집니다.")

            secondaryButton(isAnalyzing ? "분석 중" : "이 대사로 말투 규칙 뽑기",
                            systemName: "wand.and.stars",
                            busy: isAnalyzing,
                            disabled: isAnalyzing || sampleLines.isEmpty,
                            action: analyze)

            Text("말투 규칙").font(.custom("Pretendard-Bold", size: 11.5))
                .foregroundColor(inkPrimary)
                .padding(.top, 2)
            inputArea(text: $styleGuide, height: 110)
            hint("직접 고쳐도 됩니다.")

            // 뽑아낸 규칙을 말로 손보는 자리입니다.
            // 규칙을 통째로 다시 만들지 않고 요청한 부분만 고칩니다.
            HairlineDivider().padding(.vertical, 1)
            Text("말로 교정하기").font(.custom("Pretendard-Bold", size: 11.5))
                .foregroundColor(inkPrimary)
            inputField("예) 좀 더 딱딱하게 · 이모지 빼줘 · 존댓말로", text: $refineInstruction) { refine() }
            secondaryButton(isRefining ? "고치는 중" : "이 방향으로 고치기",
                            systemName: "slider.horizontal.3",
                            busy: isRefining,
                            disabled: isRefining
                                || refineInstruction.trimmingCharacters(in: .whitespaces).isEmpty
                                || styleGuide.trimmingCharacters(in: .whitespaces).isEmpty,
                            action: refine)
            if canUndoRefine {
                Button(action: {
                    styleGuide = guideBeforeRefine
                    canUndoRefine = false
                    previewAnswers = [:]
                    status = "교정을 되돌렸습니다."
                }) {
                    Text("되돌리기")
                        .font(.custom("Pretendard-Medium", size: 10.5))
                        .foregroundColor(inkSecondary)
                }
                .buttonStyle(.plain)
            }
            hint("여러 번 이어서 고칠 수 있습니다. 고친 뒤 다시 말 시켜보세요.")
        }
    }

    /// 이 방의 모드에 맞는 미리보기 질문들입니다.
    private var previewPrompts: [(situation: String, message: String)] {
        GeminiService.previewPrompts(for: roomManager.getRoom(id: roomId)?.resolvedMode ?? .mathMentor)
    }

    private var canAsk: Bool { !(styleGuide.isEmpty && sampleLines.isEmpty) }

    private var previewCard: some View {
        card {
            if !sampleLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("원본 대사").font(.custom("Pretendard-Bold", size: 9.5)).foregroundColor(inkSecondary)
                    ForEach(sampleLines.prefix(2), id: \.self) { line in
                        Text("“\(line)”")
                            .font(.custom("Pretendard-Regular", size: 10))
                            .foregroundColor(inkSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(pageBackground, in: RoundedRectangle(cornerRadius: 8))
            }

            // **누른 것만 보냅니다.** 예전에는 열자마자 세 건을 한꺼번에 던졌습니다.
            // 하나만 보고 싶어도 셋 값을 냈고, 셋 다 장부에 안 잡혔습니다.
            hint("상황마다 따로 물어봅니다. 원본 대사와 결이 비슷하면 맞는 겁니다.")

            ForEach(previewPrompts, id: \.situation) { item in
                previewExchange(situation: item.situation, question: item.message)
            }

            HairlineDivider()

            VStack(alignment: .leading, spacing: 5) {
                Text("직접 물어보기")
                    .font(.custom("Pretendard-Bold", size: 9.5))
                    .foregroundColor(inkSecondary)
                HStack(spacing: 6) {
                    TextField("하고 싶은 말을 적으세요", text: $customQuestion)
                        .textFieldStyle(.plain)
                        .font(.custom("Pretendard-Regular", size: 11))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(pageBackground, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(hairline))
                    askButton(
                        situation: customSituation,
                        question: customQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                if let answer = previewAnswers[customSituation] {
                    HStack {
                        PersonaPreviewBubble(text: answer, background: cardBackground,
                                             border: hairline, ink: inkPrimary)
                        Spacer(minLength: 28)
                    }
                }
            }
        }
    }

    /// 한 상황에 대한 질문·답변 한 쌍입니다.
    private func previewExchange(situation: String, question: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(situation)
                    .font(.custom("Pretendard-Bold", size: 9.5))
                    .foregroundColor(inkSecondary)
                Spacer()
                askButton(situation: situation, question: question)
            }
            // 카카오톡 말풍선 배치 그대로: 내 말은 오른쪽 노랑, 상대는 왼쪽 흰색
            HStack {
                Spacer(minLength: 28)
                Text(question)
                    .font(.custom("Pretendard-Regular", size: 10.5))
                    .foregroundColor(inkPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(kakaoYellow, in: RoundedRectangle(cornerRadius: 9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let answer = previewAnswers[situation] {
                HStack {
                    // 실제 채팅방과 같은 렌더러를 씁니다.
                    // 미리보기 답변에도 수식과 마크다운이 섞여 나오므로
                    // 평범한 Text로 두면 $x^2$ 같은 원문이 그대로 보입니다.
                    PersonaPreviewBubble(text: answer,
                                         background: cardBackground,
                                         border: hairline,
                                         ink: inkPrimary)
                    Spacer(minLength: 28)
                }
            }
        }
        .padding(8)
        .background(Color(red: 0.639, green: 0.729, blue: 0.812).opacity(0.28),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func askButton(situation: String, question: String) -> some View {
        let busy = previewAsking == situation
        let disabled = !canAsk || question.isEmpty || previewAsking != nil
        return Button { ask(situation: situation, message: question) } label: {
            HStack(spacing: 4) {
                if busy {
                    ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 9, height: 9)
                } else {
                    Image(systemName: "play.fill").font(.system(size: 8))
                }
                Text(busy ? "묻는 중" : "물어보기").font(.custom("Pretendard-Medium", size: 10))
            }
            .foregroundColor(disabled ? inkSecondary : inkPrimary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(disabled ? pageBackground : kakaoYellow, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var tipCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("더 잘 맞추려면", systemImage: "lightbulb.fill")
                .font(.custom("Pretendard-Bold", size: 10.5))
                .foregroundColor(Color(red: 0.55, green: 0.42, blue: 0.0))
            ForEach([
                "대사를 다듬지 말고 원문 그대로 넣으세요.",
                "짧은 대답·긴 설명·칭찬·지적을 섞으면 재현이 안정적입니다. 20줄까지 반영됩니다.",
                "말투가 세서 설명이 흐려지면 대사 줄 수를 줄여보세요."
            ], id: \.self) { tip in
                Text("· " + tip)
                    .font(.custom("Pretendard-Regular", size: 10))
                    .foregroundColor(Color(red: 0.42, green: 0.34, blue: 0.05))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 1.0, green: 0.976, blue: 0.878), in: RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if !status.isEmpty {
                Text(status)
                    .font(.custom("Pretendard-Regular", size: 10))
                    .foregroundColor(inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(action: {
                    description = ""; samplesText = ""; styleGuide = ""; isEnabled = false
                    previewAnswers = [:]; lookupConfidence = ""; lookupNote = ""; lookupSources = []
                    status = "지웠습니다."
                }) {
                    Text("지우기")
                        .font(.custom("Pretendard-Medium", size: 11.5))
                        .foregroundColor(Color(red: 0.80, green: 0.25, blue: 0.25))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                primaryButton("저장하고 닫기", systemName: "checkmark", busy: false, disabled: false) {
                    save(); onClose()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(cardBackground)
    }

    // MARK: - 동작

    private func pickScreenshot() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let mime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
        attachedShot = (data.base64EncodedString(), mime, url.lastPathComponent)
    }

    private func lookup() {
        isLookingUp = true
        lookupProgress = "자료를 찾고 있습니다…"
        status = ""
        let query = lookupQuery
        let shot = attachedShot
        let room = roomId
        Task {
            do {
                let result = try await GeminiService.shared.lookupPersona(
                    query: query, roomId: room, imageBase64: shot?.base64, imageMimeType: shot?.mime
                ) { label in
                    await MainActor.run { lookupProgress = label }
                }
                await MainActor.run {
                    isLookingUp = false
                    lookupProgress = ""
                    lookupConfidence = result.confidence
                    lookupNote = result.note
                    lookupSources = result.sources
                    guard result.isUsable else {
                        status = "말투를 찾지 못했습니다. 대사를 직접 넣어보세요."
                        return
                    }
                    if !result.samples.isEmpty { samplesText = result.samples.joined(separator: "\n") }
                    if !result.styleGuide.isEmpty { styleGuide = result.styleGuide }
                    if description.trimmingCharacters(in: .whitespaces).isEmpty {
                        description = query.trimmingCharacters(in: .whitespaces)
                    }
                    isEnabled = true
                    previewAnswers = [:]
                    status = "찾았습니다. 말 시켜보고 확인하세요."
                }
            } catch {
                await MainActor.run {
                    isLookingUp = false
                    lookupProgress = ""
                    status = error.localizedDescription
                }
            }
        }
    }

    /// 상황 하나만 물어봅니다.
    private func ask(situation: String, message: String) {
        guard !message.isEmpty, previewAsking == nil else { return }
        previewAsking = situation
        status = ""
        let persona = PersonaStyle(
            description: description, samples: sampleLines, styleGuide: styleGuide, isEnabled: true
        )
        let botName = roomManager.getRoom(id: roomId)?.profile.name ?? "사피엔스"
        // 이 방의 모드로 미리봅니다. 챗봇 방인데 멘토 지침으로 미리보면
        // 여기서 괜찮아 보이던 말투가 실제 대화에서는 전혀 다르게 나옵니다.
        let mode = roomManager.getRoom(id: roomId)?.resolvedMode ?? .mathMentor
        let room = roomId
        Task {
            let answer: String
            do {
                answer = try await GeminiService.shared.previewPersona(
                    roomId: room, persona: persona, botName: botName, message: message, mode: mode
                )
            } catch {
                await MainActor.run {
                    previewAsking = nil
                    status = error.localizedDescription
                }
                return
            }
            await MainActor.run {
                previewAnswers[situation] = answer
                previewAsking = nil
                status = "원본 대사와 결이 비슷하면 저장하세요."
            }
        }
    }

    private func refine() {
        isRefining = true
        status = ""
        guideBeforeRefine = styleGuide
        let currentGuide = styleGuide
        let instruction = refineInstruction
        let currentDescription = description
        let currentSamples = sampleLines
        let room = roomId
        Task {
            do {
                let revised = try await GeminiService.shared.refinePersonaStyle(
                    roomId: room,
                    currentGuide: currentGuide,
                    instruction: instruction,
                    description: currentDescription,
                    samples: currentSamples
                )
                await MainActor.run {
                    styleGuide = revised
                    isRefining = false
                    canUndoRefine = true
                    refineInstruction = ""
                    previewAnswers = [:]
                    status = "고쳤습니다. 말 시켜보고 확인하세요."
                }
            } catch {
                await MainActor.run {
                    isRefining = false
                    status = error.localizedDescription
                }
            }
        }
    }

    private func analyze() {
        isAnalyzing = true
        status = ""
        let currentDescription = description
        let currentSamples = sampleLines
        let room = roomId
        Task {
            do {
                let guide = try await GeminiService.shared.analyzePersonaStyle(
                    roomId: room, description: currentDescription, samples: currentSamples
                )
                await MainActor.run {
                    styleGuide = guide
                    isEnabled = true
                    isAnalyzing = false
                    previewAnswers = [:]
                    status = "규칙을 뽑았습니다. 말 시켜보고 확인하세요."
                }
            } catch {
                await MainActor.run {
                    isAnalyzing = false
                    status = error.localizedDescription
                }
            }
        }
    }

    private func save() {
        roomManager.updateRoomPersona(
            roomId: roomId,
            persona: PersonaStyle(
                description: description,
                samples: sampleLines,
                styleGuide: styleGuide,
                isEnabled: isEnabled
            )
        )
    }
}

/// 미리보기 답변을 실제 채팅방과 같은 방식으로 그립니다.
///
/// 답변에는 `$x^2$`나 `**굵게**`가 섞여 나옵니다. 평범한 `Text`로 두면 원문이 그대로 보여서
/// 정작 확인해야 할 말투가 기호에 묻힙니다. 웹뷰는 높이가 나중에 확정되므로
/// 말풍선마다 자기 높이를 따로 들고 있습니다.
private struct PersonaPreviewBubble: View {
    let text: String
    let background: Color
    let border: Color
    let ink: Color

    @State private var height: CGFloat = 20
    @State private var messageID = UUID()

    private var looksRich: Bool {
        text.contains("$") || text.contains("**") || text.contains("\\(") || text.contains("\\[")
    }

    var body: some View {
        Group {
            if looksRich {
                LaTeXMarkdownView(messageID: messageID, content: text, isUser: false, dynamicHeight: $height)
                    .frame(height: height)
                    .frame(maxWidth: 250)
            } else {
                Text(text)
                    .font(.custom("Pretendard-Regular", size: 10.5))
                    .foregroundColor(ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(border))
    }
}
