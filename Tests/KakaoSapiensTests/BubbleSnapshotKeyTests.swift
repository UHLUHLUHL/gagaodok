import Foundation

@main
struct BubbleSnapshotKeyTests {
    static func main() {
        let first = BubbleSnapshotKey(content: "$x$", width: 320, query: "", isCurrentHit: false, isDark: false)
        let same = BubbleSnapshotKey(content: "$x$", width: 320.2, query: "", isCurrentHit: false, isDark: false)
        let narrower = BubbleSnapshotKey(content: "$x$", width: 280, query: "", isCurrentHit: false, isDark: false)

        precondition(first == same, "Sub-point width noise must reuse the same rendered snapshot")
        precondition(first != narrower, "A real width change must rerender wrapping")

        let heights = BubbleLayoutHeightCache(capacity: 2)
        heights.insert(148, for: first)
        precondition(heights.height(for: first) == 148,
                     "A recycled rich bubble must restore its settled height before rendering")

        let messageID = UUID()
        let messageHeights = BubbleMessageHeightCache(capacity: 2)
        messageHeights.insert(148, for: messageID, content: "$x$")
        precondition(messageHeights.height(for: messageID, content: "$x$") == 148,
                     "A recreated SwiftUI row must start from its previously settled height")
        precondition(messageHeights.height(for: messageID, content: "$y$") == nil,
                     "An edited message must not reuse the old content height")

        precondition(BubbleRenderRequestDelay.nanoseconds(hasRenderedKey: false, widthChanged: false) == 0,
                     "A newly recreated visible bubble must not wait for resize debounce")
        precondition(BubbleRenderRequestDelay.nanoseconds(hasRenderedKey: true, widthChanged: true) == 300_000_000,
                     "Only a real resize after rendering should be debounced")

        precondition(!BubbleSnapshotReusePolicy.shouldApply(key: first, lastAppliedKey: first),
                     "Reapplying the same NSImage during every SwiftUI layout pass would create a layout loop")
        precondition(BubbleSnapshotReusePolicy.shouldApply(key: first, lastAppliedKey: nil),
                     "A recreated row still needs to restore its cached image once")

        var stability = BubbleHeightStabilityTracker()
        precondition(!stability.observe(72), "The first height sample is not settled yet")
        precondition(!stability.observe(96), "A late font or wrapped row must restart height settling")
        precondition(stability.observe(96), "Two equal consecutive samples mean the full wrapped height is ready")
    }
}
