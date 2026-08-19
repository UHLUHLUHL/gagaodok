import Foundation

public enum ObsidianStructuredOutput {
    case episodeScope
    case episodeChunk
    case preparedNote
    case batchCandidates

    public static let maximumAttempts = 2

    public var name: String {
        switch self {
        case .episodeScope: return "obsidian_episode_scope"
        case .episodeChunk: return "obsidian_episode_chunk"
        case .preparedNote: return "obsidian_prepared_note"
        case .batchCandidates: return "obsidian_batch_candidates"
        }
    }

    public var schema: [String: Any] {
        switch self {
        case .episodeScope:
            return Self.object([
                "startTurn": Self.integer,
                "endTurn": Self.integer,
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "relatedTurns": Self.array(Self.integer),
                "unrelatedTurns": Self.array(Self.integer),
                "needsEarlierContext": ["type": "boolean"],
                "reason": Self.string
            ])
        case .episodeChunk:
            return Self.object([
                "startTurn": Self.integer,
                "endTurn": Self.integer,
                "problemStatements": Self.array(Self.string),
                "facts": Self.array(Self.string),
                "ideas": Self.array(Self.string),
                "confusions": Self.array(Self.string),
                "solutionSteps": Self.array(Self.string),
                "answers": Self.array(Self.string),
                "concepts": Self.array(Self.string),
                "unresolved": Self.array(Self.string),
                "coverage": Self.array(Self.coverage)
            ])
        case .preparedNote:
            return Self.object([
                "title": Self.string,
                "problem": Self.string,
                "givens": Self.array(Self.string),
                "ideas": Self.array(Self.string),
                "confusions": Self.array(Self.string),
                "solution": Self.string,
                "answer": Self.string,
                "concepts": Self.array(Self.string),
                "unresolved": Self.array(Self.string),
                "evidenceTurns": Self.array(Self.integer),
                "coverage": Self.array(Self.coverage),
                "visuals": Self.array(Self.visual)
            ])
        case .batchCandidates:
            return Self.object([
                "candidates": Self.array(Self.object([
                    "startTurn": Self.integer,
                    "endTurn": Self.integer,
                    "relatedTurns": Self.array(Self.integer),
                    "unrelatedTurns": Self.array(Self.integer),
                    "title": Self.string,
                    "score": ["type": "number", "minimum": 0, "maximum": 1],
                    "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                    "reason": Self.string
                ]))
            ])
        }
    }

    public func geminiGenerationConfig(maxOutputTokens: Int) -> [String: Any] {
        [
            "maxOutputTokens": maxOutputTokens,
            "responseMimeType": "application/json",
            // Gemini responseSchema는 JSON Schema 전체가 아니라 제한된 subset입니다.
            // 특히 additionalProperties를 전송하면 요청 자체가 400으로 거절됩니다.
            "responseSchema": Self.removingAdditionalProperties(from: schema),
            "thinkingConfig": ["thinkingLevel": "low"]
        ]
    }

    public var openAITextConfig: [String: Any] {
        [
            "verbosity": "low",
            "format": [
                "type": "json_schema",
                "name": name,
                "strict": true,
                "schema": schema
            ]
        ]
    }

    private static let string: [String: Any] = ["type": "string"]
    private static let integer: [String: Any] = ["type": "integer"]
    private static let number: [String: Any] = ["type": "number"]
    private static let coverage: [String: Any] = object([
        "turn": integer,
        "status": ["type": "string", "enum": ["included", "unrelated", "merged"]],
        "reason": string
    ])

    private static let point: [String: Any] = object([
        "x": number,
        "y": number,
        "z": number,
        "label": string
    ])

    private static let segment: [String: Any] = object([
        "start": point,
        "end": point,
        "label": string
    ])

    private static let visual: [String: Any] = object([
        "id": string,
        "kind": ["type": "string", "enum": [
            "function2D", "parametric2D", "implicit2D", "integral2D", "ode2D",
            "surface3D", "coordinateDiagram"
        ]],
        "title": string,
        "caption": string,
        "expression": string,
        "xExpression": string,
        "yExpression": string,
        "legend": string,
        "xLabel": string,
        "yLabel": string,
        "zLabel": string,
        "xMin": number,
        "xMax": number,
        "yMin": number,
        "yMax": number,
        "zMin": number,
        "zMax": number,
        "parameterMin": number,
        "parameterMax": number,
        "initialX": number,
        "initialY": number,
        "contourValue": number,
        "points": array(point),
        "segments": array(segment)
    ])

    private static func array(_ items: [String: Any]) -> [String: Any] {
        ["type": "array", "items": items]
    }

    private static func object(_ properties: [String: [String: Any]]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": properties.keys.sorted(),
            "additionalProperties": false
        ]
    }

    private static func removingAdditionalProperties(from value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, pair in
                guard pair.key != "additionalProperties" else { return }
                result[pair.key] = removingAdditionalProperties(from: pair.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(removingAdditionalProperties(from:))
        }
        return value
    }
}
