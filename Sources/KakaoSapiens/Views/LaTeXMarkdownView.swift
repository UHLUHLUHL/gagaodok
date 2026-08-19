import SwiftUI
import WebKit

public extension Notification.Name {
    static let bubbleHeightSettled = Notification.Name("KakaoSapiens.bubbleHeightSettled")
}

enum BubbleWebAssets {
    static let shellURL: URL? = {
        for bundle in candidateBundles {
            if let url = bundle.url(forResource: "bubble", withExtension: "html") { return url }
            if let url = bundle.url(forResource: "Resources/bubble", withExtension: "html") { return url }
        }
        return nil
    }()

    static var readAccessURL: URL? { shellURL?.deletingLastPathComponent() }

    private static var candidateBundles: [Bundle] {
        var bundles: [Bundle] = [.main]
        let names = ["KakaoSapiens_KakaoSapiens", "KakaoSapiens_KakaoSapiens.bundle"]
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                     Bundle.main.bundleURL.deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            for name in names {
                let candidate = root.appendingPathComponent(name.hasSuffix(".bundle") ? name : name + ".bundle")
                if let bundle = Bundle(url: candidate) { bundles.append(bundle) }
            }
        }
        return bundles
    }
}

struct BubbleSnapshotKey: Hashable {
    let content: String
    let width: Int
    let query: String
    let isCurrentHit: Bool
    let isDark: Bool

    init(content: String, width: CGFloat, query: String, isCurrentHit: Bool, isDark: Bool) {
        self.content = content
        self.width = max(36, Int(width.rounded()))
        self.query = query
        self.isCurrentHit = isCurrentHit
        self.isDark = isDark
    }
}

/// 이미지 캐시에서 스냅샷이 밀려나도 이미 확정한 레이아웃 높이는 보존합니다.
/// 높이 값은 이미지에 비해 매우 작고, 제한을 둬 오래된 대화가 무한히 쌓이지 않게 합니다.
final class BubbleLayoutHeightCache {
    private let capacity: Int
    private var values: [BubbleSnapshotKey: CGFloat] = [:]
    private var order: [BubbleSnapshotKey] = []

    init(capacity: Int = 5_000) {
        self.capacity = max(1, capacity)
    }

    func height(for key: BubbleSnapshotKey) -> CGFloat? { values[key] }

    func insert(_ height: CGFloat, for key: BubbleSnapshotKey) {
        if values[key] != nil { order.removeAll { $0 == key } }
        values[key] = height
        order.append(key)
        while values.count > capacity, let oldest = order.first {
            order.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }
}

/// LazyVStack가 행 자체를 재생성해도 30pt 기본 높이로 돌아가지 않게 하는 작은 캐시입니다.
final class BubbleMessageHeightCache: @unchecked Sendable {
    static let shared = BubbleMessageHeightCache()

    private struct Entry { let content: String; let height: CGFloat }
    private let capacity: Int
    private let lock = NSLock()
    private var values: [UUID: Entry] = [:]
    private var order: [UUID] = []

    init(capacity: Int = 5_000) {
        self.capacity = max(1, capacity)
    }

    func height(for id: UUID, content: String) -> CGFloat? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = values[id], entry.content == content else { return nil }
        return entry.height
    }

    func insert(_ height: CGFloat, for id: UUID, content: String) {
        lock.lock(); defer { lock.unlock() }
        if values[id] != nil { order.removeAll { $0 == id } }
        values[id] = Entry(content: content, height: height)
        order.append(id)
        while values.count > capacity, let oldest = order.first {
            order.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }
}

enum BubbleRenderRequestDelay {
    static func nanoseconds(hasRenderedKey: Bool, widthChanged: Bool) -> UInt64 {
        hasRenderedKey && widthChanged ? 300_000_000 : 0
    }
}

enum BubbleSnapshotReusePolicy {
    static func shouldApply(key: BubbleSnapshotKey, lastAppliedKey: BubbleSnapshotKey?) -> Bool {
        key != lastAppliedKey
    }
}

struct BubbleHeightStabilityTracker {
    private var lastHeight: CGFloat?

    mutating func observe(_ height: CGFloat) -> Bool {
        defer { lastHeight = height }
        guard let lastHeight else { return false }
        return abs(lastHeight - height) <= 0.5
    }
}

private struct BubbleSnapshot {
    let image: NSImage
    let height: CGFloat
    let cost: Int
}

/// KaTeX/Markdown은 앱 전체의 WKWebView 하나에서 순차 렌더링합니다.
@MainActor
private final class BubbleSnapshotRenderer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = BubbleSnapshotRenderer()

    private struct Job { let key: BubbleSnapshotKey; let content: String }
    typealias Completion = (NSImage, CGFloat) -> Void

    private let webView: WKWebView
    private var isReady = false
    private var isRendering = false
    private var queue: [Job] = []
    private var callbacks: [BubbleSnapshotKey: [Completion]] = [:]
    private var cache: [BubbleSnapshotKey: BubbleSnapshot] = [:]
    private var cacheOrder: [BubbleSnapshotKey] = []
    private var cacheCost = 0
    private let cacheCostLimit = 64 * 1024 * 1024
    private let heightCache = BubbleLayoutHeightCache()

    override init() {
        let controller = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.suppressesIncrementalRendering = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 2000), configuration: configuration)
        super.init()
        controller.add(self, name: "readyHandler")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        if let shell = BubbleWebAssets.shellURL, let access = BubbleWebAssets.readAccessURL {
            webView.loadFileURL(shell, allowingReadAccessTo: access)
        }
    }

    func render(key: BubbleSnapshotKey, content: String, completion: @escaping Completion) {
        if let cached = cache[key] { completion(cached.image, cached.height); return }
        if callbacks[key] != nil { callbacks[key]?.append(completion); return }
        callbacks[key] = [completion]
        // 빠르게 스크롤했을 때 이미 지나간 요청보다 현재 화면 요청을 먼저 그립니다.
        queue.insert(Job(key: key, content: content), at: 0)
        pump()
    }

    func cachedSnapshot(for key: BubbleSnapshotKey) -> (NSImage, CGFloat)? {
        guard let snapshot = cache[key] else { return nil }
        return (snapshot.image, snapshot.height)
    }

    func cachedHeight(for key: BubbleSnapshotKey) -> CGFloat? {
        heightCache.height(for: key)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "readyHandler" else { return }
        isReady = true
        pump()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("typeof renderContent === 'function'") { [weak self] result, _ in
            Task { @MainActor in
                guard result as? Bool == true else { return }
                self?.isReady = true
                self?.pump()
            }
        }
    }

    private func pump() {
        guard isReady, !isRendering, !queue.isEmpty else { return }
        isRendering = true
        let job = queue.removeFirst()
        webView.frame = NSRect(x: 0, y: 0, width: job.key.width, height: 2000)
        guard let data = try? JSONEncoder().encode([job.content]),
              let literal = String(data: data, encoding: .utf8) else {
            finish(job: job, image: fallbackImage(for: job), height: 30); return
        }
        webView.evaluateJavaScript("renderContent(\(literal)[0])") { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }
                let initialHeight = max(18, CGFloat((result as? NSNumber)?.doubleValue ?? 30))
                var tracker = BubbleHeightStabilityTracker()
                _ = tracker.observe(initialHeight)
                self.settleHeight(job: job, tracker: tracker, attemptsRemaining: 6)
            }
        }
    }

    private func settleHeight(job: Job, tracker: BubbleHeightStabilityTracker, attemptsRemaining: Int) {
        webView.evaluateJavaScript("fitDisplayMath(); Math.ceil(container.scrollHeight)") { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }
                let height = max(18, CGFloat((result as? NSNumber)?.doubleValue ?? 30))
                var nextTracker = tracker
                let isStable = nextTracker.observe(height)
                if isStable || attemptsRemaining <= 1 {
                    self.webView.frame.size.height = height
                    self.applyHighlight(for: job) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                            self.capture(job: job, height: height)
                        }
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                        self.settleHeight(job: job, tracker: nextTracker, attemptsRemaining: attemptsRemaining - 1)
                    }
                }
            }
        }
    }

    private func applyHighlight(for job: Job, completion: @escaping () -> Void) {
        guard let data = try? JSONEncoder().encode([job.key.query]),
              let literal = String(data: data, encoding: .utf8) else { completion(); return }
        webView.evaluateJavaScript("highlightSearch(\(literal)[0], \(job.key.isCurrentHit))") { _, _ in completion() }
    }

    private func capture(job: Job, height: CGFloat) {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: CGFloat(job.key.width), height: height)
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            Task { @MainActor in
                guard let self else { return }
                let result = image ?? self.fallbackImage(for: job)
                result.size = NSSize(width: CGFloat(job.key.width), height: height)
                self.finish(job: job, image: result, height: height)
            }
        }
    }

    private func finish(job: Job, image: NSImage, height: CGFloat) {
        let cost = max(1, job.key.width * Int(height.rounded()) * 8)
        heightCache.insert(height, for: job.key)
        cache[job.key] = BubbleSnapshot(image: image, height: height, cost: cost)
        cacheOrder.append(job.key)
        cacheCost += cost
        while cacheCost > cacheCostLimit, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) { cacheCost -= removed.cost }
        }
        let waiting = callbacks.removeValue(forKey: job.key) ?? []
        waiting.forEach { $0(image, height) }
        isRendering = false
        pump()
    }

    private func fallbackImage(for job: Job) -> NSImage {
        let image = NSImage(size: NSSize(width: job.key.width, height: 30))
        image.lockFocus()
        NSAttributedString(string: job.content, attributes: [
            .font: NSFont.systemFont(ofSize: 13.5),
            .foregroundColor: job.key.isDark ? NSColor.white : NSColor.labelColor
        ]).draw(in: NSRect(x: 0, y: 0, width: job.key.width, height: 30))
        image.unlockFocus()
        return image
    }
}

public final class BubbleSnapshotView: NSView {
    let imageView = NSImageView()
    let fallbackLabel = NSTextField(wrappingLabelWithString: "")
    var widthChanged: ((CGFloat) -> Void)?
    private var lastWidth: CGFloat = 0
    private var displayedContent: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleAxesIndependently
        fallbackLabel.font = .systemFont(ofSize: 13.5)
        fallbackLabel.maximumNumberOfLines = 3
        addSubview(fallbackLabel)
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { nil }

    public override func layout() {
        super.layout()
        imageView.frame = bounds
        fallbackLabel.frame = bounds
        if bounds.width > 35, abs(bounds.width - lastWidth) > 0.75 {
            lastWidth = bounds.width
            widthChanged?(bounds.width)
        }
    }

    func showFallback(_ content: String) {
        guard displayedContent != content else { return }
        displayedContent = content
        fallbackLabel.stringValue = content
        fallbackLabel.isHidden = false
        imageView.image = nil
        setAccessibilityLabel(content)
    }

    func show(image: NSImage) {
        imageView.image = image
        fallbackLabel.isHidden = true
    }
}

public struct LaTeXMarkdownView: NSViewRepresentable {
    let messageID: UUID
    let content: String
    let isUser: Bool
    @Binding var dynamicHeight: CGFloat
    var isRenderingEnabled: Bool = true
    var searchQuery: String = ""
    var isCurrentSearchHit: Bool = false

    public init(messageID: UUID, content: String, isUser: Bool, dynamicHeight: Binding<CGFloat>,
                isRenderingEnabled: Bool = true, searchQuery: String = "", isCurrentSearchHit: Bool = false) {
        self.messageID = messageID; self.content = content; self.isUser = isUser; self._dynamicHeight = dynamicHeight
        self.isRenderingEnabled = isRenderingEnabled
        self.searchQuery = searchQuery; self.isCurrentSearchHit = isCurrentSearchHit
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> BubbleSnapshotView {
        let view = BubbleSnapshotView()
        view.showFallback(content)
        view.widthChanged = { [weak coordinator = context.coordinator, weak view] width in
            guard let coordinator, let view else { return }
            coordinator.request(width: width, in: view)
        }
        return view
    }

    public func updateNSView(_ nsView: BubbleSnapshotView, context: Context) {
        context.coordinator.parent = self
        nsView.showFallback(content)
        if nsView.bounds.width > 35 {
            context.coordinator.request(width: nsView.bounds.width, in: nsView)
        }
    }

    public final class Coordinator {
        var parent: LaTeXMarkdownView
        private var lastKey: BubbleSnapshotKey?
        private var pendingKey: BubbleSnapshotKey?
        private var pendingTask: Task<Void, Never>?
        init(_ parent: LaTeXMarkdownView) { self.parent = parent }

        @MainActor
        func request(width: CGFloat, in view: BubbleSnapshotView) {
            guard parent.isRenderingEnabled else { return }
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let key = BubbleSnapshotKey(content: parent.content, width: width, query: parent.searchQuery,
                                        isCurrentHit: parent.isCurrentSearchHit, isDark: dark)

            guard BubbleSnapshotReusePolicy.shouldApply(key: key, lastAppliedKey: lastKey),
                  key != pendingKey else { return }

            if let (image, height) = BubbleSnapshotRenderer.shared.cachedSnapshot(for: key) {
                pendingTask?.cancel()
                pendingKey = nil
                lastKey = key
                apply(image: image, height: height, key: key, in: view)
                return
            }

            if let height = BubbleSnapshotRenderer.shared.cachedHeight(for: key) {
                applyHeight(height)
            }

            let previousKey = lastKey
            let delay = BubbleRenderRequestDelay.nanoseconds(
                hasRenderedKey: previousKey != nil,
                widthChanged: previousKey?.width != key.width
            )
            pendingKey = key
            pendingTask?.cancel()
            pendingTask = Task { @MainActor [weak self, weak view] in
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard !Task.isCancelled, let self, let view, self.pendingKey == key else { return }
                self.pendingKey = nil
                self.lastKey = key
                BubbleSnapshotRenderer.shared.render(key: key, content: self.parent.content) { [weak self, weak view] image, height in
                    guard let self, let view, self.lastKey == key else { return }
                    self.apply(image: image, height: height, key: key, in: view)
                }
            }
        }


        @MainActor
        private func apply(image: NSImage, height: CGFloat, key: BubbleSnapshotKey, in view: BubbleSnapshotView) {
            guard lastKey == key else { return }
            view.show(image: image)
            applyHeight(height)
        }

        @MainActor
        private func applyHeight(_ height: CGFloat) {
            BubbleMessageHeightCache.shared.insert(height, for: parent.messageID, content: parent.content)
            if abs(parent.dynamicHeight - height) > 0.5 {
                parent.dynamicHeight = height
                NotificationCenter.default.post(name: .bubbleHeightSettled, object: nil)
            }
        }
    }
}
