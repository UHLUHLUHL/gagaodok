import SwiftUI

/// 카카오톡이 쓰는 모양에 맞춰 직접 그린 아이콘입니다.
///
/// SF Symbols로 대신하면 획 두께와 모서리 굴림이 조금씩 달라 나란히 놓으면 티가 납니다.
/// 자주 보이는 것부터 하나씩 옮깁니다.
public enum KakaoIcon {}

/// 새 대화 — 둥근 말풍선에 꼬리가 왼쪽 아래로 나오고, 오른쪽에 +가 붙습니다.
///
/// 원본을 확대해 보니 사각형이 아니라 거의 원에 가깝고, +가 놓인 자리에서
/// 테두리가 끊겨 있습니다. 그 끊김이 이 아이콘의 인상을 만듭니다.
public struct ComposeChatIcon: View {
    var lineWidth: CGFloat = 1.5
    var color: Color = Color.black.opacity(0.78)

    public init(lineWidth: CGFloat = 1.5, color: Color = Color.black.opacity(0.78)) {
        self.lineWidth = lineWidth
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let r = min(w, h) * 0.33
            let c = CGPoint(x: w * 0.38, y: h * 0.42)
            let plusCenter = CGPoint(x: w * 0.84, y: h * 0.46)
            let plusHalf = min(w, h) * 0.17

            ZStack {
                BubbleOutline(center: c, radius: r)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

                Path { p in
                    p.move(to: CGPoint(x: plusCenter.x - plusHalf, y: plusCenter.y))
                    p.addLine(to: CGPoint(x: plusCenter.x + plusHalf, y: plusCenter.y))
                    p.move(to: CGPoint(x: plusCenter.x, y: plusCenter.y - plusHalf))
                    p.addLine(to: CGPoint(x: plusCenter.x, y: plusCenter.y + plusHalf))
                }
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
    }

    /// 오른쪽에 +가 들어갈 만큼 테두리를 비우고, 왼쪽 아래에 꼬리를 답니다.
    private struct BubbleOutline: Shape {
        let center: CGPoint
        let radius: CGFloat

        func path(in rect: CGRect) -> Path {
            // 화면 좌표는 y가 아래로 커지므로 0°가 오른쪽, 90°가 아래입니다.
            // +가 놓일 오른쪽(약 -42°~42°)을 비우고 나머지를 두 토막으로 그립니다.
            var p = Path()
            p.addArc(center: center, radius: radius,
                     startAngle: .degrees(30), endAngle: .degrees(116),
                     clockwise: false)
            // 왼쪽 아래로 뾰족하게 빠지는 꼬리
            p.addLine(to: CGPoint(x: center.x - radius * 0.98, y: center.y + radius * 1.24))
            p.addArc(center: center, radius: radius,
                     startAngle: .degrees(156), endAngle: .degrees(300),
                     clockwise: false)
            return p
        }
    }
}

/// 친구 추가 — 사람 옆에 +가 있는 모양입니다.
public struct AddFriendIcon: View {
    var lineWidth: CGFloat = 1.6
    var color: Color = KakaoTheme.textPrimary

    public init(lineWidth: CGFloat = 1.6, color: Color = KakaoTheme.textPrimary) {
        self.lineWidth = lineWidth
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let headR = h * 0.17
            let headCenter = CGPoint(x: w * 0.38, y: h * 0.27)
            let plus = w * 0.30
            let plusCenter = CGPoint(x: w * 0.82, y: h * 0.30)

            ZStack {
                Path { path in
                    path.addEllipse(in: CGRect(x: headCenter.x - headR, y: headCenter.y - headR,
                                               width: headR * 2, height: headR * 2))
                    // 어깨선
                    path.move(to: CGPoint(x: w * 0.08, y: h * 0.86))
                    path.addQuadCurve(to: CGPoint(x: w * 0.68, y: h * 0.86),
                                      control: CGPoint(x: w * 0.38, y: h * 0.50))
                }
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

                Path { path in
                    path.move(to: CGPoint(x: plusCenter.x - plus / 2, y: plusCenter.y))
                    path.addLine(to: CGPoint(x: plusCenter.x + plus / 2, y: plusCenter.y))
                    path.move(to: CGPoint(x: plusCenter.x, y: plusCenter.y - plus / 2))
                    path.addLine(to: CGPoint(x: plusCenter.x, y: plusCenter.y + plus / 2))
                }
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
    }
}

/// 사이드바의 채팅 아이콘 — 꼬리가 왼쪽 아래로 난 둥근 말풍선을 통째로 채웁니다.
///
/// 원본은 선택 여부로 채움/외곽선을 나누지 않고, 둘 다 채운 채 색만 바꿉니다.
/// SF Symbols의 bubble.left는 모서리가 각지고 꼬리 위치가 달라 나란히 놓으면 티가 납니다.
public struct ChatBubbleGlyph: View {
    var color: Color

    public init(color: Color) {
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let r = min(w, h) * 0.40
            let c = CGPoint(x: w * 0.50, y: h * 0.44)

            Path { p in
                p.addArc(center: c, radius: r,
                         startAngle: .degrees(122), endAngle: .degrees(96),
                         clockwise: false)
                // 왼쪽 아래로 빠지는 꼬리
                p.addLine(to: CGPoint(x: c.x - r * 0.52, y: c.y + r * 1.62))
                p.closeSubpath()
            }
            .fill(color)
        }
    }
}

/// 돋보기 — 정원에 45° 손잡이가 오른쪽 아래로 뻗습니다.
public struct MagnifierIcon: View {
    var lineWidth: CGFloat = 1.5
    var color: Color

    public init(lineWidth: CGFloat = 1.5, color: Color) {
        self.lineWidth = lineWidth
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let r = s * 0.30
            let c = CGPoint(x: s * 0.42, y: s * 0.42)
            let start = CGPoint(x: c.x + r * 0.707, y: c.y + r * 0.707)
            Path { p in
                p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                p.move(to: start)
                p.addLine(to: CGPoint(x: start.x + r * 0.72, y: start.y + r * 0.72))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }
}

/// 햄버거 — 길이가 같은 가로줄 셋.
public struct HamburgerIcon: View {
    var lineWidth: CGFloat = 1.5
    var color: Color

    public init(lineWidth: CGFloat = 1.5, color: Color) {
        self.lineWidth = lineWidth
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { p in
                for i in 0..<3 {
                    let y = h * (0.26 + 0.24 * CGFloat(i))
                    p.move(to: CGPoint(x: w * 0.10, y: y))
                    p.addLine(to: CGPoint(x: w * 0.90, y: y))
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }
}

/// 전화 — 고전적인 수화기 모양입니다.
public struct PhoneIcon: View {
    var lineWidth: CGFloat = 1.5
    var color: Color

    public init(lineWidth: CGFloat = 1.5, color: Color) {
        self.lineWidth = lineWidth
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            Path { p in
                // 왼쪽 위 귀 부분에서 시작해 아래로 휘어 오른쪽 아래 입 부분까지
                p.move(to: CGPoint(x: s * 0.22, y: s * 0.16))
                p.addLine(to: CGPoint(x: s * 0.36, y: s * 0.30))
                p.addLine(to: CGPoint(x: s * 0.28, y: s * 0.44))
                p.addCurve(to: CGPoint(x: s * 0.56, y: s * 0.72),
                           control1: CGPoint(x: s * 0.34, y: s * 0.56),
                           control2: CGPoint(x: s * 0.44, y: s * 0.66))
                p.addLine(to: CGPoint(x: s * 0.70, y: s * 0.64))
                p.addLine(to: CGPoint(x: s * 0.84, y: s * 0.78))
                // 손잡이 곡선
                p.addCurve(to: CGPoint(x: s * 0.22, y: s * 0.16),
                           control1: CGPoint(x: s * 0.62, y: s * 1.02),
                           control2: CGPoint(x: s * -0.02, y: s * 0.40))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

/// 화상통화 — 둥근 네모에 오른쪽으로 렌즈가 튀어나온 모양입니다.
public struct VideoIcon: View {
    var lineWidth: CGFloat = 1.5
    var color: Color

    public init(lineWidth: CGFloat = 1.5, color: Color) {
        self.lineWidth = lineWidth
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let body = CGRect(x: w * 0.06, y: h * 0.26, width: w * 0.60, height: h * 0.48)
            Path { p in
                p.addRoundedRect(in: body, cornerSize: CGSize(width: h * 0.11, height: h * 0.11))
                // 오른쪽 렌즈
                p.move(to: CGPoint(x: w * 0.94, y: h * 0.32))
                p.addLine(to: CGPoint(x: w * 0.70, y: h * 0.44))
                p.addLine(to: CGPoint(x: w * 0.70, y: h * 0.56))
                p.addLine(to: CGPoint(x: w * 0.94, y: h * 0.68))
                p.closeSubpath()
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}
