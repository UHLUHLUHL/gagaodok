import SwiftUI

/// 카카오톡이 쓰는 모양에 맞춰 직접 그린 아이콘입니다.
///
/// SF Symbols로 대신하면 획 두께와 모서리 굴림이 조금씩 달라 나란히 놓으면 티가 납니다.
/// 자주 보이는 것부터 하나씩 옮깁니다.
public enum KakaoIcon {}

/// 새 대화 — 말풍선 안에 +가 있는 모양입니다.
public struct ComposeChatIcon: View {
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
            // 말풍선 몸통은 아래쪽에 꼬리 자리를 남기고 그립니다.
            let bodyHeight = h * 0.80
            let plus = min(w, bodyHeight) * 0.42

            ZStack {
                BubbleWithTail(bodyHeight: bodyHeight)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

                Path { path in
                    let cx = w / 2
                    let cy = bodyHeight / 2
                    path.move(to: CGPoint(x: cx - plus / 2, y: cy))
                    path.addLine(to: CGPoint(x: cx + plus / 2, y: cy))
                    path.move(to: CGPoint(x: cx, y: cy - plus / 2))
                    path.addLine(to: CGPoint(x: cx, y: cy + plus / 2))
                }
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
    }

    private struct BubbleWithTail: Shape {
        let bodyHeight: CGFloat

        func path(in rect: CGRect) -> Path {
            let w = rect.width
            let r = bodyHeight * 0.30
            let body = CGRect(x: 0, y: 0, width: w, height: bodyHeight)

            var path = Path()
            // 왼쪽 아래 모서리에서 시작해 시계 방향으로 돌되, 꼬리 자리를 비워 둡니다.
            let tailStart = CGPoint(x: w * 0.30, y: bodyHeight)
            let tailTip = CGPoint(x: w * 0.20, y: rect.height)
            let tailEnd = CGPoint(x: w * 0.44, y: bodyHeight)

            path.move(to: CGPoint(x: r, y: bodyHeight))
            path.addLine(to: tailStart)
            path.addLine(to: tailTip)
            path.addLine(to: tailEnd)
            path.addLine(to: CGPoint(x: w - r, y: bodyHeight))
            path.addArc(center: CGPoint(x: w - r, y: bodyHeight - r), radius: r,
                        startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            path.addLine(to: CGPoint(x: w, y: r))
            path.addArc(center: CGPoint(x: w - r, y: r), radius: r,
                        startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
            path.addLine(to: CGPoint(x: r, y: 0))
            path.addArc(center: CGPoint(x: r, y: r), radius: r,
                        startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)
            path.addLine(to: CGPoint(x: 0, y: bodyHeight - r))
            path.addArc(center: CGPoint(x: r, y: bodyHeight - r), radius: r,
                        startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            path.closeSubpath()
            _ = body
            return path
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
