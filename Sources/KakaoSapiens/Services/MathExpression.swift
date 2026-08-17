import Foundation

/// 그래프용 수식 파서.
///
/// 예전 평가기는 문자열에 `sin(x)`가 들어 있는지 훑어보는 방식이라
/// `2*sin(x)`의 계수를 무시했고, 무엇보다 **해석하지 못한 식을 `y = x`로 그렸습니다.**
/// 수학 학습 앱에서 조용히 틀린 그래프를 내보내는 건 안 그리느니만 못하므로,
/// 이제는 제대로 파싱하고 실패하면 `nil`을 돌려줍니다.
public struct MathExpression {
    private let root: Node

    public init?(_ source: String) {
        var parser = Parser(source)
        guard let node = parser.parseExpression(), parser.isAtEnd else { return nil }
        root = node
    }

    /// 변수 값을 넣어 계산합니다. 정의역을 벗어나면(예: `ln(-1)`) nil입니다.
    public func value(_ variables: [String: Double]) -> Double? {
        let result = root.evaluate(variables)
        guard let result, result.isFinite else { return nil }
        return result
    }

    // MARK: - 구문 트리

    private indirect enum Node {
        case number(Double)
        case variable(String)
        case unary(String, Node)
        case binary(String, Node, Node)
        case call(String, Node)

        func evaluate(_ variables: [String: Double]) -> Double? {
            switch self {
            case .number(let value):
                return value
            case .variable(let name):
                return variables[name]
            case .unary(let op, let operand):
                guard let value = operand.evaluate(variables) else { return nil }
                return op == "-" ? -value : value
            case .binary(let op, let lhs, let rhs):
                guard let left = lhs.evaluate(variables), let right = rhs.evaluate(variables) else { return nil }
                switch op {
                case "+": return left + right
                case "-": return left - right
                case "*": return left * right
                case "/": return right == 0 ? nil : left / right
                case "^":
                    // 음수의 분수 거듭제곱은 실수 범위에서 정의되지 않습니다.
                    if left < 0, right != right.rounded() { return nil }
                    return pow(left, right)
                default: return nil
                }
            case .call(let name, let argument):
                guard let value = argument.evaluate(variables) else { return nil }
                switch name {
                case "sin": return sin(value)
                case "cos": return cos(value)
                case "tan": return tan(value)
                case "asin": return abs(value) <= 1 ? asin(value) : nil
                case "acos": return abs(value) <= 1 ? acos(value) : nil
                case "atan": return atan(value)
                case "sinh": return sinh(value)
                case "cosh": return cosh(value)
                case "tanh": return tanh(value)
                case "exp": return exp(value)
                case "ln": return value > 0 ? log(value) : nil
                case "log", "log10": return value > 0 ? log10(value) : nil
                case "sqrt": return value >= 0 ? sqrt(value) : nil
                case "abs": return abs(value)
                case "floor": return value.rounded(.down)
                case "ceil": return value.rounded(.up)
                default: return nil
                }
            }
        }
    }

    // MARK: - 파서

    private struct Parser {
        private let characters: [Character]
        private var index = 0

        private static let functions: Set<String> = [
            "sin", "cos", "tan", "asin", "acos", "atan",
            "sinh", "cosh", "tanh", "exp", "ln", "log", "log10",
            "sqrt", "abs", "floor", "ceil"
        ]
        private static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E]

        init(_ source: String) {
            characters = Array(source.replacingOccurrences(of: " ", with: "").lowercased())
        }

        var isAtEnd: Bool { index >= characters.count }

        private func peek() -> Character? { index < characters.count ? characters[index] : nil }

        private mutating func match(_ character: Character) -> Bool {
            guard peek() == character else { return false }
            index += 1
            return true
        }

        mutating func parseExpression() -> Node? {
            guard var node = parseTerm() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                index += 1
                guard let rhs = parseTerm() else { return nil }
                node = .binary(String(op), node, rhs)
            }
            return node
        }

        private mutating func parseTerm() -> Node? {
            guard var node = parseUnary() else { return nil }
            while true {
                if let op = peek(), op == "*" || op == "/" {
                    index += 1
                    guard let rhs = parseUnary() else { return nil }
                    node = .binary(String(op), node, rhs)
                } else if startsImplicitMultiplication() {
                    // 2x, 3sin(x), 2(x+1) 처럼 곱셈 기호를 생략한 표기를 받아줍니다.
                    guard let rhs = parseUnary() else { return nil }
                    node = .binary("*", node, rhs)
                } else {
                    return node
                }
            }
        }

        private func startsImplicitMultiplication() -> Bool {
            guard let next = peek() else { return false }
            return next.isLetter || next == "(" || next == "π"
        }

        // 단항 마이너스는 거듭제곱보다 느슨하게 묶입니다: -x^2 는 -(x^2) 입니다.
        private mutating func parseUnary() -> Node? {
            if match("-") {
                guard let operand = parseUnary() else { return nil }
                return .unary("-", operand)
            }
            if match("+") { return parseUnary() }
            return parsePower()
        }

        private mutating func parsePower() -> Node? {
            guard let base = parsePrimary() else { return nil }
            if match("^") {
                // 오른쪽 결합이고, 지수에도 부호가 올 수 있습니다: 2^3^2, x^-2
                guard let exponent = parseUnary() else { return nil }
                return .binary("^", base, exponent)
            }
            return base
        }

        private mutating func parsePrimary() -> Node? {
            guard let character = peek() else { return nil }

            if match("(") {
                guard let inner = parseExpression(), match(")") else { return nil }
                return inner
            }

            if character.isNumber || character == "." {
                var literal = ""
                while let next = peek(), next.isNumber || next == "." {
                    literal.append(next)
                    index += 1
                }
                guard let value = Double(literal) else { return nil }
                return .number(value)
            }

            if character.isLetter || character == "π" {
                var name = ""
                while let next = peek(), next.isLetter || next == "π" {
                    name.append(next)
                    index += 1
                }

                if Self.functions.contains(name) {
                    guard match("(") , let argument = parseExpression(), match(")") else { return nil }
                    return .call(name, argument)
                }
                if let constant = Self.constants[name] {
                    return .number(constant)
                }
                // 한 글자짜리는 변수로 봅니다. 여러 글자면 모르는 이름이므로 실패시킵니다.
                guard name.count == 1 else { return nil }
                return .variable(name)
            }

            return nil
        }
    }
}
