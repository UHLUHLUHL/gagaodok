import Foundation
import AppKit
import WebKit

@MainActor
public final class ObsidianProblemCardRenderer: NSObject, WKNavigationDelegate {
    public enum RendererError: LocalizedError {
        case resourceMissing
        case pageLoadFailed
        case renderFailed
        case pngEncodingFailed

        public var errorDescription: String? {
            switch self {
            case .resourceMissing: return "문제 카드 렌더링 파일을 찾을 수 없습니다."
            case .pageLoadFailed: return "문제 카드 렌더러를 준비하지 못했습니다."
            case .renderFailed: return "문제 카드를 이미지로 그리지 못했습니다."
            case .pngEncodingFailed: return "문제 카드를 PNG로 변환하지 못했습니다."
            }
        }
    }

    public static let shared = ObsidianProblemCardRenderer()
    public static let logicalWidth: CGFloat = 900
    public static let pixelWidth = 1_800

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

    public static func fileName(episodeID: String) -> String {
        "problem-\(ObsidianNoteWriter.sanitizedFilename(episodeID)).png"
    }

    public func render(title: String, problem: String) async throws -> Data {
        let webView = try await preparedWebView()
        webView.frame = NSRect(x: 0, y: 0, width: Self.logicalWidth, height: 1_200)

        guard let encoded = try? JSONSerialization.data(withJSONObject: [title, problem]),
              let arguments = String(data: encoded, encoding: .utf8) else {
            throw RendererError.renderFailed
        }
        let result = try await evaluate("renderProblem(\(arguments)[0], \(arguments)[1])", in: webView)
        let firstHeight = max(220, CGFloat((result as? NSNumber)?.doubleValue ?? 0))
        webView.frame.size.height = firstHeight
        try await Task.sleep(nanoseconds: 80_000_000)
        let settled = try await evaluate("fitDisplayMath(); Math.ceil(document.documentElement.scrollHeight)", in: webView)
        let height = max(firstHeight, CGFloat((settled as? NSNumber)?.doubleValue ?? 0))
        webView.frame.size.height = height
        try await Task.sleep(nanoseconds: 40_000_000)

        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: Self.logicalWidth, height: height)
        let snapshot = try await takeSnapshot(webView, configuration: configuration)
        return try retinaPNG(from: snapshot, logicalHeight: height)
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
                frame: NSRect(x: 0, y: 0, width: Self.logicalWidth, height: 1_200),
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

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        failReadyWaiters()
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
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

    private func takeSnapshot(
        _ webView: WKWebView,
        configuration: WKSnapshotConfiguration
    ) async throws -> NSImage {
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
            bitsPerPixel: 0
        ) else { throw RendererError.pngEncodingFailed }
        bitmap.size = NSSize(width: Self.logicalWidth, height: logicalHeight)
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw RendererError.pngEncodingFailed
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
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
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                     Bundle.main.bundleURL.deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            for name in ["KakaoSapiens_KakaoSapiens.bundle", "KakaoSapiens_KakaoSapiens"] {
                let url = root.appendingPathComponent(name.hasSuffix(".bundle") ? name : name + ".bundle")
                if let bundle = Bundle(url: url) { bundles.append(bundle) }
            }
        }
        for bundle in bundles {
            if let url = bundle.url(forResource: "problem-sheet", withExtension: "html") { return url }
            if let url = bundle.url(forResource: "Resources/problem-sheet", withExtension: "html") { return url }
        }
        return nil
    }
}
