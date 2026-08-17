import SwiftUI
import AppKit

/// 채팅 영역을 마우스로 훑어서 말풍선을 고르는 상태입니다.
///
/// 카카오톡은 글자 단위가 아니라 말풍선 단위로 잡습니다. 드래그가 지나간 말풍선이
/// 통째로 회색이 되고, 복사하면 그 말풍선들의 본문이 순서대로 붙습니다.
/// 그래서 여기서도 좌표만 비교하고 글자 위치는 따지지 않습니다.
public final class BubbleSelectionModel: ObservableObject {
    /// 지금 선택된 말풍선입니다.
    @Published public private(set) var selected: Set<UUID> = []

    /// 드래그 중 그려지는 사각형입니다. 끝나면 nil로 돌아갑니다.
    @Published public private(set) var marquee: CGRect?

    /// 화면에 보이는 말풍선의 위치입니다. LazyVStack이라 보이는 것만 들어옵니다.
    private var frames: [UUID: CGRect] = [:]

    private var anchor: CGPoint?

    /// 지금 ⌘C를 누르면 복사될 글입니다. 화면 쪽에서 선택이 바뀔 때마다 채워 줍니다.
    /// 복사 시점에 계산하지 않는 이유는, 모니터 클로저가 뷰 값을 붙잡으면
    /// 그 뒤에 오간 메시지를 못 보고 옛 내용을 복사하기 때문입니다.
    public var copyText: String = ""

    private var monitor: Any?

    public init() {}

    deinit { stopMonitoringCopy() }

    public var isEmpty: Bool { selected.isEmpty }

    /// ⌘C를 창 단위로 먼저 받아 봅니다.
    ///
    /// `onCopyCommand`로는 안 됩니다. 입력창이 늘 포커스를 쥐고 있어서 ⌘C가 그쪽으로 먼저 가고,
    /// 거기엔 고른 글자가 없으니 클립보드만 비워집니다.
    /// 고른 말풍선이 없으면 그대로 흘려보내므로 입력창의 복사는 평소대로 동작합니다.
    public func startMonitoringCopy() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  !self.copyText.isEmpty,
                  event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.option),
                  Self.isCKey(event) else { return event }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.copyText, forType: .string)
            return nil
        }
    }

    /// 한글 입력 중에는 ⌘C의 문자가 "c"가 아니라 "ㅊ"으로 들어옵니다.
    /// 그래서 글자 대신 자판 위치(키 코드 8 = C)를 먼저 봅니다.
    private static func isCKey(_ event: NSEvent) -> Bool {
        event.keyCode == 8 || event.charactersIgnoringModifiers?.lowercased() == "c"
    }

    public func stopMonitoringCopy() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    public func updateFrames(_ new: [UUID: CGRect]) {
        frames = new
    }

    public func isSelected(_ id: UUID) -> Bool {
        selected.contains(id)
    }

    public func beginDrag(at point: CGPoint) {
        anchor = point
        selected = []
        marquee = CGRect(origin: point, size: .zero)
    }

    public func extendDrag(to point: CGPoint) {
        guard let anchor else { return }
        let rect = CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
        marquee = rect
        // 세로로만 훑어도 그 줄의 말풍선이 잡혀야 자연스럽습니다.
        // 그래서 가로는 무시하고 세로 겹침만 봅니다.
        selected = Set(frames.filter { $0.value.maxY > rect.minY && $0.value.minY < rect.maxY }.keys)
    }

    public func endDrag() {
        anchor = nil
        marquee = nil
    }

    public func clear() {
        anchor = nil
        marquee = nil
        copyText = ""
        guard !selected.isEmpty else { return }
        selected = []
    }
}

/// 말풍선이 자기 위치를 위로 올려보내는 통로입니다.
public struct BubbleFramePreferenceKey: PreferenceKey {
    public static var defaultValue: [UUID: CGRect] { [:] }

    public static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

public extension View {
    /// 이 뷰의 위치를 지정한 좌표계 기준으로 보고합니다.
    func reportsBubbleFrame(id: UUID, in space: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BubbleFramePreferenceKey.self,
                    value: [id: proxy.frame(in: .named(space))]
                )
            }
        )
    }
}
