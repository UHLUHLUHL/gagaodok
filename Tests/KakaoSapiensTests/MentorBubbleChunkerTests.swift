import Foundation

@main
struct MentorBubbleChunkerTests {
    static func main() {
        let response = #"""
        풀이를 정리하면,

        $$\begin{aligned}
        g''(x) &= \frac{d}{dx}\left[(1+g(x)^3)^{\frac12}\right] \\

        &= \frac32 g(x)^2 g'(x)
        \end{aligned}$$

        따라서 정답은 ④번입니다.
        """#

        let chunks = MentorBubbleChunker.split(response) { line in
            if line.hasPrefix("$$") || line.hasPrefix("\\[") { return true }
            return line.contains("=") && line.contains("\\frac")
        }

        precondition(chunks.count == 3, "Mentor display math must stay between two prose bubbles")
        precondition(chunks[1].hasPrefix("$$\\begin{aligned}"), "The opening delimiter must stay with the formula")
        precondition(chunks[1].hasSuffix("\\end{aligned}$$"), "The closing delimiter must stay with the formula")
        precondition(chunks[1].contains("\n\n"), "Blank lines inside display math must not split the bubble")
    }
}
