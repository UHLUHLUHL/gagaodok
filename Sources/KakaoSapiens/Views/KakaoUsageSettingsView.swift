import SwiftUI

public struct KakaoUsageSettingsView: View {
    let onClose: () -> Void
    @ObservedObject private var usage = TokenUsageManager.shared
    @ObservedObject private var models = ModelSelectionManager.shared
    @ObservedObject private var rooms = ChatRoomManager.shared

    @State private var section: Section = .usage
    @ObservedObject private var appearance = AppearanceManager.shared
    @State private var keyDrafts: [KeychainStore.Credential: String] = [:]
    @State private var keyStatuses: [KeychainStore.Credential: String] = [:]

    private enum Section: String, CaseIterable {
        case usage = "사용량"
        case model = "AI 모델"
    }

    public init(onClose: @escaping () -> Void) { self.onClose = onClose }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.34)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                header
                Divider().opacity(0.65)
                sectionTabs
                ScrollView {
                    if section == .usage { usageSection } else { modelSection }
                }
            }
            .frame(minWidth: 310, idealWidth: 390, maxWidth: 440, minHeight: 450, idealHeight: 560, maxHeight: 640)
            .background(KakaoTheme.surface)
            .foregroundStyle(KakaoTheme.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(12)
            
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(red: 0.996, green: 0.898, blue: 0.0))
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(red: 0.23, green: 0.12, blue: 0.12))
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("사피엔스 설정")
                    .font(.custom("Pretendard-Bold", size: 15))
                Text("모델과 API 사용량을 관리합니다")
                    .font(.custom("Pretendard-Regular", size: 10.5))
                    .foregroundColor(Color.black.opacity(0.48))
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.black.opacity(0.48))
                    .frame(width: 28, height: 28)
                    .background(Color.black.opacity(0.045), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var sectionTabs: some View {
        HStack(spacing: 4) {
            ForEach(Section.allCases, id: \.rawValue) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { section = item }
                } label: {
                    Text(item.rawValue)
                        .font(.custom(section == item ? "Pretendard-Bold" : "Pretendard-Medium", size: 12))
                        .foregroundColor(section == item ? .black : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(section == item ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color(red: 0.955, green: 0.955, blue: 0.96), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 카카오톡 환경설정의 '화면 모드'와 같은 구성입니다.
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("화면 모드")
                .font(.custom("Pretendard-Bold", size: 12.5))

            HStack(spacing: 7) {
                ForEach(AppearanceMode.allCases) { mode in
                    Button { appearance.mode = mode } label: {
                        Text(mode.displayName)
                            .font(.custom("Pretendard-Medium", size: 11.5))
                            .foregroundColor(appearance.mode == mode ? KakaoTheme.textPrimary : KakaoTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(appearance.mode == mode ? KakaoTheme.sunken : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(appearance.mode == mode ? KakaoTheme.border : KakaoTheme.hairline, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }

            Text("시스템 설정을 고르면 맥의 화면 모드를 따라갑니다.")
                .font(.custom("Pretendard-Regular", size: 10.5))
                .foregroundColor(KakaoTheme.textTertiary)

            Divider().opacity(0.5).padding(.vertical, 4)
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("누적 API 요금")
                        .font(.custom("Pretendard-Medium", size: 11.5))
                        .foregroundColor(KakaoTheme.textSecondary)
                    Spacer()
                    Text("캐시 절약 ₩\(usage.totalSavingsUSD * usage.exchangeRate, specifier: "%.2f")")
                        .font(.custom("Pretendard-Medium", size: 10))
                        .foregroundColor(Color(red: 0.12, green: 0.55, blue: 0.34))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.88, green: 0.97, blue: 0.91), in: Capsule())
                }
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("₩\(usage.totalCostKRW, specifier: "%.2f")")
                        .font(.custom("Pretendard-Bold", size: 27))
                    Text("$\(usage.totalCostUSD, specifier: "%.4f")")
                        .font(.custom("Pretendard-Regular", size: 11))
                        .foregroundColor(Color.black.opacity(0.48))
                }
                Divider().opacity(0.6)
                HStack(spacing: 0) {
                    metric(title: "전체 토큰", value: usage.totalTokens.formatted())
                    metricDivider
                    metric(title: "캐시 토큰", value: usage.totalCachedTokens.formatted())
                    metricDivider
                    metric(title: "캐시 적중률", value: String(format: "%.1f%%", usage.overallCacheHitRate * 100))
                }
            }
            .padding(15)
            .background(Color(red: 0.968, green: 0.968, blue: 0.972), in: RoundedRectangle(cornerRadius: 12))

            Text("모델별 사용량")
                .font(.custom("Pretendard-Bold", size: 12.5))
                .padding(.leading, 2)

            ForEach(AIModel.allCases) { model in
                modelUsageCard(model)
            }

            if !rooms.rooms.isEmpty {
                Text("대화방별 합계")
                    .font(.custom("Pretendard-Bold", size: 12.5))
                    .padding(.top, 2)
                    .padding(.leading, 2)
                VStack(spacing: 0) {
                    ForEach(rooms.rooms) { room in
                        HStack(spacing: 10) {
                            RoomAvatarView(image: rooms.loadAvatarForRoom(profile: room.profile), size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(room.title).font(.custom("Pretendard-Medium", size: 12)).lineLimit(1)
                                Text("\(usage.getUsage(for: room.id).totalTokens.formatted()) tokens")
                                    .font(.custom("Pretendard-Regular", size: 9.5)).foregroundColor(Color.black.opacity(0.48))
                            }
                            Spacer()
                            Text("₩\(usage.costUSD(for: room.id) * usage.exchangeRate, specifier: "%.2f")")
                                .font(.custom("Pretendard-Bold", size: 11.5))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        Divider().padding(.leading, 52)
                    }
                }
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.07)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            appearanceSection

            Text("기본 응답 모델")
                .font(.custom("Pretendard-Bold", size: 12.5))

            VStack(spacing: 8) {
                ForEach(AIModel.allCases) { model in
                    Button { models.selectedModel = model } label: {
                        HStack(spacing: 11) {
                            modelBadge(model)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.displayName)
                                    .font(.custom("Pretendard-Bold", size: 12.5))
                                    .foregroundColor(.black)
                                Text("\(model.providerName) · 입력 $\(model.inputPricePerMillion, specifier: "%.2f") / 출력 $\(model.outputPricePerMillion, specifier: "%.2f")")
                                    .font(.custom("Pretendard-Regular", size: 9.5))
                                    .foregroundColor(Color.black.opacity(0.48))
                            }
                            Spacer()
                            Image(systemName: models.selectedModel == model ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(models.selectedModel == model ? Color(red: 0.996, green: 0.78, blue: 0) : KakaoTheme.border)
                        }
                        .padding(11)
                        .background(models.selectedModel == model ? Color(red: 1.0, green: 0.974, blue: 0.84) : Color(red: 0.97, green: 0.97, blue: 0.975), in: RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(KeychainStore.Credential.allCases) { credential in
                apiKeyCard(for: credential)
            }

            VStack(alignment: .leading, spacing: 7) {
                Label("캐시 최적화 켜짐", systemImage: "bolt.horizontal.circle.fill")
                    .font(.custom("Pretendard-Bold", size: 11.5))
                    .foregroundColor(Color(red: 0.18, green: 0.52, blue: 0.36))
                Text("고정 시스템 지침을 요청 앞부분에 두고 대화는 순서대로 이어 붙입니다. Gemini와 Luna의 실제 캐시 토큰을 각각 추적해 요금에 반영합니다.")
                    .font(.custom("Pretendard-Regular", size: 10.5))
                    .foregroundColor(KakaoTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if AIModel.isIntroductoryPricingActive {
                    Text("Gemini 3.7 Flash는 2026년 12월 31일까지 도입 요금(입력 $0.75 · 출력 $3.75 / 1M 토큰)이 적용됩니다. 2027년 1월 1일부터 정가로 두 배가 되며 이 화면의 금액도 자동으로 바뀝니다.")
                        .font(.custom("Pretendard-Regular", size: 10.5))
                        .foregroundColor(KakaoTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(Color(red: 0.91, green: 0.97, blue: 0.93), in: RoundedRectangle(cornerRadius: 11))
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
    }

    private func modelUsageCard(_ model: AIModel) -> some View {
        let value = usage.totalUsage(for: model)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                modelBadge(model)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName).font(.custom("Pretendard-Bold", size: 12))
                    Text("\(value.requestCount)회 요청 · \(value.totalTokens.formatted()) tokens")
                        .font(.custom("Pretendard-Regular", size: 9.5)).foregroundColor(Color.black.opacity(0.48))
                }
                Spacer()
                Text("₩\(value.costUSD(for: model) * usage.exchangeRate, specifier: "%.2f")")
                    .font(.custom("Pretendard-Bold", size: 13))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(KakaoTheme.hairline)
                    Capsule().fill(Color(red: 0.996, green: 0.82, blue: 0.0))
                        .frame(width: geometry.size.width * value.cacheHitRate)
                }
            }
            .frame(height: 5)
            HStack {
                Text("입력 \(value.inputTokens.formatted()) · 출력 \(value.outputTokens.formatted())")
                Spacer()
                Text("캐시 읽기 \(value.cachedInputTokens.formatted()) · 쓰기 \(value.cacheWriteTokens.formatted()) (\(value.cacheHitRate * 100, specifier: "%.1f")%)")
            }
            .font(.custom("Pretendard-Regular", size: 9.5))
            .foregroundColor(Color.black.opacity(0.48))
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.black.opacity(0.07)))
    }

    private func modelBadge(_ model: AIModel) -> some View {
        Text(model == .gemini37Flash ? "G" : "L")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .frame(width: 29, height: 29)
            .background(model == .gemini37Flash ? Color(red: 0.25, green: 0.52, blue: 0.94) : Color(red: 0.38, green: 0.25, blue: 0.75), in: RoundedRectangle(cornerRadius: 9))
    }

    private func metric(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.custom("Pretendard-Bold", size: 11.5))
            Text(title).font(.custom("Pretendard-Regular", size: 9)).foregroundColor(Color.black.opacity(0.48))
        }
        .frame(maxWidth: .infinity)
    }

    private var metricDivider: some View { Rectangle().fill(KakaoTheme.hairline).frame(width: 1, height: 25) }

    private func apiKeyCard(for credential: KeychainStore.Credential) -> some View {
        let isRegistered = KeychainStore.apiKey(for: credential) != nil
        let draft = Binding(
            get: { keyDrafts[credential] ?? "" },
            set: { keyDrafts[credential] = $0 }
        )
        let placeholder = isRegistered
            ? "새 키를 입력하면 교체됩니다"
            : (credential == .gemini ? "AIza… 또는 AQ.…" : "sk-proj-…")

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(credential.displayName) API 키").font(.custom("Pretendard-Bold", size: 12))
                Spacer()
                Label(
                    isRegistered ? "등록됨" : "미등록",
                    systemImage: isRegistered ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
                )
                .font(.custom("Pretendard-Medium", size: 9.5))
                .foregroundColor(isRegistered ? .green : .orange)
            }
            SecureField(placeholder, text: draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            HStack {
                Text(keyStatuses[credential] ?? "")
                    .font(.custom("Pretendard-Regular", size: 9.5))
                    .foregroundColor(Color.black.opacity(0.48))
                Spacer()
                Button("키체인에 저장") { saveAPIKey(for: credential) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.22, green: 0.22, blue: 0.22))
                    .controlSize(.small)
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(Color(red: 0.97, green: 0.97, blue: 0.975), in: RoundedRectangle(cornerRadius: 11))
    }

    private func saveAPIKey(for credential: KeychainStore.Credential) {
        do {
            try KeychainStore.save(keyDrafts[credential] ?? "", for: credential)
            keyDrafts[credential] = ""
            keyStatuses[credential] = "키체인에 안전하게 저장했습니다."
            models.objectWillChange.send()
        } catch {
            keyStatuses[credential] = error.localizedDescription
        }
    }
}
