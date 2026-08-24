package com.sapiens.gagaodok.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.clickableNoRipple
import com.sapiens.gagaodok.ui.icons.MagnifierIcon
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme

/// 목록 화면 위쪽입니다. 제목 + 오른쪽 아이콘 두 개, 그리고 필요할 때 검색창.
///
/// 상태 표시줄 아래로 내려 놓습니다. targetSdk 35에서는 앱이 상태 표시줄 아래까지
/// 그리는 것이 기본이라, 이 여백이 없으면 제목이 시계와 겹칩니다.
@Composable
fun ListTopBar(
    title: String,
    searchVisible: Boolean,
    searchText: String,
    searchPlaceholder: String,
    onToggleSearch: () -> Unit,
    onSearchTextChange: (String) -> Unit,
    actionIcon: @Composable (() -> Unit)? = null,
    onAction: (() -> Unit)? = null
) {
    val colors = KakaoTheme.colors
    val statusInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()

    Column(Modifier.fillMaxWidth().background(colors.surface).padding(top = statusInset)) {
        Row(
            Modifier
                .fillMaxWidth()
                .height(Metrics.topBarHeight)
                .padding(start = Metrics.screenPadding, end = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(title, style = KakaoText.screenTitle, color = colors.textPrimary)
            Box(Modifier.weight(1f))

            IconButton(onClick = onToggleSearch, modifier = Modifier.size(Metrics.touchTarget)) {
                MagnifierIcon(
                    color = colors.textPrimary,
                    modifier = Modifier.size(Metrics.headerIcon)
                )
            }
            if (actionIcon != null && onAction != null) {
                IconButton(onClick = onAction, modifier = Modifier.size(Metrics.touchTarget)) {
                    actionIcon()
                }
            }
        }

        if (searchVisible) {
            val focusRequester = remember { FocusRequester() }
            val keyboard = LocalSoftwareKeyboardController.current
            // 돋보기를 누르면 바로 칠 수 있어야 합니다.
            // 커서를 넣는 것만으로는 키보드가 올라오지 않아 함께 띄웁니다.
            LaunchedEffect(Unit) {
                focusRequester.requestFocus()
                keyboard?.show()
            }

            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = Metrics.screenPadding)
                    .padding(bottom = 10.dp)
                    .background(colors.sunken, RoundedCornerShape(10.dp))
                    .padding(horizontal = 12.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                MagnifierIcon(color = colors.textSecondary, modifier = Modifier.size(15.dp))
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                    if (searchText.isEmpty()) {
                        Text(searchPlaceholder, style = KakaoText.body, color = colors.textTertiary)
                    }
                    BasicTextField(
                        value = searchText,
                        onValueChange = onSearchTextChange,
                        textStyle = LocalTextStyle.current.merge(KakaoText.body)
                            .copy(color = colors.textPrimary),
                        cursorBrush = SolidColor(colors.textPrimary),
                        singleLine = true,
                        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                            imeAction = ImeAction.Search
                        ),
                        modifier = Modifier.fillMaxWidth().focusRequester(focusRequester)
                    )
                }
                if (searchText.isNotEmpty()) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = "검색어 지우기",
                        tint = colors.textSecondary,
                        modifier = Modifier
                            .size(18.dp)
                            .clickableNoRipple { onSearchTextChange("") }
                    )
                }
            }
        }
    }
}

/// 목록이 비었을 때 자리를 채웁니다.
@Composable
fun EmptyState(title: String, detail: String? = null) {
    val colors = KakaoTheme.colors
    Column(
        Modifier.fillMaxWidth().padding(top = 90.dp, start = 30.dp, end = 30.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Text(title, style = KakaoText.roomName, color = colors.textSecondary)
        if (detail != null) {
            Text(
                detail,
                style = KakaoText.caption,
                color = colors.textTertiary,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center
            )
        }
    }
}

@Composable
fun HorizontalGap(width: androidx.compose.ui.unit.Dp) {
    Box(Modifier.width(width))
}
