import SwiftUI

public struct TypingIndicatorView: View {
    let botName: String
    let customAvatar: NSImage?
    /// 답변 받기를 멈춥니다. 없으면 멈춤 버튼을 보이지 않습니다.
    var onCancel: (() -> Void)? = nil

    @State private var dotScales: [CGFloat] = [1.0, 1.0, 1.0]
    @State private var dotOpacities: [Double] = [0.4, 0.4, 0.4]
    @State private var isHoveringCancel = false

    public init(
        botName: String = "사피엔스",
        customAvatar: NSImage? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.botName = botName
        self.customAvatar = customAvatar
        self.onCancel = onCancel
    }
    
    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 아바타 (38x38)
            RoomAvatarView(image: customAvatar, size: 38)
                .padding(.top, 1)
            
            VStack(alignment: .leading, spacing: 2.5) {
                // 발신자 이름 (현재 설정된 이름 동적 바인딩)
                Text(botName)
                    .font(.custom("Pretendard-Regular", size: 12))
                    .foregroundColor(Color(red: 0.35, green: 0.35, blue: 0.35))
                    .padding(.leading, 1)
                
                // 도톰한 카카오톡 타이핑 버블 (말풍선 한 줄 두께 32px)
                HStack(spacing: 5.5) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(Color(red: 0.996, green: 0.85, blue: 0.0)) // 카카오 옐로우 액티브 닷
                            .frame(width: 6.5, height: 6.5)
                            .scaleEffect(dotScales[i])
                            .opacity(dotOpacities[i])
                    }
                }
                .padding(.horizontal, 15)
                .frame(height: 32)
                .background(
                    KakaoAlignedSapiensBubbleShape(isFirst: true)
                        .fill(Color(red: 0.46, green: 0.54, blue: 0.62)) // 카카오톡 수신 대기 둥근 회색-블루 버블
                )
            }

            // 답변이 길어질 때 멈출 수 있게 합니다. 답변을 받는 동안에만 보입니다.
            if let onCancel {
                Button(action: onCancel) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 8.5, weight: .bold))
                        Text("멈추기")
                            .font(.custom("Pretendard-Medium", size: 11))
                    }
                    .foregroundColor(Color.black.opacity(isHoveringCancel ? 0.75 : 0.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(Color.white.opacity(isHoveringCancel ? 0.95 : 0.75))
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { isHoveringCancel = $0 }
                // 이름 줄(약 17pt) + 말풍선 절반(16pt) = 33pt가 말풍선 중심입니다.
                // 버튼 높이가 23pt이므로 그 절반을 빼서 위에서 21pt 내려놓습니다.
                .padding(.top, 21)
                .help("답변 받기를 멈춥니다")
            }

            Spacer()
        }
        .padding(.horizontal, 11)
        .padding(.top, 4)
        .padding(.bottom, 12) // 바닥 입력창과 넉넉히 띄움
        .onAppear {
            animateDots()
        }
    }
    
    private func animateDots() {
        for i in 0..<3 {
            withAnimation(
                Animation.easeInOut(duration: 0.45)
                    .repeatForever(autoreverses: true)
                    .delay(Double(i) * 0.18)
            ) {
                dotScales[i] = 1.3
                dotOpacities[i] = 1.0
            }
        }
    }
}
