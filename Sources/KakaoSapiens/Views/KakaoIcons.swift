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
    /// 참이면 가로·세로 배율을 따로 잡아 설계 상자를 프레임에 꽉 채웁니다.
    /// SVG에서 옮겨 온 도형은 원본 카카오톡과 가로세로 비가 몇 %씩 다른데,
    /// 비율을 지키며 맞추면 잉크 상자가 실측 크기에서 벗어납니다.
    var stretch: Bool = false

    private var uniform: CGFloat {
        min(bounds.width / design.width, bounds.height / design.height)
    }
    var scaleX: CGFloat { stretch ? bounds.width / design.width : uniform }
    var scaleY: CGFloat { stretch ? bounds.height / design.height : uniform }
    var scale: CGFloat { uniform }

    /// 설계 상자를 실제 프레임 가운데에 놓습니다.
    private var origin: CGPoint {
        CGPoint(
            x: bounds.midX - design.width * scaleX / 2,
            y: bounds.midY - design.height * scaleY / 2
        )
    }

    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x * scaleX, y: origin.y + y * scaleY)
    }

    func len(_ v: CGFloat) -> CGFloat { v * uniform }
    func lenX(_ v: CGFloat) -> CGFloat { v * scaleX }
    func lenY(_ v: CGFloat) -> CGFloat { v * scaleY }
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
/// 도형은 `kakao-style-svg-icons/sidebar-profile.svg`를 그대로 옮겼습니다.
/// SVG는 64 x 64 상자 안에 잉크가 48 x 50으로 들어 있어서, 그 48 x 50만 떼어
/// 설계 상자로 씁니다. 좌표는 SVG 값에서 (8, 7)을 뺀 것입니다.
///
/// 가로세로를 따로 늘려 23 x 23에 맞춥니다. 실측한 원본이 23 x 23인데 SVG는
/// 48 x 50이라 비율이 4%쯤 다릅니다. 비율을 지키면 폭이 22.1로 줄어 레일에서
/// 말풍선보다 작아 보입니다. 게다가 원본 머리는 실측 12 x 11로 원래 세로가
/// 눌려 있어서, 늘리는 쪽이 원본에 더 가깝습니다.
public struct PersonGlyph: View {
    var color: Color

    public init(color: Color) { self.color = color }

    public var body: some View {
        GeometryReader { geo in
            let c = Canvas(design: CGSize(width: 48, height: 50),
                           bounds: CGRect(origin: .zero, size: geo.size),
                           stretch: true)

            Path { p in
                // 머리: SVG는 r 13인데 12.5로 줄였습니다. 13이면 화면에서 지름이
                // 12.5가 되어 실측 12.0보다 굵고, 아래로도 0.5 더 내려와 어깨와의
                // 틈을 먹습니다. 12.5면 폭 12.0, 아래 끝 11.5로 원본과 같습니다.
                p.addEllipse(in: CGRect(origin: c.pt(11.5, 0),
                                        size: CGSize(width: c.lenX(25), height: c.lenY(25))))

                // 어깨: 돔을 올리고 바닥은 반지름 1.5로 살짝 굴립니다.
                p.move(to: c.pt(0, 48.5))
                p.addCurve(to: c.pt(24, 30), control1: c.pt(0, 37.73), control2: c.pt(10.75, 30))
                p.addCurve(to: c.pt(48, 48.5), control1: c.pt(37.25, 30), control2: c.pt(48, 37.73))
                p.addCurve(to: c.pt(46.5, 50), control1: c.pt(48, 49.33), control2: c.pt(47.33, 50))
                p.addLine(to: c.pt(1.5, 50))
                p.addCurve(to: c.pt(0, 48.5), control1: c.pt(0.67, 50), control2: c.pt(0, 49.33))
                p.closeSubpath()
            }
            .fill(color)
        }
    }
}

// MARK: - 레일: 채팅

/// 사이드바의 채팅 아이콘 — 왼쪽 아래로 꼬리가 난 채운 말풍선입니다.
///
/// 도형은 `kakao-style-svg-icons/sidebar-chat.svg`를 그대로 옮겼습니다.
/// SVG의 잉크는 49.68 x 47이라 그만큼만 떼어 설계 상자로 쓰고, 좌표는 SVG 값에서
/// (8, 9)를 뺀 것입니다. 실측 22 x 22에 맞추려고 가로세로를 따로 늘립니다.
///
/// 전에는 몸통을 알약(높이의 절반이 반지름인 둥근 사각형)으로 그렸는데 틀렸습니다.
/// 그렇게 판단한 근거가 "원본 맨 윗줄의 폭이 3.4뿐"이었는데, 그 캡처는 안 읽은
/// 개수를 알리는 빨간 배지가 말풍선 오른쪽 위를 덮고 있어서 윗줄이 잘려 보인
/// 것이었습니다. 가리지 않은 왼쪽 가장자리만 행마다 다시 재 보면 알약이 아니라
/// 타원입니다. y=1에서 5.5, y=2에서 4.0, y=3에서 2.5, y=4에서 2.0 — 알약은 여기서
/// 각각 4.5, 3.0, 2.0, 1.5로 매번 넓습니다.
///
/// 꼬리만 SVG를 그대로 두지 않았습니다. SVG는 꼬리의 곧은 왼쪽 변이 x=5.2인데
/// 원본은 4.0이라 꼬리가 1.2만큼 여위어 보입니다. 그래서 몸통은 SVG대로 두고
/// 꼬리는 실측 좌표로 따로 겹쳐 그립니다.
///
/// 몸통과 꼬리를 한 Path에 넣으면 안 됩니다. 두 도형의 감는 방향이 반대라
/// 겹친 자리가 비어 하얀 쐐기가 생깁니다. 실제로 그렇게 났었습니다.
/// 겹쳐 그리면 그런 다툼이 없습니다.
public struct ChatBubbleGlyph: View {
    var color: Color

    public init(color: Color) { self.color = color }

    public var body: some View {
        GeometryReader { geo in
            let c = Canvas(design: CGSize(width: 49.68, height: 47),
                           bounds: CGRect(origin: .zero, size: geo.size),
                           stretch: true)
            // 꼬리는 실측값이라 22 단위로 따로 잡습니다. 잉크 상자가 같으니
            // 두 좌표계는 화면에서 정확히 겹칩니다.
            let m = Canvas(design: CGSize(width: 22, height: 22),
                           bounds: CGRect(origin: .zero, size: geo.size),
                           stretch: true)

            ZStack {
                // 몸통: SVG의 바깥선에서 꼬리만 빼고, 그 자리는 오른쪽 아래 곡선을
                // 좌우로 뒤집어 이어 붙였습니다.
                Path { p in
                    p.move(to: c.pt(24.84, 0))
                    p.addCurve(to: c.pt(0, 19.98),
                               control1: c.pt(11.12, 0), control2: c.pt(0, 8.48))
                    p.addCurve(to: c.pt(24.84, 40.57),
                               control1: c.pt(0, 32.09), control2: c.pt(11.12, 40.57))
                    p.addCurve(to: c.pt(49.68, 19.98),
                               control1: c.pt(38.56, 40.57), control2: c.pt(49.68, 32.09))
                    p.addCurve(to: c.pt(24.84, 0),
                               control1: c.pt(49.68, 8.48), control2: c.pt(38.56, 0))
                    p.closeSubpath()
                }
                .fill(color)

                // 꼬리: 곧은 왼쪽 변 x=4.0, 끝점 y=22.0, 몸통으로 돌아가는 빗변.
                // 위쪽 두 점은 몸통 안에 넉넉히 물려 둡니다. 경계에 딱 붙이면
                // 곡선을 따라 실틈이 보입니다.
                Path { p in
                    p.move(to: m.pt(4.0, 15.0))
                    p.addLine(to: m.pt(11.0, 18.0))
                    p.addLine(to: m.pt(4.05, 22.0))
                    p.closeSubpath()
                }
                .fill(color)
            }
        }
    }
}
