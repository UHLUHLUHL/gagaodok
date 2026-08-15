package com.sapiens.gagaodok.ui.components

import android.annotation.SuppressLint
import android.graphics.Color as AndroidColor
import android.view.MotionEvent
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import org.json.JSONObject

/// 웹뷰 하나가 지금 무엇을 그리고 있는지입니다.
///
/// 셸 문서를 띄우는 동안에도 화면은 여러 번 다시 그려집니다. 그때마다 자바스크립트를
/// 부르면 아직 준비되지 않은 페이지에 대고 부르는 것이라 아무 일도 일어나지 않고,
/// 그 사이 "이미 그렸다"고 기록해 두면 정작 준비된 뒤에 그리지 않게 됩니다.
/// 실제로 그렇게 말풍선이 통째로 비었습니다. 그래서 준비 여부와 마지막으로 그린 내용을
/// 함께 들고 다니며, 준비된 순간에 밀린 내용을 한 번 그립니다.
private class BubbleWebState {
    var ready = false
    var rendered: String? = null
    var pending: String? = null
}

/// 수식과 마크다운이 든 말풍선을 웹뷰로 그립니다.
///
/// 안드로이드 웹뷰는 맥의 WKWebView보다 훨씬 무겁습니다. 인스턴스 하나에 수십 MB를
/// 쓰고 만드는 것도 느려서, 말풍선마다 하나씩 두면 긴 대화에서 스크롤이 끊깁니다.
/// 그래서 두 가지를 합니다.
///
/// 1. 수식이 없는 말풍선은 아예 여기 오지 않습니다(`needsWebView`가 갈라냅니다).
/// 2. 여기 온 말풍선도 셸 문서를 한 번만 띄우고 내용만 갈아끼웁니다.
///    `LazyColumn`이 화면 밖 항목을 버리므로 살아 있는 웹뷰는 보이는 개수만큼입니다.
///
/// 높이는 웹뷰가 알려 줍니다. KaTeX가 다 그리고 글꼴이 도착해야 확정되므로,
/// 그 전에는 어림잡은 높이로 자리를 잡고 있다가 알려 온 값으로 고칩니다.
@SuppressLint("SetJavaScriptEnabled", "ClickableViewAccessibility")
@Composable
fun MathMarkdownView(
    content: String,
    isMine: Boolean,
    searchQuery: String = "",
    isCurrentSearchHit: Boolean = false,
    modifier: Modifier = Modifier
) {
    val density = LocalDensity.current
    val isDark = KakaoTheme.colors.isDark
    // 글자 한 줄쯤으로 시작합니다. 0으로 두면 확정되기 전까지 말풍선이 납작하게 접힙니다.
    var heightDp by remember(content) { mutableFloatStateOf(24f) }
    val state = remember { BubbleWebState() }
    val payload = remember(content, isDark, searchQuery, isCurrentSearchHit) {
        script(content, isDark, searchQuery, isCurrentSearchHit)
    }

    AndroidView(
        modifier = modifier
            .fillMaxWidth()
            .height(heightDp.dp),
        factory = { context ->
            WebView(context).apply {
                setBackgroundColor(AndroidColor.TRANSPARENT)
                isVerticalScrollBarEnabled = false
                isHorizontalScrollBarEnabled = false
                // 말풍선 안에서 스크롤이 잡히면 대화 목록이 안 움직입니다.
                // 가로로 넘치는 수식은 페이지 안의 .katex-display가 따로 처리합니다.
                setOnTouchListener { _, event -> event.action == MotionEvent.ACTION_MOVE }
                settings.apply {
                    javaScriptEnabled = true
                    allowFileAccess = false
                    allowContentAccess = false
                    domStorageEnabled = false
                    // 기기 글꼴 배율이 커도 말풍선이 무너지지 않게 웹뷰는 앱이 정한 크기를 씁니다.
                    textZoom = 100
                }
                addJavascriptInterface(object {
                    @JavascriptInterface
                    fun setHeight(px: Int) {
                        post { heightDp = px / density.density + 1f }
                    }

                    @JavascriptInterface
                    fun onReady() {
                        post { markReady(this@apply, state) }
                    }
                }, "AndroidBridge")

                webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView, url: String?) {
                        markReady(view, state)
                    }
                }
                webChromeClient = object : android.webkit.WebChromeClient() {
                    override fun onConsoleMessage(m: android.webkit.ConsoleMessage): Boolean {
                        android.util.Log.d("BubbleWeb", m.message())
                        return true
                    }
                }
                loadUrl("file:///android_asset/bubble.html")
            }
        },
        update = { view ->
            state.pending = payload
            if (state.ready && state.rendered != payload) {
                state.rendered = payload
                view.evaluateJavascript(payload, null)
            }
        }
    )
}

private fun markReady(view: WebView, state: BubbleWebState) {
    state.ready = true
    val payload = state.pending ?: return
    if (state.rendered == payload) return
    state.rendered = payload
    view.evaluateJavascript(payload, null)
}

private fun script(
    content: String,
    isDark: Boolean,
    searchQuery: String,
    isCurrentSearchHit: Boolean
): String {
    // 글을 자바스크립트 문자열 리터럴로 안전하게 넣습니다.
    // 따옴표나 줄바꿈, 역슬래시가 그대로 들어가면 수식 하나에 스크립트가 통째로 깨집니다.
    val encoded = JSONObject.quote(content)
    val query = JSONObject.quote(searchQuery)
    return """
    (function () {
        if (!window.renderContent) return;
        window.setTheme($isDark);
        window.renderContent($encoded);
        window.highlightSearch($query, $isCurrentSearchHit);
    })();
    """.trimIndent()
}
