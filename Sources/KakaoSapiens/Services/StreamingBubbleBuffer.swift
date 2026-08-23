import Foundation

/// 스트리밍으로 도착하는 글자를 모았다가, 말풍선 하나가 완성됐을 때만 내보냅니다.
///
/// 청크는 아무 데서나 끊깁니다. `$$\frac{1}` 까지만 온 상태에서 그리면 깨진 수식이 잠깐 보였다가
/// 고쳐지는 꼴이 됩니다. 그래서 글자 단위로 그리지 않고, **완성된 문단**만 내보냅니다.
///
/// 안전한 지점은 빈 줄(문단 경계)이면서 열어 둔 구분자가 하나도 없는 곳입니다.
/// 어차피 이 앱은 답변을 문단 단위 말풍선으로 쪼개 보여주므로, 문단이 완성되는 순간이
/// 곧 말풍선이 완성되는 순간입니다. 잃는 것 없이 깨진 화면만 피합니다.
public struct StreamingBubbleBuffer {
    private var pending = ""

    public init() {}

    /// 아직 내보내지 않고 쌓아 둔 글입니다.
    public var buffered: String { pending }

    /// 새로 도착한 조각을 넣고, 이번에 완성된 문단들을 돌려줍니다.
    public mutating func append(_ chunk: String) -> [String] {
        pending += chunk
        var ready: [String] = []
        while let cut = Self.safeCutIndex(in: pending) {
            let piece = String(pending[pending.startIndex..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending = String(pending[cut...])
            if !piece.isEmpty { ready.append(piece) }
        }
        return ready
    }

    /// 스트림이 끝났을 때 남은 것을 모두 비웁니다. 여기서는 구분자가 안 닫혔어도 그대로 내보냅니다.
    /// 모델이 수식을 열어 놓고 끝낸 경우인데, 삼키는 것보다 보여주는 편이 낫습니다.
    public mutating func flush() -> String {
        let rest = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        return rest
    }

    /// 여기서 잘라도 되는 첫 지점을 찾습니다. 없으면 nil입니다.
    static func safeCutIndex(in text: String) -> String.Index? {
        var index = text.startIndex
        var searchFrom = text.startIndex
        while let range = text.range(of: "\n\n", range: searchFrom..<text.endIndex) {
            index = range.upperBound
            if isBalanced(String(text[text.startIndex..<range.lowerBound])) {
                return index
            }
            searchFrom = range.upperBound
        }
        return nil
    }

    /// 이 글이 열어 둔 구분자 없이 끝나는지 봅니다.
    static func isBalanced(_ text: String) -> Bool {
        var inFence = false          // ``` 코드 블록
        var inDisplayMath = false    // $$ 또는 \[
        var inlineMathOpen = false   // $ 하나
        var inGraphTag = false       // [GRAPH: ...]

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            // 코드 블록 안에서는 수식 기호를 세지 않습니다.
            if i + 2 < chars.count, chars[i] == "`", chars[i + 1] == "`", chars[i + 2] == "`" {
                inFence.toggle()
                i += 3
                continue
            }
            if inFence { i += 1; continue }

            // 이스케이프된 달러는 수식이 아닙니다.
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                i += 2
                continue
            }

            if i + 1 < chars.count, chars[i] == "\\", chars[i + 1] == "[" {
                inDisplayMath = true
                i += 2
                continue
            }
            if i + 1 < chars.count, chars[i] == "\\", chars[i + 1] == "]" {
                inDisplayMath = false
                i += 2
                continue
            }

            if i + 1 < chars.count, chars[i] == "$", chars[i + 1] == "$" {
                inDisplayMath.toggle()
                // $$를 열고 닫을 때는 인라인 상태를 끌고 가지 않습니다.
                inlineMathOpen = false
                i += 2
                continue
            }
            if chars[i] == "$" {
                if !inDisplayMath { inlineMathOpen.toggle() }
                i += 1
                continue
            }

            if !inDisplayMath, !inGraphTag, text.dropFirst(i).hasPrefix("[GRAPH:") {
                inGraphTag = true
                i += 1
                continue
            }
            if inGraphTag, chars[i] == "]" {
                inGraphTag = false
                i += 1
                continue
            }

            i += 1
        }
        return !inFence && !inDisplayMath && !inlineMathOpen && !inGraphTag
    }
}

/// 멘토 답변을 말풍선으로 나누되 블록 수식은 시작·끝 표기가 같은 줄에 붙어 있어도 보존합니다.
///
/// 일반 챗봇의 기존 말풍선 규칙을 바꾸지 않도록 멘토 경로에서만 호출합니다.
enum MentorBubbleChunker {
    static func split(
        _ text: String,
        isStandaloneMathLine: (String) -> Bool
    ) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var buffer: [String] = []
        var mathMode: Bool?
        var displayMathClosingDelimiter: String?

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            result.append(buffer.joined(separator: "\n"))
            buffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                if displayMathClosingDelimiter != nil {
                    buffer.append("")
                } else {
                    flushBuffer()
                    mathMode = nil
                }
                continue
            }

            if let closing = displayMathClosingDelimiter {
                buffer.append(trimmed)
                if trimmed.contains(closing) {
                    flushBuffer()
                    displayMathClosingDelimiter = nil
                    mathMode = nil
                }
                continue
            }

            let delimiter: (opening: String, closing: String)? =
                trimmed.contains("$$") ? ("$$", "$$") :
                trimmed.contains("\\[") ? ("\\[", "\\]") : nil
            if let delimiter,
               let opening = trimmed.range(of: delimiter.opening) {
                flushBuffer()
                buffer.append(trimmed)
                let remainder = trimmed[opening.upperBound...]
                if remainder.contains(delimiter.closing) {
                    flushBuffer()
                    mathMode = nil
                } else {
                    mathMode = true
                    displayMathClosingDelimiter = delimiter.closing
                }
                continue
            }

            let isMath = isStandaloneMathLine(trimmed)
            if let mode = mathMode, mode != isMath { flushBuffer() }
            mathMode = isMath
            buffer.append(trimmed)
        }

        flushBuffer()
        return result.isEmpty ? [text] : result
    }
}
