import Foundation
import AppKit

@main
@MainActor
struct MathVisualRendererTests {
    static func main() async throws {
        let shellURL = URL(fileURLWithPath: "Sources/KakaoSapiens/Resources/visual-sheet.html")
        let renderer = MathVisualRenderer(shellURL: shellURL)

        try await assertRetinaPNG(renderer: renderer, spec: makeSpec(
            kind: .implicit2D, expression: "x^2+y^2", contourValue: 1
        ))
        try await assertRetinaPNG(renderer: renderer, spec: makeSpec(
            kind: .integral2D, expression: "x*t", parameterMin: 0, parameterMax: 1
        ))
        try await assertRetinaPNG(renderer: renderer, spec: makeSpec(
            kind: .ode2D, expression: "y", initialX: 0, initialY: 1
        ))
        try await testImplicitCurveUsesEqualAxisScale(renderer: renderer)

        let html = try String(contentsOf: shellURL, encoding: .utf8)
        precondition(html.contains("id=\"legend\""), "범례를 표시할 전용 요소가 필요합니다.")
        precondition(html.contains("payload.xLabel"), "축 라벨은 명세 값에서 와야 합니다.")
        precondition(!html.contains("http://") && !html.contains("https://"))
        print("MathVisualRendererTests passed")
    }

    static func assertRetinaPNG(renderer: MathVisualRenderer, spec: MathVisualSpec) async throws {
        let data = try await renderer.render(spec: spec)
        precondition(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        guard let image = NSImage(data: data),
              let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
            preconditionFailure("PNG를 NSImage로 다시 열 수 있어야 합니다.")
        }
        precondition(bitmap.pixelsWide == 2_400, "그래프 PNG 폭은 2,400px이어야 합니다.")
        precondition(bitmap.pixelsHigh > 1_400, "제목과 그래프를 담을 충분한 세로 해상도가 필요합니다.")
    }

    static func testImplicitCurveUsesEqualAxisScale(renderer: MathVisualRenderer) async throws {
        let data = try await renderer.render(spec: makeSpec(
            kind: .implicit2D,
            expression: "x^2+y^2",
            contourValue: 1
        ))
        let bitmap = NSBitmapImageRep(data: data)!
        var minX = bitmap.pixelsWide, maxX = 0, minY = bitmap.pixelsHigh, maxY = 0
        var matched = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let red = color.redComponent, green = color.greenComponent, blue = color.blueComponent
                guard red > 0.65, green < 0.55, blue < 0.7, red > blue + 0.08 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                matched += 1
            }
        }
        precondition(matched > 100, "음함수 곡선 픽셀을 찾을 수 있어야 합니다.")
        let ratio = Double(maxX - minX) / Double(maxY - minY)
        precondition((0.95...1.05).contains(ratio), "동일 범위의 단위원은 화면에서도 원이어야 합니다: \(ratio)")
    }

    static func makeSpec(
        kind: MathVisualKind,
        expression: String,
        parameterMin: Double = 0,
        parameterMax: Double = 1,
        initialX: Double = 0,
        initialY: Double = 0,
        contourValue: Double = 0
    ) -> MathVisualSpec {
        MathVisualSpec(
            id: "render", kind: kind, title: "수치 그래프", caption: "검증용 시각자료",
            expression: expression, legend: "해 곡선", xLabel: "가로축", yLabel: "세로축", zLabel: "높이",
            xMin: -2, xMax: 2, yMin: -2, yMax: 4, zMin: -2, zMax: 2,
            parameterMin: parameterMin, parameterMax: parameterMax,
            initialX: initialX, initialY: initialY, contourValue: contourValue,
            points: [], segments: []
        )
    }
}
