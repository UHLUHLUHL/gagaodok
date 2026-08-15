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
    var color: Color = Color.black.opacity(0.72)

    public init(lineWidth: CGFloat = 1.6, color: Color = Color.black.opacity(0.72)) {
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
