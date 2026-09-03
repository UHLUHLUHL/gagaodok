import Foundation

private struct Failure: Error { let message: String }
private func check(_ v: @autoclosure () -> Bool, _ m: String) throws {
    if !v() { throw Failure(message: m) }
}

private func message(_ text: String) -> ChatMessage {
    ChatMessage(sender: .sapiens, text: text)
}

/// 말풍선을 웹뷰로 그릴지 평문으로 그릴지 정하는 판정입니다.
///
/// 이 판정이 바뀌면 수식이 원문으로 보이거나, 평문이 웹뷰로 가서 느려집니다.
/// 속도를 고치는 동안 결과가 한 글자도 달라지지 않았음을 여기서 확인합니다.
@main private struct Runner {
    static func main() throws {
        // 수식으로 봐야 하는 것
        let math = [
            "$x^2$", "값은 $\\alpha$ 입니다", "\\(a+b\\)", "\\[E=mc^2\\]",
            "\\frac{1}{2}", "\\sqrt{2}",
        ]
        for sample in math {
            try check(message(sample).containsLaTeXOrMarkdown, "수식을 놓쳤다: \(sample)")
        }

        // 마크다운으로 봐야 하는 것
        let markdown = [
            "```swift\ncode\n```", "**굵게**", "별표 하나 * 있음",
            "## 제목", "표 | 구분", "> 인용",
            "# 제목",            // 블록: '# ' 접두사
            "- 목록",            // 블록: '- ' 접두사
            "---",               // 블록: 수평선
            "___",               // 블록: 밑줄 수평선
            "앞줄\n---\n뒷줄",    // 가운데 줄이 수평선
        ]
        for sample in markdown {
            try check(message(sample).containsLaTeXOrMarkdown, "마크다운을 놓쳤다: \(sample)")
        }

        // 평문으로 봐야 하는 것 — 여기가 잘못되면 멀쩡한 글이 웹뷰로 가서 느려집니다
        let plain = [
            "안녕하세요", "오늘 날씨가 좋네요.", "1 + 1 = 2",
            "가격은 3000원입니다", "괄호 (이렇게) 쓴 글",
            "줄바꿈\n두 줄짜리 평문", "하이픈-중간에-있음", "밑줄_중간에_있음",
            "--",                // 두 글자는 수평선이 아님
            "-목록아님",          // '- ' 가 아니라 '-목록'
            "#제목아님",          // '# ' 가 아님
            "1 > 0",             // '> ' 는 인용이지만 여기는 '> 0' 이라 걸린다
        ]
        var plainMismatch: [String] = []
        for sample in plain where message(sample).containsLaTeXOrMarkdown {
            plainMismatch.append(sample)
        }
        // 지금 동작을 그대로 적습니다. "1 > 0"은 '> ' 때문에 마크업으로 잡힙니다.
        try check(plainMismatch == ["1 > 0"],
                  "평문 판정이 달라졌다: \(plainMismatch)")

        // 빈 글
        try check(!message("").containsLaTeXOrMarkdown, "빈 글이 마크업으로 잡혔다")

        // 시각 표시 — DateFormatter를 재사용해도 글자가 달라지면 안 됩니다.
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 3
        components.hour = 15; components.minute = 7
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let afternoon = calendar.date(from: components)!
        components.hour = 9; components.minute = 5
        let morning = calendar.date(from: components)!

        let pm = ChatMessage(sender: .user, text: "x", timestamp: afternoon).formattedTime
        let am = ChatMessage(sender: .user, text: "x", timestamp: morning).formattedTime
        try check(pm == "오후 3:07", "오후 시각 표시가 달라졌다: \(pm)")
        try check(am == "오전 9:05", "오전 시각 표시가 달라졌다: \(am)")
        // 같은 시각은 몇 번을 물어도 같아야 합니다(포매터를 공유해도).
        try check(ChatMessage(sender: .user, text: "y", timestamp: afternoon).formattedTime == pm,
                  "같은 시각이 두 번 다르게 나왔다")

        print("\(math.count + markdown.count + plain.count + 4) markup and time checks passed")
    }
}
