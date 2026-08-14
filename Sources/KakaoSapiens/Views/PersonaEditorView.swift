import SwiftUI
import AppKit

/// 방마다 다른 말투를 설정하는 화면입니다.
///
/// 말투는 "설명"보다 "실제 대사"가 훨씬 잘 먹힙니다. 그래서 대사를 붙여넣게 하고,
/// Gemini가 거기서 관찰 가능한 규칙을 뽑아내면 그 규칙과 원문을 함께 들고 다닙니다.
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

    // 이름·링크로 찾아오기
    @State private var lookupQuery: String = ""
    @State private var isLookingUp = false
    @State private var lookupConfidence: String = ""
    @State private var lookupNote: String = ""
    @State private var lookupSources: [String] = []
    @State private var attachedShot: (base64: String, mime: String, name: String)?

    // 저장 전 확인용 미리보기
    @State private var isPreviewing = false
    @State private var previews: [(situation: String, question: String, answer: String)] = []

    private let accent = Color(red: 0.996, green: 0.902, blue: 0.0)

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
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { save(); onClose() }

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        toggleRow
                        lookupSection
                        Divider()
                        characterField
                        samplesField
                        analyzeRow
                        styleGuideField
                        previewSection
                        tipBox
                    }
                    .padding(16)
                }

                Divider()
                footer
            }
            .frame(width: 460, height: 620)
            .background(Color(red: 0.98, green: 0.98, blue: 0.985))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("말투 설정").font(.custom("Pretendard-Bold", size: 15))
                Text("이 방에서만 적용됩니다").font(.custom("Pretendard-Regular", size: 11))
                    .foregroundColor(.black.opacity(0.5))
            }
            Spacer()
            Button(action: { save(); onClose() }) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                    .foregroundColor(.black.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Color.white)
    }

    private var toggleRow: some View {
        Toggle(isOn: $isEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("말투 적용").font(.custom("Pretendard-Bold", size: 12.5))
                Text("끄면 기본 말투로 돌아갑니다").font(.custom("Pretendard-Regular", size: 10.5))
                    .foregroundColor(.black.opacity(0.5))
            }
        }
        .toggleStyle(.switch)
        .tint(accent)
    }

    /// 대사를 외우고 있지 않아도 되도록, 이름이나 링크만으로 찾아옵니다.
    private var lookupSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("캐릭터로 찾기").font(.custom("Pretendard-Bold", size: 12))

            HStack(spacing: 7) {
                TextField("예) 짱구는 못말려의 짱구 · 위키 링크도 가능", text: $lookupQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
                    .onSubmit { lookup() }

                Button(action: pickScreenshot) {
                    Image(systemName: attachedShot == nil ? "photo" : "photo.fill")
                        .font(.system(size: 12))
                        .foregroundColor(attachedShot == nil ? .black.opacity(0.55) : .green)
                        .frame(width: 28, height: 24)
                        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("대사가 담긴 스크린샷 첨부")

                Button(action: lookup) {
                    HStack(spacing: 5) {
                        if isLookingUp { ProgressView().controlSize(.small) }
                        else { Image(systemName: "magnifyingglass").font(.system(size: 11)) }
                        Text(isLookingUp ? "찾는 중" : "찾기").font(.custom("Pretendard-Medium", size: 11.5))
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Color(red: 0.22, green: 0.22, blue: 0.22), in: RoundedRectangle(cornerRadius: 7))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(isLookingUp || (lookupQuery.trimmingCharacters(in: .whitespaces).isEmpty && attachedShot == nil))
            }

            if let shot = attachedShot {
                HStack(spacing: 5) {
                    Image(systemName: "paperclip").font(.system(size: 9))
                    Text(shot.name).font(.custom("Pretendard-Regular", size: 10)).lineLimit(1)
                    Button(action: { attachedShot = nil }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundColor(.black.opacity(0.5))
            }

            if !lookupConfidence.isEmpty {
                confidenceBadge
            }

            Text("이름만 넣으면 검색해서 실제 대사를 찾아옵니다. 못 찾으면 지어내지 않고 알려줍니다.")
                .font(.custom("Pretendard-Regular", size: 10))
                .foregroundColor(.black.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var confidenceBadge: some View {
        let color: Color = lookupConfidence == "높음" ? .green
            : (lookupConfidence == "보통" ? .orange : .red)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text("확신도 \(lookupConfidence)").font(.custom("Pretendard-Bold", size: 11))
                Text(lookupNote)
                    .font(.custom("Pretendard-Regular", size: 10.5))
                    .foregroundColor(.black.opacity(0.55))
                    .lineLimit(2)
            }
            if !lookupSources.isEmpty {
                Text("출처: " + lookupSources.prefix(4).joined(separator: ", "))
                    .font(.custom("Pretendard-Regular", size: 9.5))
                    .foregroundColor(.black.opacity(0.4))
                    .lineLimit(2)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 채팅방에 들어가기 전에 결이 맞는지 확인하는 자리입니다.
    /// 실제 대화와 같은 지침으로 답을 만들기 때문에, 여기서 보이는 말투가 그대로 나옵니다.
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("말투 확인").font(.custom("Pretendard-Bold", size: 12))
                Spacer()
                Button(action: runPreview) {
                    HStack(spacing: 5) {
                        if isPreviewing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "play.circle").font(.system(size: 11)) }
                        Text(isPreviewing ? "시연 중" : "말 시켜보기")
                            .font(.custom("Pretendard-Medium", size: 11.5))
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(accent, in: RoundedRectangle(cornerRadius: 7))
                    .foregroundColor(.black)
                }
                .buttonStyle(.plain)
                .disabled(isPreviewing || (styleGuide.isEmpty && sampleLines.isEmpty))
            }

            if !sampleLines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("원본 대사 (비교용)").font(.custom("Pretendard-Bold", size: 10))
                        .foregroundColor(.black.opacity(0.45))
                    ForEach(sampleLines.prefix(3), id: \.self) { line in
                        Text("“\(line)”")
                            .font(.custom("Pretendard-Regular", size: 10.5))
                            .foregroundColor(.black.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }

            if previews.isEmpty {
                Text("세 가지 상황으로 답을 만들어 보여줍니다. 원본 대사와 결이 비슷하면 맞는 겁니다.")
                    .font(.custom("Pretendard-Regular", size: 10))
                    .foregroundColor(.black.opacity(0.45))
            } else {
                ForEach(previews, id: \.situation) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.situation)
                            .font(.custom("Pretendard-Bold", size: 10))
                            .foregroundColor(.black.opacity(0.45))
                        HStack {
                            Spacer(minLength: 40)
                            Text(item.question)
                                .font(.custom("Pretendard-Regular", size: 11))
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(accent, in: RoundedRectangle(cornerRadius: 9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Text(item.answer)
                                .font(.custom("Pretendard-Regular", size: 11))
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.08)))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 40)
                        }
                    }
                    .padding(9)
                    .background(Color(red: 0.79, green: 0.85, blue: 0.92).opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var characterField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("인물").font(.custom("Pretendard-Bold", size: 12))
            TextField("예) 무뚝뚝하지만 챙겨주는 검도부 선배", text: $description)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
            Text("이름만 적기보다 성격과 관계를 함께 적으면 훨씬 잘 맞습니다.")
                .font(.custom("Pretendard-Regular", size: 10))
                .foregroundColor(.black.opacity(0.45))
        }
    }

    private var samplesField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("실제 대사").font(.custom("Pretendard-Bold", size: 12))
                Spacer()
                Text("\(sampleLines.count)줄")
                    .font(.custom("Pretendard-Regular", size: 10.5))
                    .foregroundColor(sampleLines.count >= 5 ? .green : .orange)
            }
            TextEditor(text: $samplesText)
                .font(.system(size: 11.5))
                .frame(height: 120)
                .padding(4)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.15)))
            Text("한 줄에 대사 하나씩. 이 기능의 정확도는 여기에 달려 있습니다. 8~12줄을 권장합니다.")
                .font(.custom("Pretendard-Regular", size: 10))
                .foregroundColor(.black.opacity(0.45))
        }
    }

    private var analyzeRow: some View {
        HStack(spacing: 10) {
            Button(action: analyze) {
                HStack(spacing: 6) {
                    if isAnalyzing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars").font(.system(size: 11))
                    }
                    Text(isAnalyzing ? "분석 중…" : "Gemini로 말투 분석")
                        .font(.custom("Pretendard-Medium", size: 12))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(red: 0.22, green: 0.22, blue: 0.22), in: RoundedRectangle(cornerRadius: 8))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .disabled(isAnalyzing || sampleLines.isEmpty)
            .opacity(sampleLines.isEmpty ? 0.45 : 1)

            Text(status)
                .font(.custom("Pretendard-Regular", size: 10.5))
                .foregroundColor(.black.opacity(0.55))
                .lineLimit(2)
        }
    }

    private var styleGuideField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("말투 규칙").font(.custom("Pretendard-Bold", size: 12))
            TextEditor(text: $styleGuide)
                .font(.system(size: 11.5))
                .frame(height: 150)
                .padding(4)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.15)))
            Text("분석 결과가 여기 들어옵니다. 직접 고쳐도 되고, 처음부터 직접 써도 됩니다.")
                .font(.custom("Pretendard-Regular", size: 10))
                .foregroundColor(.black.opacity(0.45))
        }
    }

    private var tipBox: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("더 잘 맞추려면", systemImage: "lightbulb.fill")
                .font(.custom("Pretendard-Bold", size: 11.5))
                .foregroundColor(Color(red: 0.62, green: 0.45, blue: 0.0))
            ForEach([
                "설명보다 대사가 강합니다. 문장을 다듬지 말고 원문 그대로 넣으세요.",
                "짧은 대답, 긴 설명, 칭찬, 지적처럼 상황이 다른 대사를 섞으면 재현이 안정적입니다.",
                "말투가 세면 수학 설명이 흐려질 수 있습니다. 이상하면 대사 줄 수를 줄여보세요."
            ], id: \.self) { tip in
                Text("• " + tip)
                    .font(.custom("Pretendard-Regular", size: 10.5))
                    .foregroundColor(.black.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 1.0, green: 0.975, blue: 0.86), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            Button("말투 지우기") {
                description = ""; samplesText = ""; styleGuide = ""; isEnabled = false
                status = "지웠습니다."
            }
            .buttonStyle(.plain)
            .font(.custom("Pretendard-Regular", size: 11.5))
            .foregroundColor(.red.opacity(0.8))

            Spacer()

            Button(action: { save(); onClose() }) {
                Text("저장하고 닫기")
                    .font(.custom("Pretendard-Bold", size: 12))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(accent, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundColor(.black)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color.white)
    }

    private func pickScreenshot() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.lowercased()
        let mime = (ext == "png") ? "image/png" : "image/jpeg"
        attachedShot = (data.base64EncodedString(), mime, url.lastPathComponent)
    }

    private func lookup() {
        isLookingUp = true
        status = ""
        let query = lookupQuery
        let shot = attachedShot
        Task {
            do {
                let result = try await GeminiService.shared.lookupPersona(
                    query: query, imageBase64: shot?.base64, imageMimeType: shot?.mime
                )
                await MainActor.run {
                    isLookingUp = false
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
                    previews = []
                    status = "찾았습니다. 아래에서 말 시켜보고 확인하세요."
                }
            } catch {
                await MainActor.run {
                    isLookingUp = false
                    status = error.localizedDescription
                }
            }
        }
    }

    private func runPreview() {
        isPreviewing = true
        previews = []
        status = ""
        let persona = PersonaStyle(
            description: description, samples: sampleLines, styleGuide: styleGuide, isEnabled: true
        )
        let botName = roomManager.getRoom(id: roomId)?.profile.name ?? "사피엔스"
        Task {
            // 세 상황을 동시에 물어 대기 시간을 한 번으로 줄입니다.
            let results = await withTaskGroup(of: (Int, String, String, String).self) { group in
                for (index, prompt) in GeminiService.personaPreviewPrompts.enumerated() {
                    group.addTask {
                        let answer = (try? await GeminiService.shared.previewPersona(
                            persona: persona, botName: botName, message: prompt.message
                        )) ?? "(불러오지 못했습니다)"
                        return (index, prompt.situation, prompt.message, answer)
                    }
                }
                var collected: [(Int, String, String, String)] = []
                for await item in group { collected.append(item) }
                return collected.sorted { $0.0 < $1.0 }
            }
            await MainActor.run {
                previews = results.map { ($0.1, $0.2, $0.3) }
                isPreviewing = false
                status = "원본 대사와 결이 비슷하면 저장하세요."
            }
        }
    }

    private func analyze() {
        isAnalyzing = true
        status = ""
        let currentDescription = description
        let currentSamples = sampleLines
        Task {
            do {
                let guide = try await GeminiService.shared.analyzePersonaStyle(
                    description: currentDescription, samples: currentSamples
                )
                await MainActor.run {
                    styleGuide = guide
                    isEnabled = true
                    isAnalyzing = false
                    status = "분석 완료. 규칙을 확인하고 저장하세요."
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
