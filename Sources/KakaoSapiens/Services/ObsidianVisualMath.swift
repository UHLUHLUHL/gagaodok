import Foundation

public enum ObsidianVisualMath {
    public enum MathError: LocalizedError, Equatable {
        case invalidExpression
        case expressionTooLong

        public var errorDescription: String? {
            switch self {
            case .invalidExpression: return "지원하지 않는 그래프 수식입니다."
            case .expressionTooLong: return "그래프 수식이 너무 깁니다."
            }
        }
    }

    public static func evaluate(_ source: String, x: Double, y: Double) throws -> Double? {
        guard source.utf8.count <= 300 else { throw MathError.expressionTooLong }
        var parser = try Parser(source: source, x: x, y: y)
        let result = try parser.parse()
        return result.isFinite ? result : nil
    }

    public static func validateExpression(_ source: String) throws {
        guard source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw MathError.invalidExpression
        }
        guard source.utf8.count <= 300 else { throw MathError.expressionTooLong }
        var parser = try Parser(source: source, x: 0, y: 0)
        _ = try parser.parse()
    }

    public static func validatedVisuals(_ visuals: [ObsidianVisualSpec]) -> [ObsidianVisualSpec] {
        var seenIDs = Set<String>()
        return visuals.filter { visual in
            guard !seenIDs.contains(visual.id), isRenderable(visual) else { return false }
            seenIDs.insert(visual.id)
            return true
        }
    }

    private static func isRenderable(_ visual: ObsidianVisualSpec) -> Bool {
        let finiteBounds = [visual.xMin, visual.xMax, visual.yMin, visual.yMax, visual.zMin, visual.zMax]
            .allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
        guard finiteBounds, visual.xMin < visual.xMax, visual.yMin < visual.yMax, visual.zMin < visual.zMax else {
            return false
        }
        guard !visual.id.isEmpty, visual.id.utf8.count <= 80,
              visual.title.utf8.count <= 200, visual.caption.utf8.count <= 500,
              visual.points.count <= 256, visual.segments.count <= 256 else { return false }
        guard visual.points.allSatisfy(isFinite(_:)), visual.segments.allSatisfy({ isFinite($0.start) && isFinite($0.end) }) else {
            return false
        }
        switch visual.kind {
        case .function2D, .surface3D:
            return (try? validateExpression(visual.expression)) != nil
        case .coordinateDiagram:
            return !visual.points.isEmpty || !visual.segments.isEmpty
        }
    }

    private static func isFinite(_ point: ObsidianVisualPoint) -> Bool {
        [point.x, point.y, point.z].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
            && point.label.utf8.count <= 120
    }

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case plus, minus, multiply, divide, power, leftParen, rightParen, comma
        case end
    }

    private struct Parser {
        let tokens: [Token]
        let x: Double
        let y: Double
        var index = 0

        init(source: String, x: Double, y: Double) throws {
            self.tokens = try Self.tokenize(source)
            self.x = x
            self.y = y
        }

        mutating func parse() throws -> Double {
            let value = try parseAdditive()
            guard peek == .end else { throw MathError.invalidExpression }
            return value
        }

        mutating func parseAdditive() throws -> Double {
            var value = try parseMultiplicative()
            while true {
                switch peek {
                case .plus:
                    advance(); value += try parseMultiplicative()
                case .minus:
                    advance(); value -= try parseMultiplicative()
                default:
                    return value
                }
            }
        }

        mutating func parseMultiplicative() throws -> Double {
            var value = try parseUnary()
            while true {
                switch peek {
                case .multiply:
                    advance(); value *= try parseUnary()
                case .divide:
                    advance()
                    let divisor = try parseUnary()
                    if abs(divisor) < 1e-12 { return .nan }
                    value /= divisor
                default:
                    return value
                }
            }
        }

        mutating func parsePower() throws -> Double {
            var value = try parsePrimary()
            if peek == .power {
                advance()
                let exponent = try parseUnary()
                value = pow(value, exponent)
            }
            return value
        }

        mutating func parseUnary() throws -> Double {
            switch peek {
            case .plus:
                advance(); return try parseUnary()
            case .minus:
                advance(); return -(try parseUnary())
            default:
                return try parsePower()
            }
        }

        mutating func parsePrimary() throws -> Double {
            switch peek {
            case .number(let value):
                advance(); return value
            case .identifier(let name):
                advance()
                switch name {
                case "x": return x
                case "y": return y
                case "pi": return Double.pi
                case "e": return M_E
                default:
                    guard peek == .leftParen else { throw MathError.invalidExpression }
                    advance()
                    let argument = try parseAdditive()
                    guard peek == .rightParen else { throw MathError.invalidExpression }
                    advance()
                    return try apply(name, to: argument)
                }
            case .leftParen:
                advance()
                let value = try parseAdditive()
                guard peek == .rightParen else { throw MathError.invalidExpression }
                advance()
                return value
            default:
                throw MathError.invalidExpression
            }
        }

        func apply(_ name: String, to value: Double) throws -> Double {
            switch name {
            case "sin": return sin(value)
            case "cos": return cos(value)
            case "tan": return tan(value)
            case "asin": return asin(value)
            case "acos": return acos(value)
            case "atan": return atan(value)
            case "sqrt": return sqrt(value)
            case "log": return log(value)
            case "exp": return exp(value)
            case "abs": return abs(value)
            default: throw MathError.invalidExpression
            }
        }

        var peek: Token { tokens[index] }

        mutating func advance() {
            index = min(index + 1, tokens.count - 1)
        }

        static func tokenize(_ source: String) throws -> [Token] {
            let bytes = Array(source.utf8)
            var tokens: [Token] = []
            var cursor = 0
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if byte == 32 || byte == 9 || byte == 10 || byte == 13 {
                    cursor += 1
                    continue
                }
                if byte >= 48 && byte <= 57 || byte == 46 {
                    let start = cursor
                    var hasDigits = false
                    while cursor < bytes.count, bytes[cursor] >= 48, bytes[cursor] <= 57 {
                        hasDigits = true; cursor += 1
                    }
                    if cursor < bytes.count, bytes[cursor] == 46 {
                        cursor += 1
                        while cursor < bytes.count, bytes[cursor] >= 48, bytes[cursor] <= 57 {
                            hasDigits = true; cursor += 1
                        }
                    }
                    if !hasDigits { throw MathError.invalidExpression }
                    if cursor < bytes.count, bytes[cursor] == 101 || bytes[cursor] == 69 {
                        cursor += 1
                        if cursor < bytes.count, bytes[cursor] == 43 || bytes[cursor] == 45 { cursor += 1 }
                        let exponentStart = cursor
                        while cursor < bytes.count, bytes[cursor] >= 48, bytes[cursor] <= 57 { cursor += 1 }
                        if exponentStart == cursor { throw MathError.invalidExpression }
                    }
                    guard let number = Double(String(decoding: bytes[start..<cursor], as: UTF8.self)) else {
                        throw MathError.invalidExpression
                    }
                    tokens.append(.number(number))
                    continue
                }
                if byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 {
                    let start = cursor
                    cursor += 1
                    while cursor < bytes.count,
                          (bytes[cursor] >= 65 && bytes[cursor] <= 90) ||
                          (bytes[cursor] >= 97 && bytes[cursor] <= 122) {
                        cursor += 1
                    }
                    tokens.append(.identifier(String(decoding: bytes[start..<cursor], as: UTF8.self).lowercased()))
                    continue
                }
                let token: Token?
                switch byte {
                case 43: token = .plus
                case 45: token = .minus
                case 42: token = .multiply
                case 47: token = .divide
                case 94: token = .power
                case 40: token = .leftParen
                case 41: token = .rightParen
                case 44: token = .comma
                default: token = nil
                }
                guard let token else { throw MathError.invalidExpression }
                tokens.append(token)
                cursor += 1
                if tokens.count > 256 { throw MathError.invalidExpression }
            }
            tokens.append(.end)
            return tokens
        }
    }
}
