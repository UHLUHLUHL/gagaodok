import Foundation

/// Obsidian 내보내기의 기존 호출부를 공용 수학 엔진에 연결하는 호환 계층입니다.
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
        let expression = try compile(source)
        return expression.value(["x": x, "y": y])
    }

    public static func validateExpression(_ source: String) throws {
        _ = try compile(source)
    }

    public static func validatedVisuals(_ visuals: [ObsidianVisualSpec]) -> [ObsidianVisualSpec] {
        var seenIDs = Set<String>()
        return visuals.filter { visual in
            guard seenIDs.insert(visual.id).inserted else { return false }
            return (try? MathVisualSampler.validate(visual)) != nil
        }
    }

    private static func compile(_ source: String) throws -> MathExpression {
        do {
            return try MathExpression.compile(source, allowedVariables: ["x", "y"])
        } catch MathExpression.CompileError.expressionTooLong {
            throw MathError.expressionTooLong
        } catch {
            throw MathError.invalidExpression
        }
    }
}
