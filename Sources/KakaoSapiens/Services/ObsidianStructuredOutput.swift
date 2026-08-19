import Foundation

public enum ObsidianStructuredOutput {
    case episodeScope
    case episodeChunk
    case preparedNote

    public static let maximumAttempts = 2

    public var name: String {
        switch self {
        case .episodeScope: return "obsidian_episode_scope"
        case .episodeChunk: return "obsidian_episode_chunk"
        case .preparedNote: return "obsidian_prepared_note"
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
                "coverage": Self.array(Self.coverage)
            ])
        }
    }

    public func geminiGenerationConfig(maxOutputTokens: Int) -> [String: Any] {
        [
            "maxOutputTokens": maxOutputTokens,
            "responseMimeType": "application/json",
            "responseSchema": schema,
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
    private static let coverage: [String: Any] = object([
        "turn": integer,
        "status": ["type": "string", "enum": ["included", "unrelated", "merged"]],
        "reason": string
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
}
