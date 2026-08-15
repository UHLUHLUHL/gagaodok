import SwiftUI

// 카카오톡 모양에 맞춰 직접 그린 아이콘입니다.
//
// 처음에는 헤더 아이콘을 전부 직접 그렸는데, 확대해서 원본과 나란히 놓아 보니
// 돋보기·수화기·비디오·햄버거는 SF Symbols 쪽이 오히려 더 가깝고 깔끔했습니다.
// 특히 수화기는 직접 그린 경로가 스스로 겹쳐 뭉개진 덩어리가 됐습니다.
// 그래서 SF Symbols에 같은 모양이 아예 없는 둘만 남깁니다.

/// 새 대화 — 둥근 말풍선에 꼬리가 왼쪽 아래로 나오고, 오른쪽에 +가 붙습니다.
///
/// 원본을 확대해 보니 사각형이 아니라 거의 원에 가깝고, +가 놓인 자리에서
/// 테두리가 끊겨 있습니다. 그 끊김이 이 아이콘의 인상을 만듭니다.
/// SF Symbols에는 이렇게 테두리가 열린 말풍선이 없습니다.
public struct ComposeChatIcon: View {
    var lineWidth: CGFloat
    var color: Color

    public init(lineWidth: CGFloat = 1.5, color: Color) {
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
            // +가 놓일 오른쪽을 비우고 나머지를 두 토막으로 그립니다.
            var p = Path()
            p.addArc(center: center, radius: radius,
                     startAngle: .degrees(30), endAngle: .degrees(116),
                     clockwise: false)
            p.addLine(to: CGPoint(x: center.x - radius * 0.98, y: center.y + radius * 1.24))
            p.addArc(center: center, radius: radius,
                     startAngle: .degrees(156), endAngle: .degrees(300),
                     clockwise: false)
            return p
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
                p.addLine(to: CGPoint(x: c.x - r * 0.52, y: c.y + r * 1.62))
                p.closeSubpath()
            }
            .fill(color)
        }
    }
}
