package com.sapiens.gagaodok.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.ui.components.Hairline
import com.sapiens.gagaodok.ui.icons.ChatBubbleGlyph
import com.sapiens.gagaodok.ui.icons.GearIcon
import com.sapiens.gagaodok.ui.icons.PersonGlyph
import com.sapiens.gagaodok.ui.screens.ChatsScreen
import com.sapiens.gagaodok.ui.screens.FriendsScreen
import com.sapiens.gagaodok.ui.screens.SettingsScreen
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme

/// 아래 탭 세 개입니다.
///
/// 맥 판은 왼쪽에 세로 막대를 뒀지만 그대로 옮기면 안 됩니다. 폭 48dp를 통째로
/// 먹는데 360dp 폰에서 그건 화면의 13%입니다. 카카오톡 모바일이 막대 대신
/// 아래 탭바를 쓰는 이유가 그것입니다.
enum class RootTab(val label: String) {
    FRIENDS("친구"),
    CHATS("채팅"),
    SETTINGS("설정")
}

@Composable
fun RootScreen(
    onOpenRoom: (java.util.UUID) -> Unit
) {
    var tab by rememberSaveable { mutableStateOf(RootTab.CHATS) }
    val colors = KakaoTheme.colors

    Column(
        Modifier
            .fillMaxSize()
            .background(colors.surface)
    ) {
        Box(Modifier.weight(1f)) {
            // 탭을 바꿀 때 옆으로 미는 대신 부드럽게 겹칩니다.
            // 옆으로 밀면 뒤로가기로 돌아가는 화면처럼 읽혀서, 나란한 탭에는 맞지 않습니다.
            AnimatedContent(
                targetState = tab,
                transitionSpec = {
                    fadeIn(tween(120)) togetherWith fadeOut(tween(120))
                },
                label = "tab"
            ) { current ->
                when (current) {
                    RootTab.FRIENDS -> FriendsScreen(onOpenRoom = onOpenRoom)
                    RootTab.CHATS -> ChatsScreen(onOpenRoom = onOpenRoom)
                    RootTab.SETTINGS -> SettingsScreen()
                }
            }
        }

        Hairline()
        BottomTabBar(selected = tab, onSelect = { tab = it })
    }
}

@Composable
private fun BottomTabBar(selected: RootTab, onSelect: (RootTab) -> Unit) {
    val colors = KakaoTheme.colors
    // 제스처 바 위로 올려 둡니다. edge-to-edge라 앱이 그 아래까지 그리기 때문에
    // 이 여백이 없으면 탭 글자가 제스처 바에 가립니다.
    val bottomInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()

    Row(
        Modifier
            .fillMaxWidth()
            .background(colors.tabBar)
            .padding(bottom = bottomInset)
            .height(Metrics.tabBarHeight),
        verticalAlignment = Alignment.CenterVertically
    ) {
        RootTab.entries.forEach { entry ->
            TabItem(
                tab = entry,
                selected = selected == entry,
                onSelect = { onSelect(entry) },
                modifier = Modifier.weight(1f)
            )
        }
    }
}

@Composable
private fun TabItem(
    tab: RootTab,
    selected: Boolean,
    onSelect: () -> Unit,
    modifier: Modifier = Modifier
) {
    val colors = KakaoTheme.colors
    // 원본은 선택 여부로 채움/외곽선을 나누지 않습니다. 둘 다 채운 채 색만 바꿉니다.
    val tint: Color = if (selected) colors.textPrimary else colors.textTertiary
    val interaction = remember { MutableInteractionSource() }

    Column(
        modifier
            .fillMaxSize()
            .selectable(
                selected = selected,
                interactionSource = interaction,
                indication = null,
                role = Role.Tab,
                onClick = onSelect
            ),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        val iconModifier = Modifier.size(Metrics.tabIcon)
        when (tab) {
            RootTab.FRIENDS -> PersonGlyph(tint, iconModifier)
            RootTab.CHATS -> ChatBubbleGlyph(tint, iconModifier)
            RootTab.SETTINGS -> GearIcon(tint, iconModifier)
        }
        Text(
            tab.label,
            style = KakaoText.tabLabel,
            color = tint,
            // 실측: 아이콘 잉크 아래와 글자 잉크 위 사이가 26화소입니다.
            modifier = Modifier.padding(top = 5.dp)
        )
    }
}
