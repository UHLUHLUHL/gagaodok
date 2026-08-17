import Foundation
import AppKit

public struct GeneratedMessageBubble {
    public let text: String
    public let attachment: ChatAttachment?
    public let kind: MessageKind

    public init(text: String, attachment: ChatAttachment? = nil, kind: MessageKind = .speech) {
        self.text = text
        self.attachment = attachment
        self.kind = kind
    }
}

public struct GeneratedAIResponse {
    public let rawText: String
    public let bubbles: [GeneratedMessageBubble]

    public init(rawText: String, bubbles: [GeneratedMessageBubble]) {
        self.rawText = rawText
        self.bubbles = bubbles
    }
}


/// 스트림 조각을 받아 완성된 말풍선만 밖으로 내보냅니다.
///
/// 버퍼는 값 타입이라 스트림 콜백이 여러 번 불려도 상태를 이어가려면 담아 둘 곳이 필요합니다.
/// 문단이 완성되면 기존 말풍선 분리기에 그대로 넘기므로, 그래프 태그 처리나
/// 이름 접두사 제거 같은 규칙이 스트리밍에서도 똑같이 적용됩니다.
public actor StreamBubbleSink {
    private var buffer = StreamingBubbleBuffer()
    private let botName: String
    private let onBubble: @Sendable (GeneratedMessageBubble) async -> Void
    private let makeBubbles: @Sendable (String, Bool) async -> [GeneratedMessageBubble]

    /// 이 턴이 상황극이라고 이미 아는지.
    ///
    /// 문단은 완성되는 대로 화면에 붙기 때문에, 첫 문단을 붙일 때는 뒤에 따옴표 대사가
    /// 나올지 알 수 없습니다. 그래서 지난 턴에서 얻은 값으로 시작합니다.
    /// 상황극을 처음 시작하는 턴에서만, 첫 대사가 나오기 전의 묘사가 대사 말풍선으로
    /// 나옵니다. 그 다음 턴부터는 앞 턴이 근거가 되어 첫 문단부터 제대로 갈립니다.
    private var roleplayEstablished: Bool

    public init(
        botName: String,
        roleplayEstablished: Bool = false,
        onBubble: @escaping @Sendable (GeneratedMessageBubble) async -> Void,
        makeBubbles: @escaping @Sendable (String, Bool) async -> [GeneratedMessageBubble]
    ) {
        self.botName = botName
        self.roleplayEstablished = roleplayEstablished
        self.onBubble = onBubble
        self.makeBubbles = makeBubbles
    }

    public func consume(_ piece: String) async {
        for paragraph in buffer.append(piece) { await handle(paragraph) }
    }

    public func finish() async {
        let rest = buffer.flush()
        guard !rest.isEmpty else { return }
        await handle(rest)
    }

    private func handle(_ paragraph: String) async {
        if RoleplayParser.establishesRoleplay(paragraph) { roleplayEstablished = true }
        for bubble in await makeBubbles(paragraph, roleplayEstablished) { await onBubble(bubble) }
    }
}


/// 답변 한 덩이를 카카오톡 말풍선 여러 개로 가릅니다.
///
/// 네트워크를 모릅니다. 글자만 보고 판단하므로 따로 시험해 볼 수 있습니다.
extension GeminiService {
    /// - Parameter roleplay: 이 턴이 상황극임이 확인됐는지. 참일 때만 따옴표 없는
    ///   문단을 묘사로 봅니다. 잡담에서는 대사에 따옴표를 치지 않으므로, 이 조건이
    ///   없으면 평범한 대화가 통째로 묘사가 됩니다.
    func parseResponseIntoBubbles(
        rawText: String,
        botName: String,
        roleplay: Bool = false
    ) -> [GeneratedMessageBubble] {
        let cleanText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        var paragraphs = cleanText.components(separatedBy: "\n\n")
        if paragraphs.count == 1 {
            let lines = cleanText.components(separatedBy: "\n")
            if lines.contains(where: { $0.hasPrefix("\(botName):") || $0.hasPrefix("사피엔스:") }) { paragraphs = lines }
        }

        // 한 번에 받는 경로에서는 답변 전체가 여기 들어오므로, 뒤쪽 문단의 따옴표를
        // 보고 앞쪽 문단까지 제대로 가를 수 있습니다. 스트리밍 경로는 문단이 하나씩
        // 들어오므로 호출하는 쪽이 지금까지 본 것을 `roleplay`로 알려 줍니다.
        let isRoleplay = roleplay || paragraphs.contains { RoleplayParser.establishesRoleplay($0) }

        var chunks: [String] = []
        for paragraph in paragraphs { chunks.append(contentsOf: splitTextAndComplexMath(paragraph: paragraph)) }
        var bubbles: [GeneratedMessageBubble] = []
        for item in chunks {
            var text = item.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["\(botName):", "\(botName) :", "사피엔스:"] where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            let classified = RoleplayParser.classify(text, roleplayEstablished: isRoleplay)
            text = classified.text
            let (cleanedText, allSpecs) = MathGraphRenderer.extractGraphSpecs(from: text)
            if !cleanedText.isEmpty {
                bubbles.append(GeneratedMessageBubble(text: cleanedText, kind: classified.kind))
            }
            // 해석하지 못하는 식은 그래프를 만들지 않습니다. 틀린 그림을 내보내는 것보다 낫습니다.
            let specs = allSpecs.filter { MathGraphRenderer.canRender($0) }
            for spec in specs {
                let image = MathGraphRenderer.shared.renderGraph(spec: spec)
                if let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                    bubbles.append(GeneratedMessageBubble(
                        text: "",
                        attachment: ChatAttachment(
                            type: .image,
                            fileName: "\(spec.title).jpg",
                            fileSize: Int64(jpeg.count),
                            fileExtension: "jpg",
                            dataBase64: jpeg.base64EncodedString(),
                            mimeType: "image/jpeg"
                        )
                    ))
                }
            }
        }
        if bubbles.isEmpty && !cleanText.isEmpty { bubbles.append(GeneratedMessageBubble(text: cleanText)) }
        return bubbles
    }

    func splitTextAndComplexMath(paragraph: String) -> [String] {
        let lines = paragraph.components(separatedBy: "\n")
        guard lines.count > 1 else { return [paragraph] }
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
            guard !trimmed.isEmpty else { continue }

            if let closing = displayMathClosingDelimiter {
                buffer.append(trimmed)
                if trimmed == closing {
                    flushBuffer()
                    displayMathClosingDelimiter = nil
                    mathMode = nil
                }
                continue
            }

            if trimmed == "$$" || trimmed == "\\[" {
                flushBuffer()
                mathMode = true
                displayMathClosingDelimiter = trimmed == "$$" ? "$$" : "\\]"
                buffer.append(trimmed)
                continue
            }

            let isMath = isStandaloneMathLine(trimmed)
            if let mode = mathMode, mode != isMath {
                flushBuffer()
            }
            mathMode = isMath
            buffer.append(trimmed)
        }
        flushBuffer()
        return result.isEmpty ? [paragraph] : result
    }

    func isStandaloneMathLine(_ line: String) -> Bool {
        if line.hasPrefix("$$") || line.hasPrefix("\\[") { return true }
        if line.hasPrefix("$") && line.hasSuffix("$") && line.contains("=") { return true }
        if line.contains("=") && ["\\frac", "\\cos", "\\sin", "\\int", "\\lim"].contains(where: line.contains) {
            let korean = line.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
            return korean <= 3
        }
        return false
    }
}
