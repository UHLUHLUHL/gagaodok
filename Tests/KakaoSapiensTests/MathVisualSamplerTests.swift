import Foundation

@main
struct MathVisualSamplerTests {
    static func main() throws {
        try testExpressionCompilerRestrictsVariablesAndCodeLikeInput()
        try testReciprocalDoesNotJoinAcrossItsAsymptote()
        try testImplicitCirclePointsStayOnTheRequestedLevelSet()
        try testIntegralFamilyMatchesAnAnalyticIntegral()
        try testRK4MatchesTheExponentialInitialValueProblem()
        try testTypeSpecificValidationRejectsUnsafeSpecifications()
        print("MathVisualSamplerTests passed")
    }

    static func testExpressionCompilerRestrictsVariablesAndCodeLikeInput() throws {
        let expression = try MathExpression.compile("sin(x)+t", allowedVariables: ["x", "t"])
        precondition(abs((expression.value(["x": .pi / 2, "t": 2]) ?? .nan) - 3) < 1e-12)
        precondition(MathExpression("Process(x)") == nil)
        precondition(MathExpression("x;system(t)") == nil)
        expectFailure("허용하지 않은 변수는 컴파일 단계에서 거부해야 합니다.") {
            _ = try MathExpression.compile("x+y", allowedVariables: ["x"])
        }
    }

    static func testReciprocalDoesNotJoinAcrossItsAsymptote() throws {
        let sample = try MathVisualSampler.sample(spec(kind: .function2D, expression: "1/x"))
        precondition(sample.curves.count == 2, "1/x는 x=0의 양쪽 곡선으로 분리되어야 합니다.")
        precondition(sample.curves[0].last!.x < 0)
        precondition(sample.curves[1].first!.x > 0)
    }

    static func testImplicitCirclePointsStayOnTheRequestedLevelSet() throws {
        let visual = spec(
            kind: .implicit2D,
            expression: "x^2+y^2",
            xMin: -1.5, xMax: 1.5, yMin: -1.5, yMax: 1.5,
            contourValue: 1
        )
        let points = try MathVisualSampler.sample(visual).curves.flatMap { $0 }
        precondition(points.count > 100, "단위원의 폐곡선을 표현할 충분한 점이 필요합니다.")
        precondition(points.allSatisfy { abs($0.x * $0.x + $0.y * $0.y - 1) < 0.03 })
    }

    static func testIntegralFamilyMatchesAnAnalyticIntegral() throws {
        let visual = spec(
            kind: .integral2D,
            expression: "x*t",
            xMin: 2, xMax: 2.01, yMin: 0, yMax: 2,
            parameterMin: 0, parameterMax: 1
        )
        let first = try MathVisualSampler.sample(visual).curves[0][0]
        precondition(abs(first.y - 1) < 1e-6, "∫₀¹ 2t dt는 1이어야 합니다.")
    }

    static func testRK4MatchesTheExponentialInitialValueProblem() throws {
        let visual = spec(
            kind: .ode2D,
            expression: "y",
            xMin: 0, xMax: 1, yMin: 0, yMax: 3,
            initialX: 0, initialY: 1
        )
        let curve = try MathVisualSampler.sample(visual).curves[0]
        precondition(abs(curve.first!.x) < 1e-12)
        precondition(abs(curve.last!.x - 1) < 1e-12)
        precondition(abs(curve.last!.y - M_E) < 1e-4, "y'=y의 수치해는 x=1에서 e와 가까워야 합니다.")
    }

    static func testTypeSpecificValidationRejectsUnsafeSpecifications() throws {
        expectFailure("뒤집힌 표시 범위는 거부해야 합니다.") {
            try MathVisualSampler.validate(spec(kind: .function2D, expression: "x", xMin: 1, xMax: -1))
        }
        expectFailure("빈 ODE 우변은 거부해야 합니다.") {
            try MathVisualSampler.validate(spec(kind: .ode2D, expression: ""))
        }
        expectFailure("적분 구간 길이는 양수여야 합니다.") {
            try MathVisualSampler.validate(spec(
                kind: .integral2D, expression: "x*t", parameterMin: 1, parameterMax: 1
            ))
        }
        expectFailure("수식 길이를 제한해야 합니다.") {
            try MathVisualSampler.validate(spec(kind: .function2D, expression: String(repeating: "x+", count: 151) + "x"))
        }
        expectFailure("실행 코드처럼 보이는 문법은 거부해야 합니다.") {
            try MathVisualSampler.validate(spec(kind: .function2D, expression: "x;system(x)"))
        }
    }

    static func spec(
        kind: MathVisualKind,
        expression: String,
        xExpression: String = "",
        yExpression: String = "",
        xMin: Double = -1,
        xMax: Double = 1,
        yMin: Double = -5,
        yMax: Double = 5,
        parameterMin: Double = 0,
        parameterMax: Double = 1,
        initialX: Double = 0,
        initialY: Double = 0,
        contourValue: Double = 0
    ) -> MathVisualSpec {
        MathVisualSpec(
            id: "test", kind: kind, title: "테스트", caption: "",
            expression: expression, xExpression: xExpression, yExpression: yExpression,
            xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax,
            zMin: -5, zMax: 5, parameterMin: parameterMin, parameterMax: parameterMax,
            initialX: initialX, initialY: initialY, contourValue: contourValue,
            points: [], segments: []
        )
    }

    static func expectFailure(_ message: String, _ operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure(message)
        } catch {
            return
        }
    }
}
