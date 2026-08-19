import Foundation

@main
struct ObsidianProviderSchemaTests {
    static func main() {
        let gemini = ObsidianStructuredOutput.preparedNote.geminiGenerationConfig(maxOutputTokens: 1_000)
        let geminiSchema = gemini["responseSchema"] as! [String: Any]
        precondition(!containsKey("additionalProperties", in: geminiSchema),
                     "Gemini rejects additionalProperties in responseSchema")

        let openAI = ObsidianStructuredOutput.preparedNote.openAITextConfig
        let format = openAI["format"] as! [String: Any]
        let openAISchema = format["schema"] as! [String: Any]
        precondition(containsKey("additionalProperties", in: openAISchema),
                     "OpenAI strict JSON Schema requires closed objects")
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
