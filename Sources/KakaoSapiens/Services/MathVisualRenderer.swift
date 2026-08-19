import Foundation
import AppKit
import WebKit

private struct MathVisualScreenPoint: Codable {
    let x: Double
    let y: Double
}

private struct MathVisualRenderTriangle: Codable {
    let points: [MathVisualScreenPoint]
    let level: Double
}

private struct MathVisualRenderPayload: Codable {
    let kind: String
    let title: String
    let caption: String
    let expression: String
    let legend: String
    let xLabel: String
    let yLabel: String
    let zLabel: String
    let equalAspect: Bool
    let xMin: Double
    let xMax: Double
    let yMin: Double
    let yMax: Double
    let zMin: Double
    let zMax: Double
    let curves: [[MathVisualPoint]]
    let points: [MathVisualPoint]
    let segments: [MathVisualSegment]
    let triangles: [MathVisualRenderTriangle]
}

@MainActor
public final class MathVisualRenderer: NSObject, WKNavigationDelegate {
    public enum RendererError: LocalizedError {
        case invalidSpec
        case resourceMissing
        case pageLoadFailed
        case renderFailed
        case pngEncodingFailed

        public var errorDescription: String? {
            switch self {
            case .invalidSpec: return "시각자료 명세를 안전하게 렌더링할 수 없습니다."
            case .resourceMissing: return "시각자료 렌더링 파일을 찾을 수 없습니다."
            case .pageLoadFailed: return "시각자료 렌더러를 준비하지 못했습니다."
            case .renderFailed: return "시각자료를 이미지로 그리지 못했습니다."
            case .pngEncodingFailed: return "시각자료를 PNG로 변환하지 못했습니다."
            }
        }
    }

    public static let shared = MathVisualRenderer()
    public static let logicalWidth: CGFloat = 1_200
    public static let pixelWidth = 2_400

    private let shellURL: URL?
    private var webView: WKWebView?
    private var isReady = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    public override convenience init() {
        self.init(shellURL: Self.defaultShellURL)
    }

    public init(shellURL: URL?) {
        self.shellURL = shellURL
        super.init()
    }

    public func render(spec: MathVisualSpec) async throws -> Data {
        let sample: MathVisualSample
        do {
            sample = try MathVisualSampler.sample(spec)
        } catch {
            throw RendererError.invalidSpec
        }
        let payload = makePayload(for: spec, sample: sample)
        let webView = try await preparedWebView()
        webView.frame = NSRect(x: 0, y: 0, width: Self.logicalWidth, height: 900)
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else { throw RendererError.renderFailed }
        let result = try await evaluate("renderVisual(\(json))", in: webView)
        let firstHeight = max(820, CGFloat((result as? NSNumber)?.doubleValue ?? 0))
        webView.frame.size.height = firstHeight
        try await Task.sleep(nanoseconds: 80_000_000)
        let settled = try await evaluate("Math.ceil(document.documentElement.scrollHeight)", in: webView)
        let height = max(firstHeight, CGFloat((settled as? NSNumber)?.doubleValue ?? 0))
        webView.frame.size.height = height
        try await Task.sleep(nanoseconds: 40_000_000)

        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: Self.logicalWidth, height: height)
        let snapshot = try await takeSnapshot(webView, configuration: configuration)
        return try retinaPNG(from: snapshot, logicalHeight: height)
    }

    private func makePayload(for spec: MathVisualSpec, sample: MathVisualSample) -> MathVisualRenderPayload {
        let triangles = sample.triangles.map { triangle in
            MathVisualRenderTriangle(
                points: triangle.points.map { project($0, in: spec) },
                level: triangle.level
            )
        }
        return MathVisualRenderPayload(
            kind: spec.kind.rawValue,
            title: spec.title,
            caption: spec.caption,
            expression: displayedExpression(for: spec),
            legend: spec.legend,
            xLabel: spec.xLabel,
            yLabel: spec.yLabel,
            zLabel: spec.zLabel,
            equalAspect: [.parametric2D, .implicit2D, .coordinateDiagram].contains(spec.kind),
            xMin: spec.xMin,
            xMax: spec.xMax,
            yMin: spec.yMin,
            yMax: spec.yMax,
            zMin: spec.zMin,
            zMax: spec.zMax,
            curves: sample.curves,
            points: spec.points,
            segments: spec.segments,
            triangles: triangles
        )
    }

    private func displayedExpression(for spec: MathVisualSpec) -> String {
        switch spec.kind {
        case .parametric2D:
            return "x(t) = \(spec.xExpression),  y(t) = \(spec.yExpression)"
        case .implicit2D:
            return "\(spec.expression) = \(spec.contourValue)"
        case .integral2D:
            return "y(x) = ∫[\(spec.parameterMin), \(spec.parameterMax)] \(spec.expression) dt"
        case .ode2D:
            return "y′ = \(spec.expression),  y(\(spec.initialX)) = \(spec.initialY)"
        case .function2D, .surface3D:
            return spec.expression
        case .coordinateDiagram:
            return ""
        }
    }

    private func project(_ point: MathVisualPoint, in spec: MathVisualSpec) -> MathVisualScreenPoint {
        let u = (point.x - spec.xMin) / (spec.xMax - spec.xMin) - 0.5
        let v = (point.y - spec.yMin) / (spec.yMax - spec.yMin) - 0.5
        let h = max(-0.5, min(0.5, (point.z - spec.zMin) / (spec.zMax - spec.zMin) - 0.5))
        return MathVisualScreenPoint(
            x: 538 + (u - v) * 720,
            y: 382 + (u + v) * 285 - h * 420
        )
    }

    private func preparedWebView() async throws -> WKWebView {
        guard let shellURL else { throw RendererError.resourceMissing }
        if let webView, isReady { return webView }
        let webView: WKWebView
        if let existing = self.webView {
            webView = existing
        } else {
            let configuration = WKWebViewConfiguration()
            configuration.suppressesIncrementalRendering = true
            let created = WKWebView(
                frame: NSRect(x: 0, y: 0, width: Self.logicalWidth, height: 900),
                configuration: configuration
            )
            created.navigationDelegate = self
            created.setValue(false, forKey: "drawsBackground")
            self.webView = created
            webView = created
            created.loadFileURL(shellURL, allowingReadAccessTo: shellURL.deletingLastPathComponent())
        }
        try await withCheckedThrowingContinuation { continuation in
            readyWaiters.append(continuation)
        }
        return webView
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failReadyWaiters()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failReadyWaiters()
    }

    private func failReadyWaiters() {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: RendererError.pageLoadFailed) }
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    private func takeSnapshot(_ webView: WKWebView, configuration: WKSnapshotConfiguration) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? RendererError.renderFailed) }
            }
        }
    }

    private func retinaPNG(from image: NSImage, logicalHeight: CGFloat) throws -> Data {
        let pixelHeight = max(1, Int(ceil(logicalHeight * 2)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Self.pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw RendererError.pngEncodingFailed
        }
        bitmap.size = NSSize(width: Self.logicalWidth, height: logicalHeight)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: Self.logicalWidth, height: logicalHeight).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: Self.logicalWidth, height: logicalHeight))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RendererError.pngEncodingFailed
        }
        return data
    }

    private static var defaultShellURL: URL? {
        var bundles: [Bundle] = [.main]
        let roots = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent()
        ].compactMap { $0 }
        for root in roots {
            for name in ["KakaoSapiens_KakaoSapiens.bundle", "KakaoSapiens_KakaoSapiens"] {
                let url = root.appendingPathComponent(name.hasSuffix(".bundle") ? name : name + ".bundle")
                if let bundle = Bundle(url: url) { bundles.append(bundle) }
            }
        }
        for bundle in bundles {
            if let url = bundle.url(forResource: "visual-sheet", withExtension: "html") { return url }
            if let url = bundle.url(forResource: "Resources/visual-sheet", withExtension: "html") { return url }
        }
        return nil
    }
}
