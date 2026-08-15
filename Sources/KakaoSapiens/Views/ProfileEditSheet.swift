import SwiftUI
import AppKit

/// 카카오톡 "멀티프로필 편집" 시트를 본뜬 공용 편집 화면입니다.
///
/// 친구 추가, 친구 프로필 편집, 내 프로필 편집이 모두 같은 모양을 씁니다.
/// 카카오톡처럼 큰 아바타에 카메라 배지, 밑줄 입력란과 글자 수 카운터, 하단 확인 버튼 구성입니다.
public struct ProfileEditSheet: View {
    public struct Result {
        public let name: String
        public let statusMessage: String
        public let image: NSImage?
        public let didChangeImage: Bool
    }

    let title: String
    let confirmLabel: String
    let onCancel: () -> Void
    let onConfirm: (Result) -> Void

    @State private var name: String
    @State private var statusMessage: String
    @State private var image: NSImage?
    @State private var didChangeImage = false

    private let nameLimit = 20
    private let statusLimit = 60

    private let kakaoYellow = Color(red: 0.996, green: 0.898, blue: 0.0)
    private let ink = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let subInk = Color(red: 0.60, green: 0.62, blue: 0.66)
    private let hairline = Color(red: 0.88, green: 0.89, blue: 0.91)

    public init(
        title: String,
        confirmLabel: String = "확인",
        name: String = "",
        statusMessage: String = "",
        image: NSImage? = nil,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (Result) -> Void
    ) {
        self.title = title
        self.confirmLabel = confirmLabel
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _name = State(initialValue: name)
        _statusMessage = State(initialValue: statusMessage)
        _image = State(initialValue: image)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canConfirm: Bool { !trimmedName.isEmpty }

    public var body: some View {
        GeometryReader { geo in
            let sheetWidth = min(max(geo.size.width - 32, 280), 330)

            ZStack {
                Color.black.opacity(0.42).ignoresSafeArea().onTapGesture { onCancel() }

                VStack(spacing: 0) {
                    Text(title)
                        .font(.custom("Pretendard-Bold", size: 14.5))
                        .foregroundColor(ink)
                        .padding(.top, 20)
                        .padding(.bottom, 18)

                    avatarPicker
                        .padding(.bottom, 20)

                    field(text: $name, placeholder: "이름", limit: nameLimit, bold: true)
                    field(text: $statusMessage, placeholder: "상태메시지를 입력해 주세요.", limit: statusLimit, bold: false)
                        .padding(.top, 12)

                    Spacer(minLength: 18)

                    Button(action: confirm) {
                        Text(confirmLabel)
                            .font(.custom("Pretendard-Bold", size: 13))
                            .foregroundColor(canConfirm ? ink : subInk)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(canConfirm ? kakaoYellow : Color(red: 0.93, green: 0.94, blue: 0.95),
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canConfirm)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                }
                .frame(width: sheetWidth, height: 400)
                .background(KakaoTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 22, x: 0, y: 10)
                .overlay(alignment: .topLeading) {
                    Button(action: onCancel) {
                        Circle().fill(KakaoTheme.hairline)
                            .frame(width: 20, height: 20)
                            .overlay(Image(systemName: "xmark")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(subInk))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // 앱 전체가 라이트 전용이라 시스템이 다크여도 밝게 고정합니다.
        
    }

    private var avatarPicker: some View {
        ZStack(alignment: .bottomTrailing) {
            RoomAvatarView(image: image, size: 88)
            Button(action: pickImage) {
                Circle()
                    .fill(Color(red: 0.20, green: 0.20, blue: 0.21))
                    .frame(width: 26, height: 26)
                    .overlay(Image(systemName: "camera.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white))
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .offset(x: 2, y: 2)
        }
        .contextMenu {
            Button("기본 이미지로") {
                image = nil
                didChangeImage = true
            }
        }
    }

    /// 카카오톡처럼 밑줄만 있는 입력란과 오른쪽 글자 수 표시입니다.
    private func field(text: Binding<String>, placeholder: String, limit: Int, bold: Bool) -> some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(.custom(bold ? "Pretendard-Bold" : "Pretendard-Regular", size: bold ? 14 : 12.5))
                    .foregroundColor(ink)
                    .onChange(of: text.wrappedValue) { _, value in
                        if value.count > limit { text.wrappedValue = String(value.prefix(limit)) }
                    }
                Text("\(text.wrappedValue.count)/\(limit)")
                    .font(.custom("Pretendard-Regular", size: 10.5))
                    .foregroundColor(subInk)
            }
            Rectangle().fill(hairline).frame(height: 1)
        }
        .padding(.horizontal, 20)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let picked = NSImage(contentsOf: url) else { return }
        image = picked
        didChangeImage = true
    }

    private func confirm() {
        guard canConfirm else { return }
        onConfirm(Result(
            name: trimmedName,
            statusMessage: statusMessage.trimmingCharacters(in: .whitespacesAndNewlines),
            image: image,
            didChangeImage: didChangeImage
        ))
    }
}
