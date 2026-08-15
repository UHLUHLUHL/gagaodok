import SwiftUI
import AppKit

/// 창 밝기를 조절하는 헤더 우상단의 얇은 슬라이더입니다.
///
/// SwiftUI 제스처로 만들었을 때는 창 드래그와 계속 부딪혔습니다. 헤더 전체를 덮은
/// 드래그용 NSView가 같은 클릭을 함께 받아, 손잡이와 창이 같이 움직였습니다.
/// hitTest로도 mouseDown 위치 검사로도 완전히 막히지 않았습니다.
///
/// 그래서 슬라이더 자체를 NSView로 만듭니다. AppKit은 겹친 형제 뷰 중 위에 있는 것에
/// 이벤트를 주고, 이 뷰가 mouseDown을 받아 삼키므로 드래그용 뷰까지 내려가지 않습니다.
/// 부딪힐 여지 자체가 사라집니다.
public struct BrightnessSlider: NSViewRepresentable {
    @Binding var value: Double
    /// 이 값 아래로는 내려가지 않습니다. 창이 아예 안 보이면 되돌릴 방법이 없습니다.
    public static let minimum: Double = 0.35

    public init(value: Binding<Double>) {
        self._value = value
    }

    public func makeNSView(context: Context) -> BrightnessSliderView {
        let view = BrightnessSliderView()
        view.value = value
        view.onChange = { context.coordinator.commit($0) }
        return view
    }

    public func updateNSView(_ nsView: BrightnessSliderView, context: Context) {
        context.coordinator.parent = self
        if abs(nsView.value - value) > 0.0001 {
            nsView.value = value
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator {
        var parent: BrightnessSlider
        init(_ parent: BrightnessSlider) { self.parent = parent }
        func commit(_ newValue: Double) { parent.value = newValue }
    }
}

public final class BrightnessSliderView: NSView {
    var onChange: ((Double) -> Void)?

    var value: Double = 1.0 {
        didSet { needsDisplay = true }
    }

    private var isHovering = false { didSet { needsDisplay = true } }
    private var isDragging = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    private let knobRadius: CGFloat = 5.0
    private let trackHeight: CGFloat = 2.5

    public override var intrinsicContentSize: NSSize { NSSize(width: 62, height: 16) }
    public override var isFlipped: Bool { true }

    // 손잡이가 양 끝에서 잘리지 않도록 안쪽으로 물려 둡니다.
    private var travel: CGRect {
        bounds.insetBy(dx: knobRadius, dy: 0)
    }

    private var knobCenter: CGPoint {
        let t = CGFloat((value - BrightnessSlider.minimum) / (1.0 - BrightnessSlider.minimum))
        return CGPoint(x: travel.minX + travel.width * t, y: bounds.midY)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { isHovering = true }
    public override func mouseExited(with event: NSEvent) { isHovering = false }

    /// 얇은 막대라 정확히 집기 어렵습니다. 세로로는 뷰 전체를 받아 줍니다.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    public override func mouseDown(with event: NSEvent) {
        isDragging = true
        apply(event)
    }

    public override func mouseDragged(with event: NSEvent) {
        apply(event)
    }

    public override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    private func apply(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let t = max(0, min(1, (local.x - travel.minX) / max(travel.width, 1)))
        let newValue = BrightnessSlider.minimum + (1.0 - BrightnessSlider.minimum) * Double(t)
        guard abs(newValue - value) > 0.0001 else { return }
        value = newValue
        onChange?(newValue)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        let trackRect = CGRect(
            x: travel.minX, y: bounds.midY - trackHeight / 2,
            width: travel.width, height: trackHeight
        )
        let filledRect = CGRect(
            x: trackRect.minX, y: trackRect.minY,
            width: max(0, knobCenter.x - trackRect.minX), height: trackHeight
        )

        // 남은 구간
        ctx.setFillColor(NSColor(white: dark ? 1 : 0, alpha: dark ? 0.22 : 0.18).cgColor)
        ctx.addPath(CGPath(roundedRect: trackRect, cornerWidth: trackHeight / 2, cornerHeight: trackHeight / 2, transform: nil))
        ctx.fillPath()

        // 지나온 구간
        ctx.setFillColor(NSColor(white: dark ? 1 : 0, alpha: dark ? 0.55 : 0.42).cgColor)
        ctx.addPath(CGPath(roundedRect: filledRect, cornerWidth: trackHeight / 2, cornerHeight: trackHeight / 2, transform: nil))
        ctx.fillPath()

        // 손잡이. 잡고 있는 동안 살짝 커져 지금 만지고 있다는 걸 알려 줍니다.
        let r = knobRadius + (isDragging ? 1.1 : (isHovering ? 0.6 : 0))
        let knobRect = CGRect(x: knobCenter.x - r, y: bounds.midY - r, width: r * 2, height: r * 2)

        ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 2,
                      color: NSColor(white: 0, alpha: 0.35).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: knobRect)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        // 밝은 배경에서 손잡이가 묻히지 않게 얇은 테두리를 둡니다.
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.12).cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokeEllipse(in: knobRect.insetBy(dx: 0.25, dy: 0.25))
    }
}

/// 창 전체의 투명도를 바꿉니다.
///
/// 예전에는 SwiftUI 쪽에 `.opacity()`를 걸었는데, 그러면 불투명한 창 배경 위에서
/// 내용만 흐려져 밝기가 낮아진 것처럼 보였습니다. 창 자체에 걸어야 뒤가 비칩니다.
public struct WindowAlphaSetter: NSViewRepresentable {
    var alpha: Double

    public init(alpha: Double) {
        self.alpha = alpha
    }

    public func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    public func updateNSView(_ nsView: NSView, context: Context) {
        let target = alpha
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if abs(window.alphaValue - CGFloat(target)) > 0.001 {
                window.alphaValue = CGFloat(target)
            }
        }
    }
}
