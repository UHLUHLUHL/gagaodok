import Foundation
import JavaScriptCore

@main
struct BubbleMathFormattingTests {
    static func main() throws {
        let htmlURL = URL(fileURLWithPath: "Sources/KakaoSapiens/Resources/bubble.html")
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        guard let start = html.range(of: "        function autoAlignLongMath(formula) {")?.lowerBound,
              let end = html.range(of: "\n        // 의미 단위로도", range: start..<html.endIndex)?.lowerBound else {
            fatalError("autoAlignLongMath source not found")
        }

        let functionSource = String(html[start..<end])
        let context = JSContext()!
        context.exceptionHandler = { _, exception in
            fatalError("JavaScript error: \(exception?.toString() ?? "unknown")")
        }
        context.evaluateScript(functionSource)

        let formula = #"\mathbf{(f^{-1})''(y) = -\frac{f''(x)}{[f'(x)]^3}} \quad (\text{단, } f(x) = y)"#
        let encoded = try JSONSerialization.data(withJSONObject: [formula])
        let literal = String(data: encoded, encoding: .utf8)!
        let formatted = context.evaluateScript("autoAlignLongMath(\(literal)[0])")!.toString()!

        precondition(formatted.contains(#"\\"#),
                     "A long trailing condition must be moved to a deliberate second math row")
        precondition(formatted.contains(#"(\text{단, } f(x) = y)"#),
                     "The trailing condition must stay intact instead of wrapping only the final y")
    }
}
