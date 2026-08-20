package com.sapiens.gagaodok.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.TheaterComedy
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.icons.MagnifierIcon
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme

// 대화방 상단 바입니다.
@Composable
internal fun ChatHeader(
    title: String,
    personaOn: Boolean,
    searchVisible: Boolean,
    searchText: String,
    hitCount: Int,
    hitIndex: Int,
    onBack: () -> Unit,
    onToggleSearch: () -> Unit,
    onSearchTextChange: (String) -> Unit,
    onMoveSearch: (Int) -> Unit,
    onOpenMenu: () -> Unit
) {
    val colors = KakaoTheme.colors
    val statusInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()

    Column(
        Modifier
            .fillMaxWidth()
            .background(colors.chatHeader)
            .padding(top = statusInset)
    ) {
        if (searchVisible) {
            // 검색 중에는 상단 바 자리를 검색창이 덮습니다. 카카오톡과 같은 동작입니다.
            val focusRequester = remember { FocusRequester() }
            val keyboard = LocalSoftwareKeyboardController.current
            // 검색을 열면 바로 칠 수 있어야 합니다. 한 번 더 눌러 커서를 넣게 하면
            // 돋보기를 누른 의도가 두 번에 나뉩니다.
            // 커서를 넣는 것만으로는 키보드가 올라오지 않아 함께 띄웁니다.
            LaunchedEffect(Unit) {
                focusRequester.requestFocus()
                keyboard?.show()
            }

            Row(
                Modifier
                    .fillMaxWidth()
                    .height(Metrics.topBarHeight)
                    .padding(horizontal = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(onClick = onToggleSearch) {
                    // 검색을 열면 이 아이콘이 뒤로 화살표와 **같은 자리**에 들어섭니다.
                    // 크기를 안 적으면 잉크가 52화소로 그려져, 방금까지 73화소이던
                    // 자리가 눈에 띄게 줄어듭니다. 같은 상자를 줘서 튐을 없앱니다.
                    Icon(
                        Icons.Filled.Close, "검색 닫기",
                        tint = colors.onChatHeader,
                        modifier = Modifier.size(Metrics.backIcon)
                    )
                }
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                    if (searchText.isEmpty()) {
                        Text("대화 내용 검색", style = KakaoText.body, color = colors.onChatHeaderDim)
                    }
                    BasicTextField(
                        value = searchText,
                        onValueChange = onSearchTextChange,
                        singleLine = true,
                        textStyle = LocalTextStyle.current.merge(KakaoText.body)
                            .copy(color = colors.onChatHeader),
                        cursorBrush = SolidColor(colors.onChatHeader),
                        modifier = Modifier.fillMaxWidth().focusRequester(focusRequester)
                    )
                }
                Text(
                    if (hitCount == 0) "0" else "${hitIndex + 1}/$hitCount",
                    style = KakaoText.caption,
                    color = colors.onChatHeaderDim
                )
                // 꺾쇠는 원래 납작해서 같은 상자를 줘도 X보다 작아 보입니다.
                // 폭이 X와 비슷하게 읽히도록 한 단 키웠습니다. **원조 검색 막대를 재서
                // 정한 값이 아니라 짐작입니다.** 그 화면 캡처를 아직 못 받았습니다.
                IconButton(onClick = { onMoveSearch(1) }, enabled = hitCount > 0) {
                    Icon(
                        Icons.Filled.KeyboardArrowUp, "이전 결과",
                        tint = colors.onChatHeader,
                        modifier = Modifier.size(Metrics.backIcon)
                    )
                }
                IconButton(onClick = { onMoveSearch(-1) }, enabled = hitCount > 0) {
                    Icon(
                        Icons.Filled.KeyboardArrowDown, "다음 결과",
                        tint = colors.onChatHeader,
                        modifier = Modifier.size(Metrics.backIcon)
                    )
                }
            }
        } else {
            // 원조 대화방 상단 바는 **한 줄입니다.** 뒤로, 굵은 이름, 돋보기, 메뉴뿐이고
            // 프로필 사진도 부제도 없습니다. 실측: 이름 잉크 높이 56화소(≈18sp 굵게),
            // 이름 왼쪽 215화소, 돋보기 66화소.
            //
            // 우리 앱이 헤더에 두던 "모델 · 모드" 줄은 뺐습니다. 대신 이름을 누르면
            // 나오는 메뉴에 지금 쓰는 모델과 모드가 ✓로 표시되므로 정보는 그대로 있고
            // 두 줄짜리 헤더만 없어집니다.
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(Metrics.topBarHeight)
                    .padding(start = 4.dp, end = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(onClick = onBack) {
                    // 크기를 적지 않으면 Material 기본값(24dp 상자)으로 그려지는데,
                    // 화살표는 그 상자를 다 안 채워서 잉크가 60화소밖에 안 됩니다.
                    // 옆의 돋보기(68화소)보다 작아 보였습니다. 원조는 반대로
                    // 뒤로(72)가 돋보기(66)보다 조금 큽니다.
                    Icon(
                        Icons.AutoMirrored.Filled.ArrowBack, "뒤로",
                        tint = colors.onChatHeader,
                        modifier = Modifier.size(Metrics.backIcon)
                    )
                }
                Row(
                    Modifier
                        .weight(1f)
                        .padding(start = 2.dp)
                        .clickable(onClick = onOpenMenu),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        title,
                        style = KakaoText.roomTitle,
                        color = colors.onChatHeader,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    if (personaOn) {
                        Icon(
                            Icons.Filled.TheaterComedy, "말투 적용됨",
                            tint = colors.personaBadge,
                            modifier = Modifier.padding(start = 6.dp).size(16.dp)
                        )
                    }
                }
                IconButton(onClick = onToggleSearch) {
                    MagnifierIcon(colors.onChatHeader, Modifier.size(Metrics.roomHeaderIcon))
                }
                IconButton(onClick = onOpenMenu) {
                    Icon(
                        Icons.Filled.MoreVert,
                        "대화방 메뉴",
                        tint = colors.onChatHeader,
                        modifier = Modifier.size(Metrics.roomHeaderIcon + 2.dp)
                    )
                }
            }
        }
        // 원조 대화방에는 상단 바 아래 구분선이 없습니다. 바탕이 대화 배경과 같은 색으로
        // 그대로 이어집니다. 다크 모드는 바탕 색이 이미 달라 선 없이도 갈립니다.
    }
}

// MARK: - 입력창
