import Foundation

public struct MathVisualTagExtraction {
    public let cleanedText: String
    public let specs: [MathVisualSpec]
    public let hadFailures: Bool

    public init(cleanedText: String, specs: [MathVisualSpec], hadFailures: Bool) {
        self.cleanedText = cleanedText
        self.specs = specs
        self.hadFailures = hadFailures
    }
}

public enum MathVisualTagParser {
    private static let advancedPattern = #"\[NUMERIC_GRAPH\]([\s\S]*?)\[/NUMERIC_GRAPH\]"#
    private static let legacyPattern = #"\[GRAPH:([^\]]+)\]"#
    private static let maximumAdvancedBytes = 16 * 1_024

    public static func extract(from text: String) -> MathVisualTagExtraction {
        var specs: [MathVisualSpec] = []
        var seenIDs = Set<String>()
        var hadFailures = false
        var cleaned = text

        if let regex = try? NSRegularExpression(pattern: advancedPattern) {
            let matches = regex.matches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
            )
            for match in matches {
                guard let fullRange = Range(match.range(at: 0), in: text),
                      let payloadRange = Range(match.range(at: 1), in: text) else { continue }
                let payload = String(text[payloadRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if payload.utf8.count <= maximumAdvancedBytes,
                   let data = payload.data(using: .utf8),
                   let spec = try? JSONDecoder().decode(MathVisualSpec.self, from: data),
                   (try? MathVisualSampler.validate(spec)) != nil,
                   seenIDs.insert(spec.id).inserted {
                    specs.append(spec)
                } else {
                    hadFailures = true
                }
                cleaned = cleaned.replacingOccurrences(of: String(text[fullRange]), with: "")
            }
        }

        if let regex = try? NSRegularExpression(pattern: legacyPattern) {
            let matches = regex.matches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
            )
            for (index, match) in matches.enumerated() {
                guard let fullRange = Range(match.range(at: 0), in: text),
                      let payloadRange = Range(match.range(at: 1), in: text) else { continue }
                if let spec = legacySpec(from: String(text[payloadRange]), index: index),
                   (try? MathVisualSampler.validate(spec)) != nil,
                   seenIDs.insert(spec.id).inserted {
                    specs.append(spec)
                } else {
                    hadFailures = true
                }
                cleaned = cleaned.replacingOccurrences(of: String(text[fullRange]), with: "")
            }
        }

        return MathVisualTagExtraction(
            cleanedText: normalizedText(cleaned),
            specs: specs,
            hadFailures: hadFailures
        )
    }

    private static func legacySpec(from payload: String, index: Int) -> MathVisualSpec? {
        var values: [String: String] = [:]
        for component in payload.split(separator: ",", omittingEmptySubsequences: true) {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }

        let type = values["type"] ?? "cartesian"
        guard type == "cartesian" || type == "parametric" else { return nil }
        let kind: MathVisualKind = type == "parametric" ? .parametric2D : .function2D
        let expression = values["func"] ?? values["function"] ?? values["y"] ?? ""
        let xExpression = kind == .parametric2D ? (values["x"] ?? "") : ""
        let yExpression = kind == .parametric2D ? (values["y"] ?? "") : ""
        let title = values["title"]?.isEmpty == false ? values["title"]! : "수학 그래프"

        return MathVisualSpec(
            id: "legacy-\(index + 1)",
            kind: kind,
            title: title,
            caption: "",
            expression: kind == .function2D ? expression : "",
            xExpression: xExpression,
            yExpression: yExpression,
            legend: title,
            xLabel: "x",
            yLabel: "y",
            zLabel: "z",
            xMin: number(values, keys: ["xmin", "x_min"], fallback: -5),
            xMax: number(values, keys: ["xmax", "x_max"], fallback: 5),
            yMin: number(values, keys: ["ymin", "y_min"], fallback: -5),
            yMax: number(values, keys: ["ymax", "y_max"], fallback: 5),
            zMin: -1,
            zMax: 1,
            parameterMin: number(values, keys: ["tmin", "t_min"], fallback: 0),
            parameterMax: number(values, keys: ["tmax", "t_max"], fallback: Double.pi * 2),
            initialX: 0,
            initialY: 0,
            contourValue: 0,
            points: [],
            segments: []
        )
    }

    private static func number(
        _ values: [String: String],
        keys: [String],
        fallback: Double
    ) -> Double {
        for key in keys {
            if let raw = values[key], let value = Double(raw) { return value }
        }
        return fallback
    }

    private static func normalizedText(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var previousWasEmpty = false
        for line in lines {
            let trimmedRight = line.replacingOccurrences(
                of: #"[ \t]+$"#,
                with: "",
                options: .regularExpression
            )
            let isEmpty = trimmedRight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isEmpty {
                if !previousWasEmpty { result.append("") }
            } else {
                result.append(trimmedRight)
            }
            previousWasEmpty = isEmpty
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
