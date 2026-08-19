import Foundation

@main
struct ObsidianProviderSchemaTests {
    static func main() {
        let gemini = ObsidianStructuredOutput.preparedNote.geminiGenerationConfig(maxOutputTokens: 1_000)
        let geminiSchema = gemini["responseSchema"] as! [String: Any]
        let geminiRequired = geminiSchema["required"] as! [String]
        precondition(geminiRequired.contains("visuals"), "Gemini prepared note schema must require visuals")
        let geminiVisual = visualItem(in: geminiSchema)
        let geminiVisualRequired = geminiVisual["required"] as! [String]
        for key in ["xExpression", "yExpression", "legend", "xLabel", "yLabel", "zLabel",
                    "parameterMin", "parameterMax", "initialX", "initialY", "contourValue"] {
            precondition(geminiVisualRequired.contains(key), "Gemini visual schema must require \(key)")
        }
        precondition(!containsKey("additionalProperties", in: geminiSchema),
                     "Gemini rejects additionalProperties in responseSchema")

        let openAI = ObsidianStructuredOutput.preparedNote.openAITextConfig
        let format = openAI["format"] as! [String: Any]
        let openAISchema = format["schema"] as! [String: Any]
        let openAIRequired = openAISchema["required"] as! [String]
        precondition(openAIRequired.contains("visuals"), "OpenAI prepared note schema must require visuals")
        let openAIVisual = visualItem(in: openAISchema)
        let openAIVisualRequired = openAIVisual["required"] as! [String]
        precondition(openAIVisualRequired.contains("contourValue"), "OpenAI visual schema must require numerical fields")
        precondition(containsKey("additionalProperties", in: openAISchema),
                     "OpenAI strict JSON Schema requires closed objects")
    }

    private static func visualItem(in schema: [String: Any]) -> [String: Any] {
        let properties = schema["properties"] as! [String: Any]
        let visuals = properties["visuals"] as! [String: Any]
        return visuals["items"] as! [String: Any]
    }

    private static func containsKey(_ key: String, in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary[key] != nil { return true }
            return dictionary.values.contains { containsKey(key, in: $0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsKey(key, in: $0) }
        }
        return false
    }
}
