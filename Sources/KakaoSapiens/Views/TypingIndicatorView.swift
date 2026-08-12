import SwiftUI

public struct TypingIndicatorView: View {
    let botName: String
    let customAvatar: NSImage?
    
    @State private var dotScales: [CGFloat] = [1.0, 1.0, 1.0]
    @State private var dotOpacities: [Double] = [0.4, 0.4, 0.4]
    
    public init(botName: String = "사피엔스", customAvatar: NSImage? = nil) {
        self.botName = botName
        self.customAvatar = customAvatar
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
