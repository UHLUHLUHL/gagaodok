import SwiftUI
import WebKit

public struct KaTeXHTMLGenerator {
    public static func generateHTML(content: String, isUser: Bool) -> String {
        let textColor = "#000000"
        
        // Escape special chars for JS safe template string
        let escapedContent = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <!-- Pretendard Webfont -->
            <link rel="stylesheet" as="style" crossorigin href="https://cdn.jsdelivr.net/gh/orioncactus/pretendard@v1.3.9/dist/web/static/pretendard.min.css" />
            <!-- KaTeX CSS & JS -->
            <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"></script>
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js"></script>
            <!-- Markdown-it for rich markdown -->
            <script src="https://cdn.jsdelivr.net/npm/markdown-it@14.1.0/dist/markdown-it.min.js"></script>
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                }
                body {
                    font-family: "Pretendard Variable", Pretendard, -apple-system, BlinkMacSystemFont, system-ui, Roboto, sans-serif;
                    font-size: 13.5px;
                    line-height: 1.50;
                    color: \(textColor);
                    background-color: transparent;
                    word-break: break-word;
                    overflow: hidden;
                    user-select: text !important;
                    -webkit-user-select: text !important;
                    letter-spacing: -0.2px;
                }
                #content {
                    display: inline-block;
                    width: 100%;
                    user-select: text !important;
                    -webkit-user-select: text !important;
                }
                p {
                    margin-bottom: 5px;
                }
                p:last-child {
                    margin-bottom: 0;
                }
                
                /* [아이디어 1 & 4] KaTeX 수식 폰트 크기 120% 스케일업 & 두께(웨이트) 보정 */
                .katex {
                    font-size: 1.18em !important; /* 본문 13.5px 대비 약 16px로 시원하게 확대 */
                    line-height: 1.25 !important;
                    text-rendering: optimizeLegibility !important;
                    -webkit-text-stroke: 0.18px currentColor !important; /* Pretendard 대비 가늘던 획 보정 */
                    letter-spacing: 0.2px;
                }
                
                .katex-display {
                    margin: 7px 0 !important;
                    overflow-x: auto;
                    overflow-y: hidden;
                    padding: 4px 2px !important;
                }
                
                .katex-display > .katex {
                    font-size: 1.22em !important; /* 블록 독립 수식은 16.5px로 더욱 뚜렷하게 */
                }
                
                /* 분수선(Fraction line) 및 루트선 두께 보강으로 레티나 화면 뭉개짐 방지 */
                .katex .frac-line {
                    border-bottom-width: 1.5px !important;
                }
                .katex .sqrt-line {
                    border-top-width: 1.5px !important;
                }
                
                /* 분수 내부 분자/분모 요소들 가시성 확보 */
                .katex .mord, .katex .mbin, .katex .mrel, .katex .mop {
                    -webkit-text-stroke: 0.18px currentColor !important;
                }
                
                pre {
                    background-color: rgba(0, 0, 0, 0.06);
                    border-radius: 6px;
                    padding: 6px 8px;
                    font-family: "Pretendard Variable", Menlo, Monaco, monospace;
                    font-size: 12px;
                    overflow-x: auto;
                    margin: 4px 0;
                }
                code {
                    font-family: Menlo, Monaco, "Courier New", monospace;
                    font-size: 12px;
                    background-color: rgba(0, 0, 0, 0.05);
                    padding: 1px 3px;
                    border-radius: 3px;
                }
                pre code {
                    background-color: transparent;
                    padding: 0;
                }
                ul, ol {
                    margin-left: 16px;
                    margin-bottom: 4px;
                }
                li {
                    margin-bottom: 2px;
                }
                blockquote {
                    border-left: 3px solid rgba(0, 0, 0, 0.2);
                    padding-left: 6px;
                    margin: 4px 0;
                    color: rgba(0, 0, 0, 0.75);
                }
                table {
                    border-collapse: collapse;
                    width: 100%;
                    margin: 5px 0;
                    font-size: 12.5px;
                }
                th, td {
                    border: 1px solid rgba(0, 0, 0, 0.15);
                    padding: 3px 6px;
                    text-align: left;
                }
                th {
                    background-color: rgba(0, 0, 0, 0.04);
                    font-weight: 600;
                }
            </style>
        </head>
        <body>
            <div id="content"></div>
            <script>
                // 수식 내 분수/적분식을 displaystyle로 자동 변환하여 축소 방지
                let rawMarkdown = `\(escapedContent)`;
                
                const md = window.markdownit({
                    html: false,
                    breaks: true,
                    linkify: true
                });
                
                // markdown-it의 줄바꿈 처리가 $$ ... $$ 내부에 <br>를 넣으면
                // KaTeX가 시작/끝 구분자를 한 블록으로 찾지 못합니다. 먼저 블록 수식을
                // 안전한 토큰으로 치환하고 Markdown 렌더링 뒤 KaTeX HTML로 복원합니다.
                const displayMathBlocks = [];
                function protectDisplayMath(source, left, right) {
                    let output = '';
                    let cursor = 0;
                    while (cursor < source.length) {
                        const start = source.indexOf(left, cursor);
                        if (start < 0) {
                            output += source.slice(cursor);
                            break;
                        }
                        const end = source.indexOf(right, start + left.length);
                        if (end < 0) {
                            output += source.slice(cursor);
                            break;
                        }
                        const token = `KATEXDISPLAYBLOCKTOKEN${displayMathBlocks.length}END`;
                        displayMathBlocks.push(source.slice(start + left.length, end));
                        output += source.slice(cursor, start) + String.fromCharCode(10, 10) + token + String.fromCharCode(10, 10);
                        cursor = end + right.length;
                    }
                    return output;
                }

                let protectedMarkdown = protectDisplayMath(rawMarkdown, '$$', '$$');
                protectedMarkdown = protectDisplayMath(protectedMarkdown, '\\\\[', '\\\\]');
                let renderedHtml = md.render(protectedMarkdown);
                displayMathBlocks.forEach((formula, index) => {
                    const token = `KATEXDISPLAYBLOCKTOKEN${index}END`;
                    const mathHtml = katex.renderToString(formula.trim(), {
                        displayMode: true,
                        throwOnError: false,
                        strict: false
                    });
                    renderedHtml = renderedHtml.split(token).join(mathHtml);
                });
                const container = document.getElementById('content');
                container.innerHTML = renderedHtml;
                
                // KaTeX Auto-render with displaystyle & thick fonts
                renderMathInElement(container, {
                    delimiters: [
                        {left: '$$', right: '$$', display: true},
                        {left: '$', right: '$', display: false},
                        {left: '\\\\(', right: '\\\\)', display: false},
                        {left: '\\\\[', right: '\\\\]', display: true}
                    ],
                    throwOnError: false,
                    strict: false
                });
                
                function sendHeight() {
                    const height = Math.ceil(document.getElementById('content').scrollHeight);
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.heightHandler) {
                        window.webkit.messageHandlers.heightHandler.postMessage(height);
                    }
                }
                
                window.addEventListener('load', () => {
                    sendHeight();
                    setTimeout(sendHeight, 60);
                    setTimeout(sendHeight, 200);
                });
                
                const resizeObserver = new ResizeObserver(() => {
                    sendHeight();
                });
                resizeObserver.observe(container);
            </script>
        </body>
        </html>
        """
    }
}

public struct LaTeXMarkdownView: NSViewRepresentable {
    let content: String
    let isUser: Bool
    @Binding var dynamicHeight: CGFloat
    
    public init(content: String, isUser: Bool, dynamicHeight: Binding<CGFloat>) {
        self.content = content
        self.isUser = isUser
        self._dynamicHeight = dynamicHeight
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "heightHandler")
        
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        
        let webView = PassthroughWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        
        webView.enclosingScrollView?.hasVerticalScroller = false
        webView.enclosingScrollView?.hasHorizontalScroller = false
        
        let html = KaTeXHTMLGenerator.generateHTML(content: content, isUser: isUser)
        webView.loadHTMLString(html, baseURL: nil)
        
        return webView
    }
    
    public func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.lastContent != content {
            context.coordinator.lastContent = content
            let html = KaTeXHTMLGenerator.generateHTML(content: content, isUser: isUser)
            nsView.loadHTMLString(html, baseURL: nil)
        }
    }
    
    public class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: LaTeXMarkdownView
        var lastContent: String = ""
        
        init(_ parent: LaTeXMarkdownView) {
            self.parent = parent
            self.lastContent = parent.content
        }
        
        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "heightHandler", let height = message.body as? CGFloat {
                DispatchQueue.main.async {
                    if abs(self.parent.dynamicHeight - height) > 0.5 {
                        self.parent.dynamicHeight = max(height, 18)
                    }
                }
            }
        }
        
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("Math.ceil(document.getElementById('content').scrollHeight)") { result, error in
                if let height = result as? CGFloat {
                    DispatchQueue.main.async {
                        self.parent.dynamicHeight = max(height, 18)
                    }
                }
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
