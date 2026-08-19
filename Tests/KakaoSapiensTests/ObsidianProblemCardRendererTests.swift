import Foundation
import AppKit

@main
@MainActor
struct ObsidianProblemCardRendererTests {
    static func main() async throws {
        let htmlURL = URL(fileURLWithPath: "Sources/KakaoSapiens/Resources/problem-sheet.html")
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        precondition(html.contains("background: #ffffff"), "문제지는 시스템 다크 모드와 무관하게 흰색이어야 합니다.")
        precondition(html.contains("window.renderProblem"), "제목과 문제 Markdown을 받는 렌더 진입점이 필요합니다.")
        precondition(!html.contains("http://") && !html.contains("https://"), "문제 카드 렌더링은 네트워크 자원을 사용하면 안 됩니다.")

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
}
