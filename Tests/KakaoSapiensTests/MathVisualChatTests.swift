import Foundation
import AppKit

@main
@MainActor
struct MathVisualChatTests {
    static func main() async throws {
        testLegacyGraphTagBecomesCommonSpec()
        testAdvancedGraphBlockDecodesStrictSpec()
        testMalformedDuplicateAndOversizedBlocksAreRejectedSafely()
        try await testRenderedGraphBecomesPNGAttachment()
        try await testChatPipelineKeepsValidImagesAndReportsRejectedGraphs()
        print("MathVisualChatTests passed")
    }

    static func testLegacyGraphTagBecomesCommonSpec() {
        let input = #"""
        설명

        [GRAPH: type=cartesian, func=sin(x), xmin=-3.14, xmax=3.14, ymin=-2, ymax=2, title="사인"]
        """#
        let parsed = MathVisualTagParser.extract(from: input)
        precondition(parsed.cleanedText == "설명")
        precondition(parsed.specs.count == 1)
        precondition(parsed.specs[0].kind == .function2D)
        precondition(parsed.specs[0].expression == "sin(x)")
        precondition(parsed.specs[0].title == "사인")
        precondition(!parsed.hadFailures)
    }

    static func testAdvancedGraphBlockDecodesStrictSpec() {
        let parsed = MathVisualTagParser.extract(from: "설명\n\n\(advancedBlock(id: "graph-1"))")
        precondition(parsed.cleanedText == "설명")
        precondition(parsed.specs.count == 1)
        precondition(parsed.specs[0].kind == .implicit2D)
        precondition(parsed.specs[0].contourValue == 1)
        precondition(parsed.specs[0].legend == "F(x,y)=1")
        precondition(!parsed.hadFailures)
    }

    static func testMalformedDuplicateAndOversizedBlocksAreRejectedSafely() {
        let malformed = MathVisualTagParser.extract(from: "본문\n\n[NUMERIC_GRAPH]{bad json}[/NUMERIC_GRAPH]")
        precondition(malformed.cleanedText == "본문")
        precondition(malformed.specs.isEmpty && malformed.hadFailures)

        let duplicate = MathVisualTagParser.extract(from: advancedBlock(id: "same") + "\n" + advancedBlock(id: "same"))
        precondition(duplicate.specs.count == 1)
        precondition(duplicate.hadFailures)

        let oversized = MathVisualTagParser.extract(from: "본문\n[NUMERIC_GRAPH]" + String(repeating: "a", count: 16_385) + "[/NUMERIC_GRAPH]")
        precondition(oversized.cleanedText == "본문")
        precondition(oversized.specs.isEmpty && oversized.hadFailures)

        let executable = advancedBlock(id: "unsafe").replacingOccurrences(of: "x^2+y^2", with: "x;system(y)")
        let rejected = MathVisualTagParser.extract(from: "안전한 설명\n" + executable)
        precondition(rejected.cleanedText == "안전한 설명")
        precondition(rejected.specs.isEmpty && rejected.hadFailures)
    }

    static func testRenderedGraphBecomesPNGAttachment() async throws {
        let parsed = MathVisualTagParser.extract(from: advancedBlock(id: "png"))
        let renderer = MathVisualRenderer(
            shellURL: URL(fileURLWithPath: "Sources/KakaoSapiens/Resources/visual-sheet.html")
        )
        let png = try await renderer.render(spec: parsed.specs[0])
        let attachment = MathVisualAttachmentFactory.make(title: "단위원 / 그래프", png: png)

        precondition(attachment.fileExtension == "png")
        precondition(attachment.mimeType == "image/png")
        precondition(!attachment.fileName.contains("/"))
        let decoded = Data(base64Encoded: attachment.dataBase64)!
        precondition(decoded.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    static func testChatPipelineKeepsValidImagesAndReportsRejectedGraphs() async throws {
        let renderer = MathVisualRenderer(
            shellURL: URL(fileURLWithPath: "Sources/KakaoSapiens/Resources/visual-sheet.html")
        )
        let valid = MathVisualTagParser.extract(from: advancedBlock(id: "pipeline"))
        let rendered = await MathVisualChatPipeline.render(valid, using: renderer)
        precondition(rendered.attachments.count == 1)
        precondition(!rendered.hadFailures)

        let invalid = MathVisualTagParser.extract(from: "[NUMERIC_GRAPH]{bad}[/NUMERIC_GRAPH]")
        let rejected = await MathVisualChatPipeline.render(invalid, using: renderer)
        precondition(rejected.attachments.isEmpty)
        precondition(rejected.hadFailures)
    }

    static func advancedBlock(id: String) -> String {
        """
        [NUMERIC_GRAPH]
        {"id":"\(id)","kind":"implicit2D","title":"단위원","caption":"","expression":"x^2+y^2","xExpression":"","yExpression":"","legend":"F(x,y)=1","xLabel":"x","yLabel":"y","zLabel":"","xMin":-2,"xMax":2,"yMin":-2,"yMax":2,"zMin":-1,"zMax":1,"parameterMin":0,"parameterMax":1,"initialX":0,"initialY":0,"contourValue":1,"points":[],"segments":[]}
        [/NUMERIC_GRAPH]
        """
    }
}
