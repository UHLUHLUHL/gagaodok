import Foundation
import AppKit

public struct GeneratedMessageBubble {
    public let text: String
    public let attachment: ChatAttachment?
    
    public init(text: String, attachment: ChatAttachment? = nil) {
        self.text = text
        self.attachment = attachment
    }
}

public actor GeminiService {
    public static let shared = GeminiService()
    
    private let apiKey: String = "REDACTED__see_Keychain"
    private let primaryModel: String = "gemini-3.6-flash"
    private let fallbackModel: String = "gemini-3.5-flash"
    
    private func buildSystemPrompt(botName: String) -> String {
        return """
# Role & Identity
너는 '\(botName)'다. 사용자의 수학 학습 파트너이자 냉철한 코칭 멘토다.
네 이름은 '\(botName)'이며, 자신을 지칭하거나 소개할 때 항상 '\(botName)'라는 이름을 사용한다.
네 임무는 사용자가 암기가 아닌 구조와 원리로 문제를 꿰뚫어 볼 수 있도록, 단계적인 사고를 유도하고 객관적인 목표 지점까지 이끄는 것이다.
문제를 받자마자 바로 답과 최종 풀이를 쏟아내지 않는다. 사용자가 스스로 실마리를 잡고 논리를 전개할 수 있도록 핵심 개념과 유도 질문을 먼저 던진다.
단, 사용자가 명시적으로 풀이나 정답을 요청하거나("풀어줘", "답을 알려줘", "모르겠어", "끝까지 풀어줘" 등) 막힌 지점이 있을 때는 군더더기 없이 명쾌한 전체 풀이와 근거를 제시한다.

# Core Personality & Tone
- **존댓말 사용:** 항상 존댓말로 대화한다. (‘~입니다’, ‘~군요’, ‘~는 거죠’, ‘~해보십시오’)
- **소크라테스식 산파술 & 단계적 사고 유도:** 문제를 해결하기 위한 첫 번째 핵심 열쇠(항등식, 개념, 접근 방향)를 짚어주고, 다음 단계로 나아갈 수 있는 구체적인 질문을 던진다.
- **냉정하고 객관적임:** 틀린 부분은 정확히 틀렸다고 지적한다. 단, 반드시 근거(개념, 공식, 논리)를 제시한다.
- **잘한 것은 반드시 인정:** 통찰력 있는 답변, 올바른 공식 적용, 핵심을 찌르는 접근이 있을 때는 ‘정확히 짚으셨군요’, ‘좋은 접근입니다’처럼 가치를 인정한다. 과도한 감탄사는 쓰지 않는다.

# 💬 카카오톡 메시지 분할 & 수식 가독성 원칙 (매우 중요 ⭐)
카카오톡 메신저 특성상 가독성을 위해 메시지를 자연스러운 호흡으로 끊어서 전송한다.
1. **짧은 인라인 수식:** 문맥 속에 잠깐 등장하는 변수($x, y, t$)나 단순 대입값($t = \\frac{\\pi}{2}$, $x=0$)은 설명 문장 안에 자연스럽게 배치한다.
2. **긴 계산식 & 전개 수식 분리:** 미분식, 전개식, 2줄 이상의 계산식, 등호가 여러 번 이어지는 긴 수식은 **반드시 앞뒤로 줄바꿈 두 번(\\n\\n)을 두어 별도의 독립된 말풍선으로 나누어 전송**한다.
   - 예시 (좋은 분할):
     \(botName): 구한 미분식에 $t = \\frac{\\pi}{2}$를 대입합니다.
     
     \(botName): $$\\frac{dx}{dt} = \\cos \\frac{\\pi}{2} - \\frac{\\pi}{2}\\sin \\frac{\\pi}{2} = -\\frac{\\pi}{2}$$
     $$\\frac{dy}{dt} = \\sin \\frac{\\pi}{2} + \\frac{\\pi}{2}\\cos \\frac{\\pi}{2} = 1$$
     
     \(botName): 따라서 구하고자 하는 접선의 기울기는 다음과 같습니다.
     
     \(botName): $$\\frac{dy}{dx} = \\frac{1}{-\\frac{\\pi}{2}} = -\\frac{2}{\\pi}$$

# 📊 Graph Generation (그래프 시각화 지원 기능)
함수의 개형, 매개변수 곡선, 접선, 미적분 곡선의 기하학적 형태가 필요하다고 판단되거나 사용자가 그래프를 요청할 경우, 별도의 말풍선(\\n\\n)에 다음 태그를 작성하면 고해상도 그래프 이미지가 자동 렌더링되어 사진 메시지로 전송된다.
- 매개변수 곡선 예시:
  [GRAPH: type=parametric, x=t*cos(t), y=t*sin(t), tmin=0, tmax=6.28, xmin=-7, xmax=7, ymin=-7, ymax=7, title="매개변수 곡선과 접선", point=0:1.57, slope=0.636]
- 직교좌표 함수 예시:
  [GRAPH: type=cartesian, func=sin(x), xmin=-6.28, xmax=6.28, ymin=-2, ymax=2, title="y = sin(x) 그래프"]
- 다항/지수함수 예시:
  [GRAPH: type=cartesian, func=x^2, xmin=-4, xmax=4, ymin=-1, ymax=10, title="y = x^2 포물선"]
"""
    }

    private init() {}
    
    public func generateResponse(chatHistory: [ChatMessage], botName: String = "사피엔스", roomId: UUID? = nil) async throws -> [GeneratedMessageBubble] {
        do {
            return try await sendRequest(model: primaryModel, chatHistory: chatHistory, botName: botName, roomId: roomId)
        } catch {
            print("Primary model (\(primaryModel)) failed: \(error.localizedDescription). Trying fallback (\(fallbackModel))...")
            return try await sendRequest(model: fallbackModel, chatHistory: chatHistory, botName: botName, roomId: roomId)
        }
    }
    
    private func sendRequest(model: String, chatHistory: [ChatMessage], botName: String, roomId: UUID?) async throws -> [GeneratedMessageBubble] {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        // Convert chat history to Gemini contents format
        var contents: [[String: Any]] = []
        
        let recentMessages = chatHistory.suffix(20)
        for msg in recentMessages {
            let role = msg.sender == .user ? "user" : "model"
            var parts: [[String: Any]] = []
            
            if !msg.text.isEmpty {
                parts.append(["text": msg.text])
            }
            
            if let attachment = msg.attachment {
                if attachment.type == .image || attachment.mimeType.starts(with: "image/") || attachment.mimeType.contains("pdf") {
                    parts.append([
                        "inlineData": [
                            "mimeType": attachment.mimeType.isEmpty ? "image/jpeg" : attachment.mimeType,
                            "data": attachment.dataBase64
                        ]
                    ])
                } else if !attachment.dataBase64.isEmpty {
                    if let fileData = Data(base64Encoded: attachment.dataBase64),
                       let textContent = String(data: fileData, encoding: .utf8) {
                        parts.append(["text": "--- 첨부파일(\(attachment.fileName)) 내용 ---\n\(textContent)\n--- 첨부파일 끝 ---"])
                    }
                }
            }
            
            if !parts.isEmpty {
                contents.append([
                    "role": role,
                    "parts": parts
                ])
            }
        }
        
        let currentSystemPrompt = buildSystemPrompt(botName: botName)
        
        let requestBody: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": currentSystemPrompt]
                ]
            ],
            "contents": contents,
            "generationConfig": [
                "temperature": 0.3,
                "maxOutputTokens": 2048,
                "topP": 0.95
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("Gemini API Error (\(httpResponse.statusCode)): \(errorText)")
            throw NSError(domain: "GeminiError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorText])
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "GeminiError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }
        
        // 실시간 토큰 사용량 파싱 및 기록
        if let usage = json["usageMetadata"] as? [String: Any] {
            let promptTokens = usage["promptTokenCount"] as? Int ?? 0
            let candidatesTokens = usage["candidatesTokenCount"] as? Int ?? 0
            if let targetRoomId = roomId {
                TokenUsageManager.shared.recordUsage(roomId: targetRoomId, promptTokens: promptTokens, candidatesTokens: candidatesTokens)
            }
        }
        
        guard let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let rawText = firstPart["text"] as? String else {
            throw NSError(domain: "GeminiError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }
        
        return parseResponseIntoBubbles(rawText: rawText, botName: botName)
    }
    
    private func parseResponseIntoBubbles(rawText: String, botName: String) -> [GeneratedMessageBubble] {
        let cleanText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. 기본 문단 분할
        var rawParagraphs = cleanText.components(separatedBy: "\n\n")
        if rawParagraphs.count == 1 {
            let lines = cleanText.components(separatedBy: "\n")
            if lines.count > 1 && lines.contains(where: { $0.hasPrefix("\(botName):") || $0.hasPrefix("사피엔스:") }) {
                rawParagraphs = lines
            }
        }
        
        // 2. 설명 문장과 긴 블록 수식이 한 문단에 붙어 있는 경우 지능적으로 별도 버블로 분리
        var refinedChunks: [String] = []
        for paragraph in rawParagraphs {
            let subChunks = splitTextAndComplexMath(paragraph: paragraph)
            refinedChunks.append(contentsOf: subChunks)
        }
        
        var bubbles: [GeneratedMessageBubble] = []
        
        for item in refinedChunks {
            var text = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("\(botName):") {
                text = String(text.dropFirst("\(botName):".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if text.hasPrefix("\(botName) :") {
                text = String(text.dropFirst("\(botName) :".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if text.hasPrefix("사피엔스:") {
                text = String(text.dropFirst("사피엔스:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            // 그래프 태그 추출
            let (cleanedText, specs) = MathGraphRenderer.extractGraphSpecs(from: text)
            
            if !cleanedText.isEmpty {
                bubbles.append(GeneratedMessageBubble(text: cleanedText))
            }
            
            // 추출된 그래프 스펙 렌더링 후 이미지 말풍선으로 추가
            for spec in specs {
                let graphImage = MathGraphRenderer.shared.renderGraph(spec: spec)
                if let tiff = graphImage.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                    let base64 = jpeg.base64EncodedString()
                    let attachment = ChatAttachment(
                        type: .image,
                        fileName: "\(spec.title).jpg",
                        fileSize: Int64(jpeg.count),
                        fileExtension: "jpg",
                        dataBase64: base64,
                        mimeType: "image/jpeg"
                    )
                    bubbles.append(GeneratedMessageBubble(text: "", attachment: attachment))
                }
            }
        }
        
        if bubbles.isEmpty && !cleanText.isEmpty {
            bubbles.append(GeneratedMessageBubble(text: cleanText))
        }
        
        return bubbles
    }
    
    // 설명 문장과 긴 전개 수식을 분리하는 지능형 스플리터
    private func splitTextAndComplexMath(paragraph: String) -> [String] {
        let lines = paragraph.components(separatedBy: "\n")
        guard lines.count > 1 else { return [paragraph] }
        
        var chunks: [String] = []
        var currentTextBuffer: [String] = []
        var currentMathBuffer: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            let isMathLine = isStandaloneMathLine(trimmed)
            
            if isMathLine {
                // 이전 일반 텍스트가 있으면 먼저 방출
                if !currentTextBuffer.isEmpty {
                    chunks.append(currentTextBuffer.joined(separator: "\n"))
                    currentTextBuffer.removeAll()
                }
                currentMathBuffer.append(trimmed)
            } else {
                // 이전 수식 버퍼가 있으면 먼저 방출
                if !currentMathBuffer.isEmpty {
                    chunks.append(currentMathBuffer.joined(separator: "\n"))
                    currentMathBuffer.removeAll()
                }
                currentTextBuffer.append(trimmed)
            }
        }
        
        if !currentTextBuffer.isEmpty {
            chunks.append(currentTextBuffer.joined(separator: "\n"))
        }
        if !currentMathBuffer.isEmpty {
            chunks.append(currentMathBuffer.joined(separator: "\n"))
        }
        
        return chunks.isEmpty ? [paragraph] : chunks
    }
    
    // 독립된 긴 수식 라인인지 판별 (등호가 있거나 \frac, \int, \lim 등으로 시작/구성된 식)
    private func isStandaloneMathLine(_ line: String) -> Bool {
        if line.starts(with: "$$") || line.starts(with: "\\[") {
            return true
        }
        // $...$ 로 전체 줄이 수식으로만 감싸져 있거나 등호가 포함된 전개식
        if line.starts(with: "$") && line.hasSuffix("$") && line.contains("=") {
            return true
        }
        if (line.contains("\\frac") || line.contains("\\cos") || line.contains("\\sin") || line.contains("\\int")) && line.contains("=") {
            // 한글 설명어가 없는 순수 수식 라인인지 검사
            let koreanCharCount = line.unicodeScalars.filter { $0.value >= 0xAC00 && $0.value <= 0xD7A3 }.count
            if koreanCharCount <= 3 {
                return true
            }
        }
        return false
    }
}
