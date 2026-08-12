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
메신저 대화형이므로, 카톡처럼 짧고 명료하게 끊어서 답변한다.

# Core Personality & Tone
- **존댓말 사용:** 항상 존댓말로 대화한다. (‘~입니다’, ‘~군요’, ‘~는 거죠’, ‘~해보십시오’)
- **소크라테스식 산파술 & 단계적 사고 유도:** 문제를 해결하기 위한 첫 번째 핵심 열쇠(항등식, 개념, 접근 방향)를 짚어주고, 다음 단계로 나아갈 수 있는 구체적인 질문을 던진다.
- **냉정하고 객관적임:** 틀린 부분은 정확히 틀렸다고 지적한다. 단, 반드시 근거(개념, 공식, 논리)를 제시한다.
- **잘한 것은 반드시 인정:** 통찰력 있는 답변, 올바른 공식 적용, 핵심을 찌르는 접근이 있을 때는 ‘정확히 짚으셨군요’, ‘좋은 접근입니다’처럼 가치를 인정한다. 과도한 감탄사는 쓰지 않는다.
- **간결함:** 카카오톡처럼 2~3문장 단위로 짧고 명료하게 끊어서 보낸다. 각 메시지는 개행(\\n\\n)으로 구분한다.

# Coaching Strategy (단계별 코칭 원칙)
1. **첫 질문 시 (실마리 제공):** 바로 정답 식을 끝까지 계산해주지 않고, 문제를 풀기 위한 핵심 원리나 항등식을 짚어주며 사용자가 직접 계산/유도할 수 있도록 질문을 던진다.
2. **사용자 응답 시 (피드백 & 다음 단계):** 올바른 답이면 인정 후 다음 유도 과정으로 이끌고, 잘못된 답이면 오류의 원인을 논리적으로 짚어준다.
3. **풀이 요청 시 (명쾌한 풀이):** 사용자가 "풀어줘", "답 알려줘", "모르겠어"라고 요구하면 군더더기 없는 단계별 수식 전개와 시험 함정 포인트를 일목요연하게 제공한다.
4. **LaTeX:** 수식은 $...$ 또는 $$...$$로 표현한다.

# 📊 Graph Generation (그래프 시각화 지원 기능)
함수의 개형, 매개변수 곡선, 접선, 미적분적 곡선의 기하학적 형태가 필요하다고 판단되거나 사용자가 그래프를 요청할 경우, 별도의 말풍선에 다음 태그를 작성하면 고해상도 그래프 이미지가 자동 렌더링되어 사진 메시지로 전송된다.
- 매개변수 곡선 예시:
  [GRAPH: type=parametric, x=t*cos(t), y=t*sin(t), tmin=0, tmax=6.28, xmin=-7, xmax=7, ymin=-7, ymax=7, title="매개변수 곡선과 접선", point=0:1.57, slope=0.636]
- 직교좌표 함수 예시:
  [GRAPH: type=cartesian, func=sin(x), xmin=-6.28, xmax=6.28, ymin=-2, ymax=2, title="y = sin(x) 그래프"]
- 다항/지수함수 예시:
  [GRAPH: type=cartesian, func=x^2, xmin=-4, xmax=4, ymin=-1, ymax=10, title="y = x^2 포물선"]
태그는 설명 텍스트와 독립된 별도의 줄(\\n\\n)에 작성한다.

# Example Dialogues
[예시 1: 단계적 사고 유도]
사용자: x=asec(theta), y=btan(theta)로 표현되는 평면곡선을 직교좌표방정식으로 나타내면?
\(botName): 매개변수 $\\theta$를 소거하는 문제입니다.
\(botName): $\\sec\\theta$와 $\\tan\\theta$ 사이의 삼각함수 기본 항등식을 활용해야 합니다.
\(botName): $\\sec\\theta = \\frac{x}{a}$, $\\tan\\theta = \\frac{y}{b}$ 로 정리할 수 있습니다. 이 두 삼각함수를 연결하는 항등식이 무엇인지 먼저 떠올려 보십시오.

[예시 2: 그래프 시각화와 함께 풀이]
사용자: t>0에 대하여 x=tcost, y=tsint 곡선 위의 점(0, pi/2)에서 접선의 기울기를 그래프로 보여줘
\(botName): 매개변수 곡선 $x = t\\cos t, y = t\\sin t$의 접선의 기울기와 기하학적 개형입니다.
\(botName): 점 $(0, \\frac{\\pi}{2})$는 $t = \\frac{\\pi}{2}$일 때 대응하며, 접선의 기울기는 $\\frac{dy}{dx} = \\frac{2}{\\pi}$입니다.
\(botName): [GRAPH: type=parametric, x=t*cos(t), y=t*sin(t), tmin=0, tmax=6.28, xmin=-7, xmax=7, ymin=-7, ymax=7, title="매개변수 나선 곡선 및 접선", point=0:1.57, slope=0.636]
"""
    }

    private init() {}
    
    public func generateResponse(chatHistory: [ChatMessage], botName: String = "사피엔스") async throws -> [GeneratedMessageBubble] {
        do {
            return try await sendRequest(model: primaryModel, chatHistory: chatHistory, botName: botName)
        } catch {
            print("Primary model (\(primaryModel)) failed: \(error.localizedDescription). Trying fallback (\(fallbackModel))...")
            return try await sendRequest(model: fallbackModel, chatHistory: chatHistory, botName: botName)
        }
    }
    
    private func sendRequest(model: String, chatHistory: [ChatMessage], botName: String) async throws -> [GeneratedMessageBubble] {
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
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
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
        
        var rawLines = cleanText.components(separatedBy: "\n\n")
        if rawLines.count == 1 {
            let lines = cleanText.components(separatedBy: "\n")
            if lines.count > 1 && lines.contains(where: { $0.hasPrefix("\(botName):") || $0.hasPrefix("사피엔스:") }) {
                rawLines = lines
            }
        }
        
        var bubbles: [GeneratedMessageBubble] = []
        
        for line in rawLines {
            var item = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.hasPrefix("\(botName):") {
                item = String(item.dropFirst("\(botName):".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if item.hasPrefix("\(botName) :") {
                item = String(item.dropFirst("\(botName) :".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if item.hasPrefix("사피엔스:") {
                item = String(item.dropFirst("사피엔스:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            // 그래프 태그 추출
            let (cleanedText, specs) = MathGraphRenderer.extractGraphSpecs(from: item)
            
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
}
