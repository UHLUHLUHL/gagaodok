import Foundation
import AppKit
import WebKit

private struct VisualPlotPoint: Codable {
    let x: Double
    let y: Double
}

private struct VisualScreenPoint: Codable {
    let x: Double
    let y: Double
}

private struct VisualTriangle: Codable {
    let points: [VisualScreenPoint]
    let level: Double
}

private struct VisualRenderPayload: Codable {
    let kind: String
    let title: String
    let caption: String
    let expression: String
    let xMin: Double
    let xMax: Double
    let yMin: Double
    let yMax: Double
    let zMin: Double
    let zMax: Double
    let curves: [[VisualPlotPoint]]
    let points: [ObsidianVisualPoint]
    let segments: [ObsidianVisualSegment]
    let triangles: [VisualTriangle]
}

@MainActor
public final class ObsidianVisualRenderer: NSObject, WKNavigationDelegate {
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

    public static let shared = ObsidianVisualRenderer()
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

    public static func fileName(episodeID: String, visualID: String) -> String {
        "visual-\(ObsidianNoteWriter.sanitizedFilename(episodeID))-\(ObsidianNoteWriter.sanitizedFilename(visualID)).png"
    }

    public func render(spec: ObsidianVisualSpec) async throws -> Data {
        guard ObsidianVisualMath.validatedVisuals([spec]).first == spec else {
            throw RendererError.invalidSpec
        }
        let payload = try makePayload(for: spec)
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

    private func makePayload(for spec: ObsidianVisualSpec) throws -> VisualRenderPayload {
        switch spec.kind {
        case .function2D:
            return VisualRenderPayload(
                kind: spec.kind.rawValue, title: spec.title, caption: spec.caption, expression: spec.expression,
                xMin: spec.xMin, xMax: spec.xMax, yMin: spec.yMin, yMax: spec.yMax, zMin: spec.zMin, zMax: spec.zMax,
                curves: try sampleCurves(spec), points: spec.points, segments: spec.segments, triangles: []
            )
        case .coordinateDiagram:
            return VisualRenderPayload(
                kind: spec.kind.rawValue, title: spec.title, caption: spec.caption, expression: spec.expression,
                xMin: spec.xMin, xMax: spec.xMax, yMin: spec.yMin, yMax: spec.yMax, zMin: spec.zMin, zMax: spec.zMax,
                curves: [], points: spec.points, segments: spec.segments, triangles: []
            )
        case .surface3D:
            return VisualRenderPayload(
                kind: spec.kind.rawValue, title: spec.title, caption: spec.caption, expression: spec.expression,
                xMin: spec.xMin, xMax: spec.xMax, yMin: spec.yMin, yMax: spec.yMax, zMin: spec.zMin, zMax: spec.zMax,
                curves: [], points: [], segments: [], triangles: try sampleSurface(spec)
            )
        case .parametric2D, .implicit2D, .integral2D, .ode2D:
            throw RendererError.invalidSpec
        }
    }

    private func sampleCurves(_ spec: ObsidianVisualSpec) throws -> [[VisualPlotPoint]] {
        let sampleCount = 1_200
        let step = (spec.xMax - spec.xMin) / Double(sampleCount - 1)
        let discontinuity = max(1, abs(spec.yMax - spec.yMin) * 4)
        var paths: [[VisualPlotPoint]] = []
        var current: [VisualPlotPoint] = []
        for index in 0..<sampleCount {
            let x = spec.xMin + Double(index) * step
            let value = try ObsidianVisualMath.evaluate(spec.expression, x: x, y: 0)
            guard let y = value, y.isFinite, abs(y) <= discontinuity else {
                if current.count >= 2 { paths.append(current) }
                current = []
                continue
            }
            if let previous = current.last,
               abs(y - previous.y) > discontinuity * 1.5 {
                if current.count >= 2 { paths.append(current) }
                current = []
            }
            current.append(VisualPlotPoint(x: x, y: y))
        }
        if current.count >= 2 { paths.append(current) }
        return paths
    }

    private func sampleSurface(_ spec: ObsidianVisualSpec) throws -> [VisualTriangle] {
        let count = 48
        let xStep = (spec.xMax - spec.xMin) / Double(count - 1)
        let yStep = (spec.yMax - spec.yMin) / Double(count - 1)
        var grid = Array(repeating: Array<Double?>(repeating: nil, count: count), count: count)
        for row in 0..<count {
            for column in 0..<count {
                let x = spec.xMin + Double(column) * xStep
                let y = spec.yMin + Double(row) * yStep
                grid[row][column] = try ObsidianVisualMath.evaluate(spec.expression, x: x, y: y)
            }
        }

        func project(x: Double, y: Double, z: Double) -> (point: VisualScreenPoint, depth: Double) {
            let u = (x - spec.xMin) / (spec.xMax - spec.xMin) - 0.5
            let v = (y - spec.yMin) / (spec.yMax - spec.yMin) - 0.5
            let h = max(-0.5, min(0.5, (z - spec.zMin) / (spec.zMax - spec.zMin) - 0.5))
            let screenX = 538 + (u - v) * 720
            let screenY = 382 + (u + v) * 285 - h * 420
            return (VisualScreenPoint(x: screenX, y: screenY), u + v + h * 0.15)
        }

        var triangles: [(VisualTriangle, Double)] = []
        for row in 0..<(count - 1) {
            for column in 0..<(count - 1) {
                guard let z00 = grid[row][column], let z10 = grid[row][column + 1],
                      let z01 = grid[row + 1][column], let z11 = grid[row + 1][column + 1] else { continue }
                let x0 = spec.xMin + Double(column) * xStep, x1 = x0 + xStep
                let y0 = spec.yMin + Double(row) * yStep, y1 = y0 + yStep
                let a = project(x: x0, y: y0, z: z00), b = project(x: x1, y: y0, z: z10)
                let c = project(x: x0, y: y1, z: z01), d = project(x: x1, y: y1, z: z11)
                let levelA = max(0, min(1, (((z00 + z10 + z01) / 3) - spec.zMin) / (spec.zMax - spec.zMin)))
                let levelB = max(0, min(1, (((z10 + z01 + z11) / 3) - spec.zMin) / (spec.zMax - spec.zMin)))
                triangles.append((VisualTriangle(points: [a.point, b.point, c.point], level: levelA), a.depth + b.depth + c.depth))
                triangles.append((VisualTriangle(points: [b.point, d.point, c.point], level: levelB), b.depth + d.depth + c.depth))
            }
        }
        return triangles.sorted { $0.1 < $1.1 }.map(\.0)
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
            let created = WKWebView(frame: NSRect(x: 0, y: 0, width: Self.logicalWidth, height: 900), configuration: configuration)
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
        let waiters = readyWaiters; readyWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failReadyWaiters() }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failReadyWaiters() }

    private func failReadyWaiters() {
        let waiters = readyWaiters; readyWaiters.removeAll()
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
            bitmapDataPlanes: nil, pixelsWide: Self.pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw RendererError.pngEncodingFailed
        }
        bitmap.size = NSSize(width: Self.logicalWidth, height: logicalHeight)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: Self.logicalWidth, height: logicalHeight).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: Self.logicalWidth, height: logicalHeight))
        context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw RendererError.pngEncodingFailed }
        return data
    }

    private static var defaultShellURL: URL? {
        var bundles: [Bundle] = [.main]
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.bundleURL.deletingLastPathComponent()].compactMap { $0 }
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
