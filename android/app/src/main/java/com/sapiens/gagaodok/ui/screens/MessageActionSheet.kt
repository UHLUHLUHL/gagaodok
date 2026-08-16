package com.sapiens.gagaodok.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme

/// 말풍선을 길게 눌렀을 때 나오는 메뉴입니다.
///
/// **아래에서 올라오는 시트가 아닙니다.** 원조를 재 보니 화면 한가운데 뜨는 카드였고,
/// 위아래 여백이 467화소·468화소로 정확히 가운데였습니다.
///
/// 실측(1440×2936, 밀도 3.75):
/// | 자리 | 화소 | dp |
/// |---|---|---|
/// | 카드 좌우 여백 | 150 | 40 |
/// | 카드 모서리 | 30 | 8 |
/// | 줄 간격 | 180 | 48 |
/// | 글자 왼쪽 잉크 | 92 | ≈24 |
/// | 아래 여백 | 43 | 11 |
/// | 뒷배경 | ×0.497 | 검정 50% |
///
/// **`Dialog`를 쓰지 않고 화면 위에 직접 덮습니다.**
/// 처음에는 `Dialog`로 만들었는데, 창이 상태 표시줄 아래에서 시작해 그 띠만
/// 안 어두워지고 카드도 정중앙보다 156화소 내려갔습니다. `usePlatformDefaultWidth`,
/// `decorFitsSystemWindows`, `FLAG_LAYOUT_NO_LIMITS`, 노치 모드까지 다 켜도
/// 33화소가 남았습니다. 원조는 y=0부터 어둡고 그 위에 상태 표시줄 글자만 얹혀
/// 있습니다 — 앱이 화면 끝까지 그리는 우리 구조에서는 그냥 덮는 것이 그대로입니다.
///
/// 원조 카드에는 태그 칩 줄과 우리에게 없는 기능(답장·전달·공지 등)이 더 있습니다.
/// **모양만 가져오고 줄은 우리 기능만 둡니다.**
@Composable
fun MessageActionSheet(
    message: ChatMessage,
    onDismiss: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit
) {
    val colors = KakaoTheme.colors
    val context = LocalContext.current

    // 사라질 때도 애니메이션이 보이도록, 실제로 치우는 것은 애니메이션이 끝난 뒤입니다.
    val visible = remember { MutableTransitionState(false).apply { targetState = true } }
    LaunchedEffect(visible.currentState, visible.targetState) {
        if (visible.isIdle && !visible.currentState) onDismiss()
    }
    val close = { visible.targetState = false }

    BackHandler(enabled = visible.targetState) { close() }

    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        AnimatedVisibility(
            visibleState = visible,
            enter = fadeIn(tween(140)),
            exit = fadeOut(tween(120))
        ) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = Metrics.sheetScrimAlpha))
                    // 바깥을 누르면 닫힙니다. 물결은 넣지 않습니다 —
                    // 화면 전체가 번쩍이면 무엇을 눌렀는지 잘못 읽힙니다.
                    .clickable(
                        indication = null,
                        interactionSource = remember { MutableInteractionSource() },
                        onClick = close
                    )
            )
        }
        AnimatedVisibility(
            visibleState = visible,
            // 카드는 살짝 작게 시작해 제자리로 옵니다.
            enter = fadeIn(tween(160)) + scaleIn(tween(180), initialScale = 0.92f),
            exit = fadeOut(tween(120)) + scaleOut(tween(120), targetScale = 0.94f)
        ) {
            Column(
                Modifier
                    .padding(horizontal = Metrics.sheetSideMargin)
                    .fillMaxWidth()
                    .background(colors.surface, RoundedCornerShape(Metrics.sheetCorner))
                    .padding(vertical = Metrics.sheetPaddingV)
            ) {
                // 줄을 고르면 카드는 바로 사라집니다. 고른 뒤에도 잠깐 남아 있으면
                // 다음 화면(수정 바와 키보드)이 그 위로 올라와 겹칩니다.
                ActionRow("복사") {
                    copyToClipboard(context, message.text)
                    onDismiss()
                }
                // 내가 보낸 것만 고칠 수 있습니다.
                if (message.sender == MessageSender.USER) {
                    ActionRow("수정", onClick = onEdit)
                }
                // 원조의 '삭제'도 다른 줄과 같은 검정입니다. 빨강으로 두면
                // 이 카드에서 그 줄만 다른 앱처럼 보입니다.
                ActionRow("삭제", onClick = onDelete)
            }
        }
    }
}

@Composable
private fun ActionRow(title: String, onClick: () -> Unit) {
    val colors = KakaoTheme.colors
    Box(
        Modifier
            .fillMaxWidth()
            .height(Metrics.sheetRowHeight)
            .clickable(onClick = onClick)
            .padding(horizontal = Metrics.sheetRowInset),
        contentAlignment = Alignment.CenterStart
    ) {
        Text(title, style = KakaoText.sheetItem, color = colors.textPrimary)
    }
}

private fun copyToClipboard(context: Context, text: String) {
    val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
    manager.setPrimaryClip(ClipData.newPlainText("가가오독", text))
}
