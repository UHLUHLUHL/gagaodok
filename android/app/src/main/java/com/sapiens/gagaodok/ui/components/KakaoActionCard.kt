package com.sapiens.gagaodok.ui.components

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
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme

/// 카드 한 줄입니다.
data class KakaoMenuItem(
    val title: String,
    /// 지금 고른 것이면 오른쪽에 체크가 붙습니다. 모델·모드처럼 하나만 고르는 목록에 씁니다.
    val checked: Boolean = false,
    val icon: ImageVector? = null,
    val destructive: Boolean = false,
    val onClick: () -> Unit
)

/// 소제목으로 묶인 줄 묶음입니다. 묶음 사이에는 얇은 선이 들어갑니다.
data class KakaoMenuSection(
    val title: String? = null,
    val items: List<KakaoMenuItem> = emptyList(),
    val content: (@Composable () -> Unit)? = null
)

/// 메뉴 카드를 띄우는 손잡이입니다. `LocalKakaoMenu`로 어디서나 꺼내 씁니다.
class KakaoMenuController internal constructor(
    private val setter: (List<KakaoMenuSection>?) -> Unit
) {
    fun show(sections: List<KakaoMenuSection>) = setter(sections)

    /// 소제목 없이 줄만 있는 흔한 경우입니다.
    fun show(vararg items: KakaoMenuItem) = setter(listOf(KakaoMenuSection(items = items.toList())))

    fun dismiss() = setter(null)
}

val LocalKakaoMenu = staticCompositionLocalOf<KakaoMenuController> {
    error("KakaoMenuHost 안에서만 쓸 수 있습니다.")
}

/// 메뉴 카드가 놓일 자리입니다. **앱에서 가장 바깥에 한 번만** 둡니다.
///
/// 화면마다 제자리에서 띄우면 안 됩니다. 처음에 친구·채팅 탭이 그렇게 했더니
/// 카드가 탭 화면 **안에** 놓여서, 아래 탭바(친구·채팅·설정)만 안 어두워지고
/// 카드도 화면 정중앙이 아니라 탭바를 뺀 자리의 가운데에 떴습니다(160화소 위).
/// 원조는 화면 전체가 어두워지고 카드가 화면 한가운데입니다.
@Composable
fun KakaoMenuHost(content: @Composable () -> Unit) {
    var sections by remember { mutableStateOf<List<KakaoMenuSection>?>(null) }
    val controller = remember { KakaoMenuController { sections = it } }

    Box(Modifier.fillMaxSize()) {
        CompositionLocalProvider(LocalKakaoMenu provides controller) { content() }
        sections?.let { KakaoActionCard(it) { sections = null } }
    }
}

/// 화면 한가운데 뜨는 카카오톡식 메뉴 카드입니다.
///
/// 원조의 길게 누르기 메뉴를 재서 만든 것을 부품으로 뺐습니다. 치수는 전부 실측입니다
/// (`Metrics`의 "길게 누르기 메뉴" 절). 카드 좌우 여백 150화소, 모서리 30화소,
/// 줄 간격 180화소, 뒷배경 검정 50%, 그리고 카드가 화면 정중앙입니다.
///
/// **`DropdownMenu`를 대신합니다.** 그쪽은 누른 자리에 붙어서 뜨는 부품인데,
/// 우리가 쓰던 자리에서는 붙일 기준이 화면 구석의 빈 상자라 메뉴가 엉뚱한 데
/// 나타났습니다. 카카오톡에는 그렇게 매달려 뜨는 메뉴 자체가 없습니다.
///
/// **`Dialog`도 쓰지 않습니다.** 창이 상태 표시줄 아래에서 시작해 그 띠만 안 어두워지고,
/// 카드도 정중앙에서 33화소 어긋났습니다. 화면 위에 직접 덮으면 그 문제가 없습니다.
/// 그래서 이 부품은 **화면 전체를 덮는 자리에 놓아야 합니다** — 목록 안이 아니라
/// 화면 맨 바깥 상자의 마지막 자식으로 두십시오.
@Composable
fun KakaoActionCard(
    sections: List<KakaoMenuSection>,
    onDismiss: () -> Unit
) {
    val colors = KakaoTheme.colors

    // 사라질 때도 애니메이션이 보이도록, 실제로 치우는 것은 애니메이션이 끝난 뒤입니다.
    val visible = remember { MutableTransitionState(false).apply { targetState = true } }
    LaunchedEffect(visible.currentState, visible.targetState) {
        if (visible.isIdle && !visible.currentState) onDismiss()
    }
    val close = { visible.targetState = false }

    BackHandler(enabled = visible.targetState) { close() }

    // 줄이 많은 카드(모드+모델+그 밖)는 화면을 넘길 수 있습니다. 넘치면 카드 안에서
    // 스크롤되게 두고, 화면 위아래로는 최소한의 여백을 남깁니다.
    val maxCardHeight = (LocalConfiguration.current.screenHeightDp - 96).dp

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
                    .widthIn(max = 520.dp)
                    .fillMaxWidth()
                    .heightIn(max = maxCardHeight)
                    .background(colors.surface, RoundedCornerShape(Metrics.sheetCorner))
                    .padding(vertical = Metrics.sheetPaddingV)
                    .verticalScroll(rememberScrollState())
            ) {
                sections.forEachIndexed { index, section ->
                    if (index > 0) {
                        Hairline(Modifier.padding(vertical = Metrics.sheetPaddingV))
                    }
                    section.title?.let {
                        Text(
                            it,
                            style = KakaoText.caption,
                            color = colors.textTertiary,
                            modifier = Modifier.padding(
                                start = Metrics.sheetRowInset,
                                bottom = 4.dp
                            )
                        )
                    }
                    section.content?.invoke()
                    section.items.forEach { MenuRow(it) }
                }
            }
        }
    }
}

@Composable
private fun MenuRow(item: KakaoMenuItem) {
    val colors = KakaoTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .height(Metrics.sheetRowHeight)
            .clickable(onClick = item.onClick)
            .padding(horizontal = Metrics.sheetRowInset),
        verticalAlignment = Alignment.CenterVertically
    ) {
        item.icon?.let {
            Icon(
                it,
                contentDescription = null,
                tint = if (item.destructive) Color(0xFFE54848) else colors.textSecondary,
                modifier = Modifier.size(20.dp)
            )
            androidx.compose.foundation.layout.Spacer(Modifier.size(14.dp))
        }
        Text(
            item.title,
            style = KakaoText.sheetItem,
            color = if (item.destructive) Color(0xFFE54848) else colors.textPrimary,
            modifier = Modifier.weight(1f)
        )
        if (item.checked) {
            // 고른 줄에만 붙습니다. 예전에는 글자 앞에 "✓ "를 붙였는데,
            // 그러면 고른 줄만 글자가 오른쪽으로 밀려 목록이 들쭉날쭉했습니다.
            // 색은 말투 표시와 같은 카카오 금색입니다. **원조를 재서 정한 값은 아닙니다.**
            Icon(
                Icons.Filled.Check,
                contentDescription = "선택됨",
                tint = colors.personaBadge,
                modifier = Modifier.size(18.dp)
            )
        }
    }
}
