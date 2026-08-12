import Foundation

let apiKey = "REDACTED__see_Keychain"
let testUrl = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent?key=\(apiKey)")!

var request = URLRequest(url: testUrl)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")

let prompt = """
사용자 질문: g(x)= (e^x - e^-x)/2, 역함수 g^-1, g^-1'(-1) 값은?
사피엔스 페르소나로 카톡처럼 짧은 문단 3~4개로 답변해줘. 수식은 LaTeX ($...$) 포함.
"""

let body: [String: Any] = [
    "contents": [
        [
            "role": "user",
            "parts": [
                ["text": prompt]
            ]
        ]
    ]
]

request.httpBody = try! JSONSerialization.data(withJSONObject: body)

let semaphore = DispatchSemaphore(value: 0)

let task = URLSession.shared.dataTask(with: request) { data, response, error in
    if let error = error {
        print("API Error: \(error)")
    } else if let data = data {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let candidates = json["candidates"] as? [[String: Any]],
           let first = candidates.first,
           let content = first["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]],
           let text = parts.first?["text"] as? String {
            print("=== Gemini Response ===")
            print(text)
        } else {
            print("Raw Response: \(String(data: data, encoding: .utf8) ?? "")")
        }
    }
    semaphore.signal()
}

task.resume()
semaphore.wait()
