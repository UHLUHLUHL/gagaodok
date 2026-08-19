import Foundation

@main
struct MathVisualModelTests {
    static func main() throws {
        try testEveryVisualKindRoundTripsWithoutLosingFields()
        try testLegacyVisualDecodesWithSafeDefaults()
        print("MathVisualModelTests passed")
    }

    static func testEveryVisualKindRoundTripsWithoutLosingFields() throws {
        let kinds: [MathVisualKind] = [
            .function2D, .parametric2D, .implicit2D, .integral2D,
            .ode2D, .surface3D, .coordinateDiagram
        ]

        for kind in kinds {
            let spec = MathVisualSpec(
                id: "graph-1",
                kind: kind,
                title: "제목",
                caption: "설명",
                expression: "x+t",
                xExpression: "cos(t)",
                yExpression: "sin(t)",
                legend: "해 곡선",
                xLabel: "x",
                yLabel: "y",
                zLabel: "z",
                xMin: -2,
                xMax: 2,
                yMin: -2,
                yMax: 2,
                zMin: -2,
                zMax: 2,
                parameterMin: 0,
                parameterMax: 1,
                initialX: 0,
                initialY: 1,
                contourValue: 0,
                points: [MathVisualPoint(x: 1, y: 2, z: 3, label: "P")],
                segments: []
            )
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(MathVisualSpec.self, from: data)
            precondition(decoded == spec, "\(kind.rawValue) 명세의 모든 필드가 왕복되어야 합니다.")
        }
    }

    static func testLegacyVisualDecodesWithSafeDefaults() throws {
        let data = Data(#"{"id":"legacy","kind":"function2D","title":"기존","caption":"","expression":"sin(x)","xMin":-3.14,"xMax":3.14,"yMin":-2,"yMax":2,"zMin":-1,"zMax":1,"points":[],"segments":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(MathVisualSpec.self, from: data)

        precondition(decoded.xExpression.isEmpty)
        precondition(decoded.yExpression.isEmpty)
        precondition(decoded.legend.isEmpty)
        precondition(decoded.xLabel == "x")
        precondition(decoded.yLabel == "y")
        precondition(decoded.zLabel == "z")
        precondition(decoded.parameterMin == 0)
        precondition(decoded.parameterMax == 1)
        precondition(decoded.initialX == 0)
        precondition(decoded.initialY == 0)
        precondition(decoded.contourValue == 0)
    }
}
