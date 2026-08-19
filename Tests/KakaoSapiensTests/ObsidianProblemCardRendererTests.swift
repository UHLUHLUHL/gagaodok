import Foundation
import AppKit

@main
@MainActor
struct ObsidianProblemCardRendererTests {
    static func main() async throws {
        try await testVisualRendererCreatesRetinaPNG()
        let htmlURL = URL(fileURLWithPath: "Sources/KakaoSapiens/Resources/problem-sheet.html")
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        let visualHTML = try String(contentsOf: URL(fileURLWithPath: "Sources/KakaoSapiens/Resources/visual-sheet.html"), encoding: .utf8)
        precondition(html.contains("background: #ffffff"), "문제지는 시스템 다크 모드와 무관하게 흰색이어야 합니다.")
        precondition(html.contains("window.renderProblem"), "제목과 문제 Markdown을 받는 렌더 진입점이 필요합니다.")
        precondition(visualHTML.contains("window.renderVisual"), "시각자료 명세를 받는 렌더 진입점이 필요합니다.")
        precondition(!html.contains("http://") && !html.contains("https://"), "문제 카드 렌더링은 네트워크 자원을 사용하면 안 됩니다.")
        precondition(!visualHTML.contains("http://") && !visualHTML.contains("https://"), "시각자료 렌더링은 네트워크 자원을 사용하면 안 됩니다.")

        precondition(
            ObsidianProblemCardRenderer.fileName(episodeID: "episode/1") == "problem-episode 1.png",
            "문제 이미지 파일명은 episode ID를 안전하게 정리해야 합니다."
        )

        let renderer = ObsidianProblemCardRenderer(shellURL: htmlURL)
        let data = try await renderer.render(
            title: "역함수의 미분",
            problem: "다음 값을 구하시오.\n\n$$\\frac{d}{dx}f^{-1}(x)$$"
        )
        precondition(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "렌더 결과는 PNG 데이터여야 합니다.")
        guard let image = NSImage(data: data),
              let representation = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
            fatalError("PNG 결과를 이미지로 다시 열 수 있어야 합니다.")
        }
        precondition(representation.pixelsWide == 1_800, "Retina 문제 카드는 1,800px 폭이어야 합니다.")
        precondition(representation.pixelsHigh > 300, "제목과 문제를 담을 충분한 세로 높이가 필요합니다.")
    }

    static func testVisualRendererCreatesRetinaPNG() async throws {
        let visualURL = URL(fileURLWithPath: "Sources/KakaoSapiens/Resources/visual-sheet.html")
        let renderer = ObsidianVisualRenderer(shellURL: visualURL)
        let function = ObsidianVisualSpec(
            id: "function", kind: .function2D, title: "삼각함수", caption: "함수 그래프",
            expression: "sin(x)", xMin: -Double.pi, xMax: Double.pi,
            yMin: -1.5, yMax: 1.5, zMin: -1, zMax: 1, points: [], segments: []
        )
        let data = try await renderer.render(spec: function)
        precondition(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "시각자료 결과는 PNG 데이터여야 합니다.")
        guard let image = NSImage(data: data),
              let representation = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
            fatalError("시각자료 PNG를 다시 열 수 있어야 합니다.")
        }
        precondition(representation.pixelsWide == 2_400, "시각자료는 2배 해상도로 출력해야 합니다.")
        precondition(representation.pixelsHigh > 1_400, "시각자료는 제목과 그래프를 담을 충분한 높이가 필요합니다.")

        let surface = ObsidianVisualSpec(
            id: "surface", kind: .surface3D, title: "표면", caption: "3차원 그래프",
            expression: "-3*y/(x^2+y^2+1)", xMin: -4, xMax: 4,
            yMin: -4, yMax: 4, zMin: -1.5, zMax: 1.5, points: [], segments: []
        )
        let surfaceData = try await renderer.render(spec: surface)
        precondition(surfaceData.starts(with: [0x89, 0x50, 0x4E, 0x47]), "3D 시각자료도 PNG여야 합니다.")
    }
}
