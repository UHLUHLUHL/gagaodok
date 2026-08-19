import Foundation

@main
struct BubbleSnapshotKeyTests {
    static func main() {
        let first = BubbleSnapshotKey(content: "$x$", width: 320, query: "", isCurrentHit: false, isDark: false)
        let same = BubbleSnapshotKey(content: "$x$", width: 320.2, query: "", isCurrentHit: false, isDark: false)
        let narrower = BubbleSnapshotKey(content: "$x$", width: 280, query: "", isCurrentHit: false, isDark: false)

        precondition(first == same, "Sub-point width noise must reuse the same rendered snapshot")
        precondition(first != narrower, "A real width change must rerender wrapping")
    }
}
