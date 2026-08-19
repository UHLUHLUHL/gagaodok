import Foundation

/// 기존 Obsidian 호출부가 공용 PNG 렌더러를 그대로 사용하도록 유지하는 이름입니다.
public typealias ObsidianVisualRenderer = MathVisualRenderer

extension MathVisualRenderer {
    public static func fileName(episodeID: String, visualID: String) -> String {
        "visual-\(ObsidianNoteWriter.sanitizedFilename(episodeID))-\(ObsidianNoteWriter.sanitizedFilename(visualID)).png"
    }
}
