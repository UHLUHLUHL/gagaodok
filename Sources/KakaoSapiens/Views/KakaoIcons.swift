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
            // 원본은 원이 아니라 모서리를 크게 굴린 사각형에 가깝고, 가로가 조금 더 깁니다.
            let body = CGRect(x: w * 0.04, y: h * 0.10, width: w * 0.92, height: h * 0.62)
            let radius = body.height * 0.46

            Path { p in
                p.addRoundedRect(in: body, cornerSize: CGSize(width: radius, height: radius),
                                 style: .continuous)
                // 왼쪽 아래로 빠지는 짧은 꼬리
                p.move(to: CGPoint(x: body.minX + body.width * 0.20, y: body.maxY - 2))
                p.addLine(to: CGPoint(x: body.minX + body.width * 0.10, y: h * 0.94))
                p.addLine(to: CGPoint(x: body.minX + body.width * 0.46, y: body.maxY - 2))
                p.closeSubpath()
            }
            .fill(color)
        }
    }
}

/// 사이드바의 친구 아이콘 — 동그란 머리와 넓은 어깨가 떨어져 있는 채운 실루엣입니다.
///
/// SF Symbols의 person.fill은 머리와 어깨가 붙어 있고 어깨도 좁아서, 원본과 나란히
/// 놓으면 다른 아이콘으로 보입니다. 원본은 둘 사이에 뚜렷한 틈이 있고 어깨가
/// 머리 지름의 두 배 가까이 넓습니다.
public struct PersonGlyph: View {
    var color: Color

    public init(color: Color) {
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let headR = s * 0.158
            let headCenter = CGPoint(x: s * 0.5, y: s * 0.265)
            let shoulderW = s * 0.68
            let shoulderTop = s * 0.505
            let shoulderBottom = s * 0.80
            let shoulderR = shoulderW / 2

            Path { p in
                p.addEllipse(in: CGRect(x: headCenter.x - headR, y: headCenter.y - headR,
                                        width: headR * 2, height: headR * 2))
                // 어깨는 위가 반원, 아래가 평평한 반쪽 알약입니다.
                let cx = s * 0.5
                let arcCenter = CGPoint(x: cx, y: shoulderTop + shoulderR)
                p.move(to: CGPoint(x: cx - shoulderR, y: shoulderBottom))
                p.addLine(to: CGPoint(x: cx - shoulderR, y: arcCenter.y))
                p.addArc(center: arcCenter, radius: shoulderR,
                         startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                p.addLine(to: CGPoint(x: cx + shoulderR, y: shoulderBottom))
                p.closeSubpath()
            }
            .fill(color)
        }
    }
}
