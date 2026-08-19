import Foundation

public struct MathVisualChatRenderResult {
    public let attachments: [ChatAttachment]
    public let hadFailures: Bool

    public init(attachments: [ChatAttachment], hadFailures: Bool) {
        self.attachments = attachments
        self.hadFailures = hadFailures
    }
}

@MainActor
public enum MathVisualChatPipeline {
    public static func render(_ extraction: MathVisualTagExtraction) async -> MathVisualChatRenderResult {
        await render(extraction, using: .shared)
    }

    public static func render(
        _ extraction: MathVisualTagExtraction,
        using renderer: MathVisualRenderer
    ) async -> MathVisualChatRenderResult {
        var attachments: [ChatAttachment] = []
        var hadFailures = extraction.hadFailures
        for spec in extraction.specs {
            do {
                let png = try await renderer.render(spec: spec)
                attachments.append(MathVisualAttachmentFactory.make(title: spec.title, png: png))
            } catch {
                hadFailures = true
            }
        }
        return MathVisualChatRenderResult(attachments: attachments, hadFailures: hadFailures)
    }
}
