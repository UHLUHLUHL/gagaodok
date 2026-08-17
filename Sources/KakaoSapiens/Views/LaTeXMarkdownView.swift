import SwiftUI
import WebKit

public extension Notification.Name {
    /// 수식 말풍선의 실제 높이는 KaTeX가 그려진 뒤에야 정해집니다.
    /// 그 사이 채팅이 아래로 밀려나므로, 높이가 확정될 때마다 알려 다시 맨 아래로 내립니다.
    static let bubbleHeightSettled = Notification.Name("KakaoSapiens.bubbleHeightSettled")
}

/// 말풍선 웹뷰가 공유하는 자원입니다.
///
/// 예전에는 말풍선마다 CDN에서 KaTeX·markdown-it·웹폰트를 받아 문서를 통째로 새로 띄웠습니다.
/// 이제는 번들에 들어 있는 고정 셸(`bubble.html`)을 한 번만 로드하고 내용만 갈아끼웁니다.
/// 덕분에 오프라인에서도 수식이 그려지고, 스크롤로 말풍선이 재생성될 때 비용이 거의 없습니다.
enum BubbleWebAssets {
    /// 번들에서 셸과 자원이 들어 있는 디렉터리를 찾습니다.
    static let shellURL: URL? = {
        for bundle in candidateBundles {
            if let url = bundle.url(forResource: "bubble", withExtension: "html") { return url }
            if let url = bundle.url(forResource: "Resources/bubble", withExtension: "html") { return url }
        }
        return nil
    }()

    /// 웹뷰가 katex/ 와 markdown-it 을 읽을 수 있어야 하므로 셸이 있는 디렉터리 전체를 허용합니다.
    static var readAccessURL: URL? { shellURL?.deletingLastPathComponent() }

    private static var candidateBundles: [Bundle] {
        var bundles: [Bundle] = [.main]
        // SwiftPM이 만든 리소스 번들은 실행 파일 옆이나 앱의 Resources 안에 놓입니다.
        let names = ["KakaoSapiens_KakaoSapiens", "KakaoSapiens_KakaoSapiens.bundle"]
        let searchRoots = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent()
        ].compactMap { $0 }
        for root in searchRoots {
            for name in names {
                let candidate = root.appendingPathComponent(name.hasSuffix(".bundle") ? name : name + ".bundle")
                if let bundle = Bundle(url: candidate) { bundles.append(bundle) }
            }
        }
        return bundles
    }
}

public struct LaTeXMarkdownView: NSViewRepresentable {
    let content: String
    let isUser: Bool
    @Binding var dynamicHeight: CGFloat
    /// 검색 중일 때만 채워집니다. 웹뷰 안에서 이 글자를 칠합니다.
    var searchQuery: String = ""
    var isCurrentSearchHit: Bool = false

    public init(
        content: String,
        isUser: Bool,
        dynamicHeight: Binding<CGFloat>,
        searchQuery: String = "",
        isCurrentSearchHit: Bool = false
    ) {
        self.content = content
        self.isUser = isUser
        self._dynamicHeight = dynamicHeight
        self.searchQuery = searchQuery
        self.isCurrentSearchHit = isCurrentSearchHit
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "heightHandler")
        controller.add(context.coordinator, name: "readyHandler")

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.suppressesIncrementalRendering = true

        let webView = PassthroughWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.enclosingScrollView?.hasVerticalScroller = false
        webView.enclosingScrollView?.hasHorizontalScroller = false

        context.coordinator.pendingContent = content
        if let shell = BubbleWebAssets.shellURL, let readAccess = BubbleWebAssets.readAccessURL {
            webView.loadFileURL(shell, allowingReadAccessTo: readAccess)
        } else {
            // 번들에서 셸을 못 찾은 경우에도 글자는 읽을 수 있게 최소한으로 표시합니다.
            webView.loadHTMLString(Self.fallbackHTML(for: content), baseURL: nil)
        }
        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastContent != content {
            context.coordinator.lastContent = content
            context.coordinator.render(content, in: nsView)
        }
        // 수식은 KaTeX가 그린 노드라 SwiftUI 쪽에서 칠할 수 없습니다.
        // 웹뷰 안에서 직접 칠하되 수식 노드는 건드리지 않습니다.
        context.coordinator.applyHighlight(query: searchQuery, isCurrent: isCurrentSearchHit, in: nsView)
    }

    private static func fallbackHTML(for content: String) -> String {
        let escaped = content
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return "<meta charset=\"utf-8\"><div style=\"font:13.5px -apple-system;white-space:pre-wrap\">\(escaped)</div>"
    }

    public class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: LaTeXMarkdownView
        var lastContent: String
        /// 셸이 준비되기 전에 들어온 내용을 담아뒀다가 준비 직후에 그립니다.
        var pendingContent: String?
        private var isReady = false

        init(_ parent: LaTeXMarkdownView) {
            self.parent = parent
            self.lastContent = parent.content
        }

        /// 마지막으로 칠한 상태입니다. 같은 값이면 다시 칠하지 않습니다.
        private var lastHighlight: String = ""

        func applyHighlight(query: String, isCurrent: Bool, in webView: WKWebView) {
            let key = "\(query)|\(isCurrent)"
            guard isReady, lastHighlight != key else { return }
            lastHighlight = key
            guard let data = try? JSONEncoder().encode([query]),
                  let literal = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("highlightSearch(\(literal)[0], \(isCurrent))", completionHandler: nil)
        }

        func render(_ content: String, in webView: WKWebView) {
            guard isReady else {
                pendingContent = content
                return
            }
            // 문자열을 JSON으로 감싸 따옴표·역슬래시·개행을 안전하게 전달합니다.
            guard let data = try? JSONEncoder().encode([content]),
                  let literal = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("renderContent(\(literal)[0])") { result, _ in
                guard let height = result as? CGFloat else { return }
                DispatchQueue.main.async { self.apply(height: height) }
            }
        }

        private func apply(height: CGFloat) {
            guard abs(parent.dynamicHeight - height) > 0.5 else { return }
            parent.dynamicHeight = max(height, 18)
            NotificationCenter.default.post(name: .bubbleHeightSettled, object: nil)
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "readyHandler":
                isReady = true
                if let webView = message.webView, let pending = pendingContent {
                    pendingContent = nil
                    render(pending, in: webView)
                }
            case "heightHandler":
                if let height = message.body as? CGFloat {
                    DispatchQueue.main.async { self.apply(height: height) }
                }
            default:
                break
            }
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // readyHandler가 먼저 오는 게 보통이지만, 순서가 뒤바뀌어도 내용이 비지 않도록 합니다.
            if isReady, let pending = pendingContent {
                pendingContent = nil
                render(pending, in: webView)
            }
        }
    }
}

/// 수식 웹뷰가 마우스 휠을 내부 스크롤로 소비하지 않고 채팅 ScrollView로 전달합니다.
final class PassthroughWKWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
