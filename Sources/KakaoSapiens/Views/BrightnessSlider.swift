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
public enum BrightnessSliderConfig {
    /// 이 값 아래로는 내려가지 않습니다. 창이 아예 안 보이면 되돌릴 방법이 없습니다.
    public static let minimum: Double = 0.35
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
        let t = CGFloat((value - BrightnessSliderConfig.minimum) / (1.0 - BrightnessSliderConfig.minimum))
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

    /// 이 뷰 위에서 누른 클릭으로는 창이 움직이지 않게 합니다.
    ///
    /// 진짜 원인이 여기 있었습니다. 슬라이더가 창 타이틀바 높이 안에 놓여 있어,
    /// AppKit이 뷰 계층보다 위에서 타이틀바 드래그를 가로챕니다. hitTest도,
    /// mouseDown 위치 검사도, NSView로 바꾼 것도 그래서 소용이 없었습니다.
    /// 이 속성이 그 판단을 뒤집는 전용 스위치입니다.
    public override var mouseDownCanMoveWindow: Bool { false }

    /// 창이 비활성일 때도 첫 클릭이 바로 먹히게 합니다.
    /// 이게 없으면 다른 앱을 보다 돌아왔을 때 한 번은 헛치게 됩니다.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        let newValue = BrightnessSliderConfig.minimum + (1.0 - BrightnessSliderConfig.minimum) * Double(t)
        guard abs(newValue - value) > 0.0001 else { return }
        value = newValue
        window?.alphaValue = CGFloat(newValue)
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

/// 타이틀바 오른쪽에 슬라이더를 얹는 액세서리입니다.
///
/// 창이 `.titled + .fullSizeContentView`라 위쪽 약 28pt는 타이틀바가 뷰 계층보다
/// 위에서 드래그를 가져갑니다. 그 안에 컨트롤을 두면 무슨 수를 써도 클릭이 창 이동에
/// 먹힙니다. AppKit이 정해 둔 방법이 이 액세서리이고, 여기 올린 뷰는 정상적으로
/// 자기 이벤트를 받습니다.
public final class BrightnessTitlebarAccessory: NSTitlebarAccessoryViewController {
    public let slider = BrightnessSliderView()

    public init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 86, height: 28))
        slider.frame = NSRect(x: 6, y: 6, width: 62, height: 16)
        slider.autoresizingMask = [.minXMargin]
        container.addSubview(slider)
        view = container
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
