import Foundation

public enum MathVisualKind: String, Codable, Equatable, CaseIterable {
    case function2D
    case parametric2D
    case implicit2D
    case integral2D
    case ode2D
    case surface3D
    case coordinateDiagram
}

public struct MathVisualPoint: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var label: String

    public init(x: Double, y: Double, z: Double = 0, label: String = "") {
        self.x = x
        self.y = y
        self.z = z
        self.label = label
    }
}

public struct MathVisualSegment: Codable, Equatable {
    public var start: MathVisualPoint
    public var end: MathVisualPoint
    public var label: String

    public init(start: MathVisualPoint, end: MathVisualPoint, label: String = "") {
        self.start = start
        self.end = end
        self.label = label
    }
}

public struct MathVisualSpec: Codable, Equatable, Identifiable {
    public var id: String
    public var kind: MathVisualKind
    public var title: String
    public var caption: String
    public var expression: String
    public var xExpression: String
    public var yExpression: String
    public var legend: String
    public var xLabel: String
    public var yLabel: String
    public var zLabel: String
    public var xMin: Double
    public var xMax: Double
    public var yMin: Double
    public var yMax: Double
    public var zMin: Double
    public var zMax: Double
    public var parameterMin: Double
    public var parameterMax: Double
    public var initialX: Double
    public var initialY: Double
    public var contourValue: Double
    public var points: [MathVisualPoint]
    public var segments: [MathVisualSegment]

    public init(
        id: String,
        kind: MathVisualKind,
        title: String,
        caption: String,
        expression: String,
        xExpression: String = "",
        yExpression: String = "",
        legend: String = "",
        xLabel: String = "x",
        yLabel: String = "y",
        zLabel: String = "z",
        xMin: Double,
        xMax: Double,
        yMin: Double,
        yMax: Double,
        zMin: Double,
        zMax: Double,
        parameterMin: Double = 0,
        parameterMax: Double = 1,
        initialX: Double = 0,
        initialY: Double = 0,
        contourValue: Double = 0,
        points: [MathVisualPoint],
        segments: [MathVisualSegment]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.caption = caption
        self.expression = expression
        self.xExpression = xExpression
        self.yExpression = yExpression
        self.legend = legend
        self.xLabel = xLabel
        self.yLabel = yLabel
        self.zLabel = zLabel
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
        self.zMin = zMin
        self.zMax = zMax
        self.parameterMin = parameterMin
        self.parameterMax = parameterMax
        self.initialX = initialX
        self.initialY = initialY
        self.contourValue = contourValue
        self.points = points
        self.segments = segments
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, caption, expression, xExpression, yExpression
        case legend, xLabel, yLabel, zLabel
        case xMin, xMax, yMin, yMax, zMin, zMax
        case parameterMin, parameterMax, initialX, initialY, contourValue
        case points, segments
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(MathVisualKind.self, forKey: .kind)
        title = try values.decode(String.self, forKey: .title)
        caption = try values.decode(String.self, forKey: .caption)
        expression = try values.decode(String.self, forKey: .expression)
        xExpression = try values.decodeIfPresent(String.self, forKey: .xExpression) ?? ""
        yExpression = try values.decodeIfPresent(String.self, forKey: .yExpression) ?? ""
        legend = try values.decodeIfPresent(String.self, forKey: .legend) ?? ""
        xLabel = try values.decodeIfPresent(String.self, forKey: .xLabel) ?? "x"
        yLabel = try values.decodeIfPresent(String.self, forKey: .yLabel) ?? "y"
        zLabel = try values.decodeIfPresent(String.self, forKey: .zLabel) ?? "z"
        xMin = try values.decode(Double.self, forKey: .xMin)
        xMax = try values.decode(Double.self, forKey: .xMax)
        yMin = try values.decode(Double.self, forKey: .yMin)
        yMax = try values.decode(Double.self, forKey: .yMax)
        zMin = try values.decode(Double.self, forKey: .zMin)
        zMax = try values.decode(Double.self, forKey: .zMax)
        parameterMin = try values.decodeIfPresent(Double.self, forKey: .parameterMin) ?? 0
        parameterMax = try values.decodeIfPresent(Double.self, forKey: .parameterMax) ?? 1
        initialX = try values.decodeIfPresent(Double.self, forKey: .initialX) ?? 0
        initialY = try values.decodeIfPresent(Double.self, forKey: .initialY) ?? 0
        contourValue = try values.decodeIfPresent(Double.self, forKey: .contourValue) ?? 0
        points = try values.decodeIfPresent([MathVisualPoint].self, forKey: .points) ?? []
        segments = try values.decodeIfPresent([MathVisualSegment].self, forKey: .segments) ?? []
    }
}
