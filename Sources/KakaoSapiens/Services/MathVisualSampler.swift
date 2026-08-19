import Foundation

public struct MathVisualTriangle: Equatable {
    public let points: [MathVisualPoint]
    public let level: Double
    public let depth: Double

    public init(points: [MathVisualPoint], level: Double, depth: Double) {
        self.points = points
        self.level = level
        self.depth = depth
    }
}

public struct MathVisualSample: Equatable {
    public let curves: [[MathVisualPoint]]
    public let triangles: [MathVisualTriangle]

    public init(curves: [[MathVisualPoint]] = [], triangles: [MathVisualTriangle] = []) {
        self.curves = curves
        self.triangles = triangles
    }
}

public enum MathVisualSampler {
    public enum SamplingError: LocalizedError, Equatable {
        case invalidSpec
        case invalidExpression
        case evaluationBudgetExceeded
        case noFiniteSamples

        public var errorDescription: String? {
            switch self {
            case .invalidSpec: return "그래프 범위나 조건이 올바르지 않습니다."
            case .invalidExpression: return "지원하지 않는 그래프 수식입니다."
            case .evaluationBudgetExceeded: return "그래프 계산량이 안전 제한을 넘었습니다."
            case .noFiniteSamples: return "표시할 수 있는 유한한 그래프 값이 없습니다."
            }
        }
    }

    private static let expressionBudget = 250_000

    public static func validate(_ spec: MathVisualSpec) throws {
        let bounds = [spec.xMin, spec.xMax, spec.yMin, spec.yMax, spec.zMin, spec.zMax,
                      spec.parameterMin, spec.parameterMax, spec.initialX, spec.initialY,
                      spec.contourValue]
        guard bounds.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
              spec.xMin < spec.xMax, spec.yMin < spec.yMax, spec.zMin < spec.zMax,
              !spec.id.isEmpty, spec.id.utf8.count <= 80,
              spec.title.utf8.count <= 200, spec.caption.utf8.count <= 500,
              spec.legend.utf8.count <= 200,
              spec.xLabel.utf8.count <= 40, spec.yLabel.utf8.count <= 40, spec.zLabel.utf8.count <= 40,
              spec.points.count <= 256, spec.segments.count <= 256,
              spec.points.allSatisfy(validPoint(_:)),
              spec.segments.allSatisfy({ validPoint($0.start) && validPoint($0.end) && $0.label.utf8.count <= 120 }) else {
            throw SamplingError.invalidSpec
        }

        do {
            switch spec.kind {
            case .function2D:
                _ = try MathExpression.compile(spec.expression, allowedVariables: ["x"])
            case .parametric2D:
                guard spec.parameterMin < spec.parameterMax else { throw SamplingError.invalidSpec }
                _ = try MathExpression.compile(spec.xExpression, allowedVariables: ["t"])
                _ = try MathExpression.compile(spec.yExpression, allowedVariables: ["t"])
            case .implicit2D:
                _ = try MathExpression.compile(spec.expression, allowedVariables: ["x", "y"])
            case .integral2D:
                guard spec.parameterMin < spec.parameterMax else { throw SamplingError.invalidSpec }
                _ = try MathExpression.compile(spec.expression, allowedVariables: ["x", "t"])
            case .ode2D:
                guard (spec.xMin...spec.xMax).contains(spec.initialX) else { throw SamplingError.invalidSpec }
                _ = try MathExpression.compile(spec.expression, allowedVariables: ["x", "y"])
            case .surface3D:
                _ = try MathExpression.compile(spec.expression, allowedVariables: ["x", "y"])
            case .coordinateDiagram:
                guard !spec.points.isEmpty || !spec.segments.isEmpty else { throw SamplingError.invalidSpec }
            }
        } catch let error as SamplingError {
            throw error
        } catch {
            throw SamplingError.invalidExpression
        }
    }

    public static func sample(_ spec: MathVisualSpec) throws -> MathVisualSample {
        try validate(spec)
        switch spec.kind {
        case .function2D:
            return try sampleFunction(spec)
        case .parametric2D:
            return try sampleParametric(spec)
        case .implicit2D:
            return try sampleImplicit(spec)
        case .integral2D:
            return try sampleIntegral(spec)
        case .ode2D:
            return try sampleODE(spec)
        case .surface3D:
            return try sampleSurface(spec)
        case .coordinateDiagram:
            return MathVisualSample()
        }
    }

    private static func sampleFunction(_ spec: MathVisualSpec) throws -> MathVisualSample {
        let expression = try compile(spec.expression, variables: ["x"])
        let count = 1_200
        let step = (spec.xMax - spec.xMin) / Double(count - 1)
        let visibleRange = spec.yMax - spec.yMin
        let guardLimit = max(abs(spec.yMin), abs(spec.yMax)) + visibleRange * 4
        let jumpLimit = max(1, visibleRange * 4)
        var curves: [[MathVisualPoint]] = []
        var current: [MathVisualPoint] = []

        for index in 0..<count {
            let x = spec.xMin + Double(index) * step
            guard let y = expression.value(["x": x]), abs(y) <= guardLimit else {
                appendCurve(&current, to: &curves)
                continue
            }
            if let previous = current.last, abs(y - previous.y) > jumpLimit {
                appendCurve(&current, to: &curves)
            }
            current.append(MathVisualPoint(x: x, y: y))
        }
        appendCurve(&current, to: &curves)
        guard !curves.isEmpty else { throw SamplingError.noFiniteSamples }
        return MathVisualSample(curves: curves)
    }

    private static func sampleParametric(_ spec: MathVisualSpec) throws -> MathVisualSample {
        let xExpression = try compile(spec.xExpression, variables: ["t"])
        let yExpression = try compile(spec.yExpression, variables: ["t"])
        let count = 1_200
        let step = (spec.parameterMax - spec.parameterMin) / Double(count - 1)
        let jumpLimit = max(spec.xMax - spec.xMin, spec.yMax - spec.yMin) * 4
        var curves: [[MathVisualPoint]] = []
        var current: [MathVisualPoint] = []

        for index in 0..<count {
            let t = spec.parameterMin + Double(index) * step
            guard let x = xExpression.value(["t": t]), let y = yExpression.value(["t": t]) else {
                appendCurve(&current, to: &curves)
                continue
            }
            if let previous = current.last, hypot(x - previous.x, y - previous.y) > jumpLimit {
                appendCurve(&current, to: &curves)
            }
            current.append(MathVisualPoint(x: x, y: y))
        }
        appendCurve(&current, to: &curves)
        guard !curves.isEmpty else { throw SamplingError.noFiniteSamples }
        return MathVisualSample(curves: curves)
    }

    private static func sampleImplicit(_ spec: MathVisualSpec) throws -> MathVisualSample {
        let expression = try compile(spec.expression, variables: ["x", "y"])
        let columns = 320
        let rows = 240
        let xStep = (spec.xMax - spec.xMin) / Double(columns)
        let yStep = (spec.yMax - spec.yMin) / Double(rows)
        var values = Array(repeating: Array<Double?>(repeating: nil, count: columns + 1), count: rows + 1)
        var evaluations = 0

        for row in 0...rows {
            let y = spec.yMin + Double(row) * yStep
            for column in 0...columns {
                evaluations += 1
                guard evaluations <= expressionBudget else { throw SamplingError.evaluationBudgetExceeded }
                let x = spec.xMin + Double(column) * xStep
                values[row][column] = expression.value(["x": x, "y": y]).map { $0 - spec.contourValue }
            }
        }

        var curves: [[MathVisualPoint]] = []
        for row in 0..<rows {
            for column in 0..<columns {
                guard let v0 = values[row][column], let v1 = values[row][column + 1],
                      let v2 = values[row + 1][column + 1], let v3 = values[row + 1][column] else { continue }
                let x0 = spec.xMin + Double(column) * xStep
                let x1 = x0 + xStep
                let y0 = spec.yMin + Double(row) * yStep
                let y1 = y0 + yStep
                let corners = [
                    MathVisualPoint(x: x0, y: y0), MathVisualPoint(x: x1, y: y0),
                    MathVisualPoint(x: x1, y: y1), MathVisualPoint(x: x0, y: y1)
                ]
                let cellValues = [v0, v1, v2, v3]
                let edges = [(0, 1), (1, 2), (2, 3), (3, 0)]
                var crossings: [MathVisualPoint] = []
                for (start, end) in edges where crossesZero(cellValues[start], cellValues[end]) {
                    crossings.append(interpolate(
                        corners[start], corners[end], cellValues[start], cellValues[end]
                    ))
                }
                if crossings.count == 2 {
                    curves.append(crossings)
                } else if crossings.count == 4 {
                    let center = (v0 + v1 + v2 + v3) / 4
                    if center >= 0 {
                        curves.append([crossings[0], crossings[1]])
                        curves.append([crossings[2], crossings[3]])
                    } else {
                        curves.append([crossings[0], crossings[3]])
                        curves.append([crossings[1], crossings[2]])
                    }
                }
            }
        }
        guard !curves.isEmpty else { throw SamplingError.noFiniteSamples }
        return MathVisualSample(curves: curves)
    }

    private static func sampleIntegral(_ spec: MathVisualSpec) throws -> MathVisualSample {
        let expression = try compile(spec.expression, variables: ["x", "t"])
        let count = 600
        let xStep = (spec.xMax - spec.xMin) / Double(count - 1)
        var evaluations = 0
        var curve: [MathVisualPoint] = []

        for index in 0..<count {
            let x = spec.xMin + Double(index) * xStep
            let value = try adaptiveIntegral(
                from: spec.parameterMin,
                to: spec.parameterMax,
                tolerance: 1e-7,
                maxDepth: 12,
                evaluations: &evaluations
            ) { t in
                expression.value(["x": x, "t": t])
            }
            curve.append(MathVisualPoint(x: x, y: spec.initialY + value))
        }
        return MathVisualSample(curves: [curve])
    }

    private static func sampleODE(_ spec: MathVisualSpec) throws -> MathVisualSample {
        let expression = try compile(spec.expression, variables: ["x", "y"])
        let width = spec.xMax - spec.xMin
        let baseStep = min(width / 200, max(1e-5, width / 1_200))
        var evaluations = 0

        func derivative(_ x: Double, _ y: Double) throws -> Double {
            evaluations += 1
            guard evaluations <= expressionBudget else { throw SamplingError.evaluationBudgetExceeded }
            guard let value = expression.value(["x": x, "y": y]) else { throw SamplingError.noFiniteSamples }
            return value
        }

        func integrate(from startX: Double, y startY: Double, to endX: Double) throws -> [MathVisualPoint] {
            guard startX != endX else { return [MathVisualPoint(x: startX, y: startY)] }
            let direction = endX > startX ? 1.0 : -1.0
            var x = startX
            var y = startY
            var points = [MathVisualPoint(x: x, y: y)]
            var steps = 0
            while direction * (endX - x) > 1e-14 {
                guard steps < 1_200 else { throw SamplingError.evaluationBudgetExceeded }
                let h = direction * min(baseStep, abs(endX - x))
                let k1 = try derivative(x, y)
                let k2 = try derivative(x + h / 2, y + h * k1 / 2)
                let k3 = try derivative(x + h / 2, y + h * k2 / 2)
                let k4 = try derivative(x + h, y + h * k3)
                y += h * (k1 + 2 * k2 + 2 * k3 + k4) / 6
                x += h
                guard x.isFinite, y.isFinite else { throw SamplingError.noFiniteSamples }
                if abs(endX - x) < 1e-12 { x = endX }
                points.append(MathVisualPoint(x: x, y: y))
                steps += 1
            }
            return points
        }

        let backward = try integrate(from: spec.initialX, y: spec.initialY, to: spec.xMin).reversed()
        let forward = try integrate(from: spec.initialX, y: spec.initialY, to: spec.xMax).dropFirst()
        let curve = Array(backward) + Array(forward)
        guard curve.count >= 2 else { throw SamplingError.noFiniteSamples }
        return MathVisualSample(curves: [curve])
    }

    private static func sampleSurface(_ spec: MathVisualSpec) throws -> MathVisualSample {
        let expression = try compile(spec.expression, variables: ["x", "y"])
        let count = 48
        let xStep = (spec.xMax - spec.xMin) / Double(count - 1)
        let yStep = (spec.yMax - spec.yMin) / Double(count - 1)
        var grid = Array(repeating: Array<Double?>(repeating: nil, count: count), count: count)
        for row in 0..<count {
            for column in 0..<count {
                let x = spec.xMin + Double(column) * xStep
                let y = spec.yMin + Double(row) * yStep
                grid[row][column] = expression.value(["x": x, "y": y])
            }
        }

        var triangles: [MathVisualTriangle] = []
        for row in 0..<(count - 1) {
            for column in 0..<(count - 1) {
                guard let z00 = grid[row][column], let z10 = grid[row][column + 1],
                      let z01 = grid[row + 1][column], let z11 = grid[row + 1][column + 1] else { continue }
                let x0 = spec.xMin + Double(column) * xStep
                let x1 = x0 + xStep
                let y0 = spec.yMin + Double(row) * yStep
                let y1 = y0 + yStep
                let a = MathVisualPoint(x: x0, y: y0, z: z00)
                let b = MathVisualPoint(x: x1, y: y0, z: z10)
                let c = MathVisualPoint(x: x0, y: y1, z: z01)
                let d = MathVisualPoint(x: x1, y: y1, z: z11)
                triangles.append(triangle([a, b, c], spec: spec))
                triangles.append(triangle([b, d, c], spec: spec))
            }
        }
        guard !triangles.isEmpty else { throw SamplingError.noFiniteSamples }
        return MathVisualSample(triangles: triangles.sorted { $0.depth < $1.depth })
    }

    private static func triangle(_ points: [MathVisualPoint], spec: MathVisualSpec) -> MathVisualTriangle {
        let averageZ = points.map(\.z).reduce(0, +) / Double(points.count)
        let level = max(0, min(1, (averageZ - spec.zMin) / (spec.zMax - spec.zMin)))
        let depth = points.map { $0.x + $0.y + $0.z * 0.15 }.reduce(0, +)
        return MathVisualTriangle(points: points, level: level, depth: depth)
    }

    private static func compile(_ source: String, variables: Set<String>) throws -> MathExpression {
        do {
            return try MathExpression.compile(source, allowedVariables: variables)
        } catch {
            throw SamplingError.invalidExpression
        }
    }

    private static func validPoint(_ point: MathVisualPoint) -> Bool {
        [point.x, point.y, point.z].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
            && point.label.utf8.count <= 120
    }

    private static func appendCurve(_ current: inout [MathVisualPoint], to curves: inout [[MathVisualPoint]]) {
        if current.count >= 2 { curves.append(current) }
        current.removeAll(keepingCapacity: true)
    }

    private static func crossesZero(_ lhs: Double, _ rhs: Double) -> Bool {
        (lhs < 0 && rhs >= 0) || (lhs >= 0 && rhs < 0)
    }

    private static func interpolate(
        _ start: MathVisualPoint,
        _ end: MathVisualPoint,
        _ startValue: Double,
        _ endValue: Double
    ) -> MathVisualPoint {
        let denominator = startValue - endValue
        let ratio = denominator == 0 ? 0.5 : max(0, min(1, startValue / denominator))
        return MathVisualPoint(
            x: start.x + (end.x - start.x) * ratio,
            y: start.y + (end.y - start.y) * ratio
        )
    }

    private static func adaptiveIntegral(
        from a: Double,
        to b: Double,
        tolerance: Double,
        maxDepth: Int,
        evaluations: inout Int,
        function: (Double) -> Double?
    ) throws -> Double {
        func evaluate(_ x: Double) throws -> Double {
            evaluations += 1
            guard evaluations <= expressionBudget else { throw SamplingError.evaluationBudgetExceeded }
            guard let value = function(x), value.isFinite else { throw SamplingError.noFiniteSamples }
            return value
        }

        let midpoint = (a + b) / 2
        let fa = try evaluate(a)
        let fm = try evaluate(midpoint)
        let fb = try evaluate(b)
        let whole = (b - a) * (fa + 4 * fm + fb) / 6

        func recurse(
            _ left: Double, _ right: Double,
            _ fLeft: Double, _ fMiddle: Double, _ fRight: Double,
            _ estimate: Double, _ epsilon: Double, _ depth: Int
        ) throws -> Double {
            let middle = (left + right) / 2
            let leftMiddle = (left + middle) / 2
            let rightMiddle = (middle + right) / 2
            let fLeftMiddle = try evaluate(leftMiddle)
            let fRightMiddle = try evaluate(rightMiddle)
            let leftEstimate = (middle - left) * (fLeft + 4 * fLeftMiddle + fMiddle) / 6
            let rightEstimate = (right - middle) * (fMiddle + 4 * fRightMiddle + fRight) / 6
            let delta = leftEstimate + rightEstimate - estimate
            if depth == 0 || abs(delta) <= 15 * epsilon {
                return leftEstimate + rightEstimate + delta / 15
            }
            return try recurse(
                left, middle, fLeft, fLeftMiddle, fMiddle,
                leftEstimate, epsilon / 2, depth - 1
            ) + recurse(
                middle, right, fMiddle, fRightMiddle, fRight,
                rightEstimate, epsilon / 2, depth - 1
            )
        }

        return try recurse(a, b, fa, fm, fb, whole, tolerance, maxDepth)
    }
}
