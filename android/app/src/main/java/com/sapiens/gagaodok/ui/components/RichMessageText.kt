package com.sapiens.gagaodok.ui.components

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme

/// 말풍선 안의 글입니다.
///
/// 수식이나 표가 들어 있으면 KaTeX를 띄운 웹뷰로 넘기고, 그렇지 않으면 네이티브로
/// 그립니다. 안드로이드 웹뷰는 인스턴스 하나에 수십 MB를 쓰고 만드는 것도 느려서,
/// 말풍선마다 하나씩 두면 긴 대화에서 스크롤이 끊깁니다. 실제로 대부분의 말풍선에는
/// 수식이 없으므로 이 갈래 하나로 큰 몫을 아낍니다.
@Composable
fun RichMessageText(
    text: String,
    isMine: Boolean,
    searchQuery: String = "",
    isCurrentSearchHit: Boolean = false,
    modifier: Modifier = Modifier
) {
    val colors = KakaoTheme.colors
    val textColor = if (isMine) colors.bubbleMineText else colors.bubbleTheirsText

    if (needsWebView(text)) {
        MathMarkdownView(
            content = text,
            isMine = isMine,
            searchQuery = searchQuery,
            isCurrentSearchHit = isCurrentSearchHit,
            modifier = modifier
        )
        return
    }

    val annotated = remember(text, searchQuery, isCurrentSearchHit) {
        inlineMarkdown(text).let {
            if (searchQuery.isBlank()) it
            else applyHighlight(it, searchQuery, isCurrentSearchHit, colors.searchHit, colors.searchHitCurrent)
        }
    }

    Text(annotated, style = KakaoText.bubble, color = textColor, modifier = modifier)
}

/// 웹뷰가 필요한 글인지 봅니다. 수식과 블록 문법만 웹뷰로 보냅니다.
///
/// 굵게·기울임처럼 줄 안에서 끝나는 문법은 네이티브로도 충분합니다.
/// 그것까지 웹뷰로 보내면 평범한 대화 말풍선 대부분이 웹뷰가 되어 버립니다.
fun needsWebView(text: String): Boolean {
    if (text.contains('$') || text.contains("\\(") || text.contains("\\[") ||
        text.contains("\\frac") || text.contains("\\sqrt")
    ) return true
    if (text.contains("```") || text.contains("| ")) return true
    return text.lineSequence().any { line ->
        val trimmed = line.trim()
        // 수평선(---)이나 제목·목록처럼 줄 단위로만 의미를 갖는 문법입니다.
        if (trimmed.length >= 3 && trimmed.toSet().size == 1 &&
            (trimmed[0] == '-' || trimmed[0] == '_')
        ) return@any true
        trimmed.startsWith("# ") || trimmed.startsWith("## ") || trimmed.startsWith("- ")
    }
}

/// 줄 안에서 끝나는 마크다운만 처리합니다. `**굵게**`, `*기울임*`, `~~취소선~~`, `` `코드` ``.
internal fun inlineMarkdown(text: String): AnnotatedString = buildAnnotatedString {
    var i = 0
    val n = text.length
    while (i < n) {
        val bold = matchDelimited(text, i, "**")
        if (bold != null) {
            withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(bold.first) }
            i = bold.second
            continue
        }
        val strike = matchDelimited(text, i, "~~")
        if (strike != null) {
            withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) { append(strike.first) }
            i = strike.second
            continue
        }
        val code = matchDelimited(text, i, "`")
        if (code != null) {
            withStyle(SpanStyle(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)) {
                append(code.first)
            }
            i = code.second
            continue
        }
        append(text[i])
        i += 1
    }
}

/// `text[from]`에서 시작하는 구분자 쌍을 찾습니다. 찾으면 (안쪽 글, 다음 위치)입니다.
private fun matchDelimited(text: String, from: Int, mark: String): Pair<String, Int>? {
    if (!text.startsWith(mark, from)) return null
    val contentStart = from + mark.length
    val end = text.indexOf(mark, contentStart)
    if (end < 0 || end == contentStart) return null
    // 줄을 넘어가면 강조가 아니라 그냥 기호로 봅니다.
    val inner = text.substring(contentStart, end)
    if (inner.contains('\n')) return null
    return inner to (end + mark.length)
}

private fun applyHighlight(
    source: AnnotatedString,
    query: String,
    isCurrent: Boolean,
    hit: androidx.compose.ui.graphics.Color,
    hitCurrent: androidx.compose.ui.graphics.Color
): AnnotatedString {
    val needle = query.lowercase()
    val haystack = source.text.lowercase()
    return buildAnnotatedString {
        append(source)
        var index = 0
        while (true) {
            val found = haystack.indexOf(needle, index)
            if (found < 0) break
            addStyle(
                SpanStyle(background = if (isCurrent) hitCurrent else hit),
                found,
                found + needle.length
            )
            index = found + needle.length
        }
    }
}
