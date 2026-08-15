import SwiftUI

// 카카오톡 아이콘을 실측 치수로 다시 그립니다.
//
// 눈대중으로 맞추다 계속 어긋나서, 실제 카카오톡 캡처를 화소 단위로 훑어
// 잉크 상자·획 굵기·곡선의 반지름을 직접 뽑았습니다. 아래 숫자는 전부 그렇게 잰
// 값이고, 주석의 좌표는 각 아이콘의 설계 상자 안에서의 pt입니다.
//
//   돋보기      16.5 x 16.5,  획 1.5
//   새 대화     19.5 x 16.0,  획 1.5
//   친구 추가   22.0 x 17.0,  획 1.5
//   레일 친구   23.0 x 23.0,  채움
//   레일 채팅   22.0 x 22.0,  채움
//   헤더 아이콘 중심 간격 41.0
//
// SF Symbols를 쓰지 않는 이유도 재 보고 알았습니다. 예를 들어 magnifyingglass는
// 원 부분 획이 1.4로 원본과 같은데 손잡이만 2.75로 두 배 가까이 굵습니다.
// 그래서 나란히 놓으면 우리 것만 뭉툭해 보였습니다.

// MARK: - 설계 좌표

/// 실측 치수를 그대로 적고, 실제 프레임 크기에 맞춰 비율만 옮깁니다.
/// 호출부가 설계 크기와 같은 프레임을 주면 배율은 1이 됩니다.
private struct Canvas {
    let design: CGSize
    let bounds: CGRect

    var scale: CGFloat {
        min(bounds.width / design.width, bounds.height / design.height)
    }

    /// 설계 상자를 실제 프레임 가운데에 놓습니다.
    private var origin: CGPoint {
        CGPoint(
            x: bounds.midX - design.width * scale / 2,
            y: bounds.midY - design.height * scale / 2
        )
    }

    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }

    func len(_ v: CGFloat) -> CGFloat { v * scale }
}

/// 초타원 위 한 점입니다. `n`이 2면 보통 타원이고, 커질수록 위가 평평하고
/// 옆구리가 곧아집니다. 카카오톡의 어깨 곡선이 정확히 n=2.5였습니다.
private func superellipsePoint(
    center: CGPoint, rx: CGFloat, ry: CGFloat, n: CGFloat, angle: CGFloat
) -> CGPoint {
    let c = cos(angle), s = sin(angle)
    let e = 2 / n
    return CGPoint(
        x: center.x + rx * copysign(pow(abs(c), e), c),
        y: center.y + ry * copysign(pow(abs(s), e), s)
    )
}

private extension Path {
    /// 초타원 호를 잘게 쪼개 잇습니다. SwiftUI의 addArc는 정원만 그려서
    /// 타원 호가 필요하면 이렇게 직접 떠야 합니다.
    mutating func addSuperellipseArc(
        canvas: Canvas, center: CGPoint, rx: CGFloat, ry: CGFloat,
        n: CGFloat = 2, from: CGFloat, to: CGFloat, steps: Int = 72, moveFirst: Bool
    ) {
        for i in 0...steps {
            let a = (from + (to - from) * CGFloat(i) / CGFloat(steps)) * .pi / 180
            let p = superellipsePoint(center: center, rx: rx, ry: ry, n: n, angle: a)
            let screen = canvas.pt(p.x, p.y)
            if i == 0 && moveFirst { move(to: screen) } else { addLine(to: screen) }
        }
    }
}

// MARK: - 헤더: 돋보기

/// 돋보기 — 원 하나에 45°로 뻗은 손잡이입니다.
///
/// 실측 16.5 x 16.5. 원의 바깥지름 12.5, 획 1.5, 손잡이도 같은 1.5입니다.
/// SF Symbols는 손잡이만 2.75로 굵어 이 자리에서 혼자 뭉툭해 보입니다.
public struct MagnifierIcon: View {
    var color: Color

    public init(color: Color) { self.color = color }

    public var body: some View {
        GeometryReader { geo in
            let c = Canvas(design: CGSize(width: 16.5, height: 16.5),
                           bounds: CGRect(origin: .zero, size: geo.size))
            let center = CGPoint(x: 6.25, y: 6.25)
            let r: CGFloat = 5.5           // 획 중심선 반지름. 바깥지름 12.5.
            let exit = r / (2.0).squareRoot()

            Path { p in
                p.addEllipse(in: CGRect(
                    x: c.pt(center.x - r, center.y - r).x,
                    y: c.pt(center.x - r, center.y - r).y,
                    width: c.len(r * 2), height: c.len(r * 2)
                ))
                p.move(to: c.pt(center.x + exit, center.y + exit))
                p.addLine(to: c.pt(15.75, 15.75))
            }
            .stroke(color, style: StrokeStyle(lineWidth: c.len(1.5), lineCap: .round))
        }
    }
}

// MARK: - 헤더: 새 대화

/// 새 대화 — 오른쪽이 트인 말풍선에 +가 붙습니다.
///
/// 실측 19.5 x 16.0. 몸통은 정원이 아니라 가로로 눌린 타원(중심선 반지름 7.5 x 6.25)이고,
/// +가 놓이는 오른쪽 72°가 통째로 비어 있습니다. 그 트임이 이 아이콘의 인상을 만듭니다.
/// 꼬리는 왼쪽 아래에서 곧게 내려갔다가 비스듬히 몸통으로 돌아옵니다.
public struct ComposeChatIcon: View {
    var color: Color

    public init(color: Color) { self.color = color }

    public var body: some View {
        GeometryReader { geo in
            let c = Canvas(design: CGSize(width: 19.5, height: 16.0),
                           bounds: CGRect(origin: .zero, size: geo.size))
            let center = CGPoint(x: 8.25, y: 7.0)
            let rx: CGFloat = 7.5, ry: CGFloat = 6.25

            Path { p in
                // 오른쪽 아래에서 시작해 바닥까지. 화면 좌표라 각도가 커지면 아래로 돕니다.
                p.addSuperellipseArc(canvas: c, center: center, rx: rx, ry: ry,
                                     from: 41, to: 110, moveFirst: true)
                // 꼬리: 뾰족한 끝을 찍고 몸통 왼쪽 아래로 되돌아옵니다.
                // 끝점은 (3.9, 15.3). 둥근 마감을 더하면 아이콘 바닥 16.0에 맞습니다.
                p.addLine(to: c.pt(3.9, 15.3))
                p.addSuperellipseArc(canvas: c, center: center, rx: rx, ry: ry,
                                     from: 134, to: 329, moveFirst: false)

                // +. 실측으로 중심 (15.5, 8.0), 획 중심선 팔 길이 3.25입니다.
                // 둥근 마감 0.75를 더하면 오른쪽 끝이 정확히 19.5, 곧 아이콘 폭이 됩니다.
                let plus = CGPoint(x: 15.5, y: 8.0)
                let arm: CGFloat = 3.25
                p.move(to: c.pt(plus.x - arm, plus.y))
                p.addLine(to: c.pt(plus.x + arm, plus.y))
                p.move(to: c.pt(plus.x, plus.y - arm))
                p.addLine(to: c.pt(plus.x, plus.y + arm))
            }
            .stroke(color, style: StrokeStyle(lineWidth: c.len(1.5),
                                              lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - 헤더: 친구 추가

/// 친구 추가 — 외곽선 사람에 +가 붙습니다.
///
/// 실측 22.0 x 17.0. 머리는 바깥지름 9의 원이고, 어깨는 초타원(n=2.5)의 윗반쪽을
/// 상자 아래에서 잘라 낸 호입니다. 어깨가 사람 폭의 전부를 쓰기 때문에
/// 아래로 갈수록 옆구리가 곧게 서고 위는 평평합니다. 보통 타원으로는 이 느낌이 안 납니다.
public struct AddFriendIcon: View {
    var color: Color

    public init(color: Color) { self.color = color }

    public var body: some View {
        GeometryReader { geo in
            let c = Canvas(design: CGSize(width: 22.0, height: 17.0),
                           bounds: CGRect(origin: .zero, size: geo.size))

            Path { p in
                // 머리. 중심선 반지름 3.75, 획 1.5 → 바깥지름 9.
                let head = CGPoint(x: 8.0, y: 4.5)
                let hr: CGFloat = 3.75
                p.addEllipse(in: CGRect(
                    x: c.pt(head.x - hr, head.y - hr).x,
                    y: c.pt(head.x - hr, head.y - hr).y,
                    width: c.len(hr * 2), height: c.len(hr * 2)
                ))

                // 어깨. 중심을 상자 아래(17.5)에 두고 윗반쪽만 그리되,
                // 상자 바닥에 닿는 지점(y≈16.25)에서 끊습니다.
                // 그 각도를 초타원 식에서 거꾸로 풀면 아래 값이 나옵니다.
                let cut: CGFloat = 7.7    // 180°+7.7° ~ 360°-7.7°
                p.addSuperellipseArc(canvas: c, center: CGPoint(x: 8.0, y: 17.5),
                                     rx: 7.5, ry: 6.25, n: 2.5,
                                     from: 180 + cut, to: 360 - cut, moveFirst: true)

                // +. 실측으로 중심 (18.25, 8.5), 획 중심선 팔 길이 2.9입니다.
                let plus = CGPoint(x: 18.25, y: 8.5)
                let arm: CGFloat = 2.9
                p.move(to: c.pt(plus.x - arm, plus.y))
                p.addLine(to: c.pt(plus.x + arm, plus.y))
                p.move(to: c.pt(plus.x, plus.y - arm))
                p.addLine(to: c.pt(plus.x, plus.y + arm))
            }
            .stroke(color, style: StrokeStyle(lineWidth: c.len(1.5),
                                              lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - 레일: 친구

/// 사이드바의 친구 아이콘 — 머리와 어깨가 떨어져 있는 채운 실루엣입니다.
///
/// 실측 23 x 23. 머리 지름 12, 틈 2, 어깨 23 x 9입니다.
/// 어깨는 아래 2.5가 곧은 옆구리이고 위 6.5가 타원 돔입니다. 행마다 폭을 재
/// 맞춰 보니 초타원이 아니라 보통 타원이 정확했습니다.
public struct PersonGlyph: View {
    var color: Color

    public init(color: Color) { self.color = color }

    public var body: some View {
        GeometryReader { geo in
            let c = Canvas(design: CGSize(width: 23, height: 23),
                           bounds: CGRect(origin: .zero, size: geo.size))

            Path { p in
                let hr: CGFloat = 6
                p.addEllipse(in: CGRect(
                    x: c.pt(11.5 - hr, 6 - hr).x, y: c.pt(11.5 - hr, 6 - hr).y,
                    width: c.len(hr * 2), height: c.len(hr * 2)
                ))

                // 어깨: 왼쪽 아래 → 곧은 옆구리 → 돔 → 오른쪽 아래.
                let domeBottom: CGFloat = 20.5
                p.move(to: c.pt(0, 23))
                p.addLine(to: c.pt(0, domeBottom))
                p.addSuperellipseArc(canvas: c,
                                     center: CGPoint(x: 11.5, y: domeBottom),
                                     rx: 11.5, ry: 6.5, n: 2,
                                     from: 180, to: 360, moveFirst: false)
                p.addLine(to: c.pt(23, 23))
                p.closeSubpath()
            }
            .fill(color)
        }
    }
}

// MARK: - 레일: 채팅

/// 사이드바의 채팅 아이콘 — 왼쪽 아래로 꼬리가 난 채운 말풍선입니다.
///
/// 실측 22 x 22. 몸통은 22 x 18.6에 반지름 9.3, 곧 높이의 절반이라 양옆이 반원인
/// 알약 모양입니다. 행마다 폭을 재서 알았습니다. 맨 윗줄의 폭이 3.4밖에 안 되고
/// 폭이 다 차는 줄이 한 줄뿐인데, 모서리를 굴린 사각형으로는 이 두 가지가 같이 안 나옵니다.
/// 꼬리는 왼쪽 모서리에서 곧게 내려와 끝을 찍고 비스듬히 바닥으로 돌아옵니다.
///
/// 몸통과 꼬리를 한 Path에 넣으면 안 됩니다. 두 도형의 감는 방향이 반대라
/// 겹친 자리가 비어 하얀 쐐기가 생깁니다. 실제로 그렇게 났었습니다.
/// 겹쳐 그리면 그런 다툼이 없습니다.
public struct ChatBubbleGlyph: View {
    var color: Color

    public init(color: Color) { self.color = color }

    public var body: some View {
        GeometryReader { geo in
            let c = Canvas(design: CGSize(width: 22, height: 22),
                           bounds: CGRect(origin: .zero, size: geo.size))

            ZStack {
                Path { p in
                    p.addRoundedRect(
                        in: CGRect(x: c.pt(0, 0).x, y: c.pt(0, 0).y,
                                   width: c.len(22), height: c.len(18.6)),
                        cornerSize: CGSize(width: c.len(9.3), height: c.len(9.3)),
                        style: .circular
                    )
                }
                .fill(color)

                Path { p in
                    // 위쪽 두 점은 몸통 안에 넉넉히 물려 둡니다. 경계에 딱 붙이면
                    // 모서리 곡선을 따라 실틈이 보입니다.
                    p.move(to: c.pt(4.0, 15.5))
                    p.addLine(to: c.pt(10.0, 18.0))
                    p.addLine(to: c.pt(4.4, 22.0))
                    p.closeSubpath()
                }
                .fill(color)
            }
        }
    }
}
