package com.sapiens.gagaodok.ui.screens

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.GagaodokApp
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.components.RoomAvatar
import com.sapiens.gagaodok.ui.icons.ChatBubbleGlyph
import com.sapiens.gagaodok.ui.theme.KakaoText
import java.util.UUID

/// 상대 한 사람의 프로필입니다.
///
/// 친구 탭에서 친구를 누르면 여기로 옵니다. **예전에는 바로 대화방으로 갔습니다.**
/// 그래서 프로필을 고치려면 길게 눌러 메뉴를 띄우는 수밖에 없었는데, 그건 알고
/// 있어야만 쓸 수 있는 길이라 사실상 없는 기능이었습니다. 대화방에서 상대
/// 프로필 사진을 눌러도 같은 화면이 열립니다.
///
/// **화면 전체가 어둡습니다.** 카카오톡 프로필이 그렇습니다. 사진이 있으면 그것을
/// 화면 가득 깔고 어둡게 덮은 뒤 그 위에 글자를 얹습니다. 그래서 이 화면의 글자색은
/// 테마를 따르지 않고 늘 흰색입니다 — 라이트 모드에서도 바탕은 어둡습니다.
///
/// **치수는 실측이 아니라 짐작입니다.** 카카오톡 프로필 화면 캡처를 아직 못 받았습니다.
/// 아바타 크기, 글자 크기, 아래 단추 줄의 높이가 모두 그렇습니다.
@Composable
fun ProfileScreen(
    roomId: UUID,
    onBack: () -> Unit,
    onOpenRoom: (UUID) -> Unit,
    onEditPersona: (UUID) -> Unit
) {
    val context = LocalContext.current
    val app = context.applicationContext as GagaodokApp
    val store = app.chatStore

    val rooms by store.rooms.collectAsState()
    val room = rooms.firstOrNull { it.id == roomId }
    if (room == null) {
        // 방이 지워진 뒤에 남아 있던 화면입니다. 조용히 빠져나갑니다.
        LaunchedEffect(Unit) { onBack() }
        return
    }

    var editing by remember { mutableStateOf(false) }
    val avatar = store.avatar(room.id, room.profile)

    Box(Modifier.fillMaxSize().background(ProfileBackdrop)) {
        // 사진이 있으면 그것이 바탕이 됩니다. 사진 위에 바로 흰 글자를 얹으면
        // 밝은 사진에서 이름이 사라지므로 반드시 어둡게 덮습니다.
        if (avatar != null) {
            Image(
                bitmap = avatar.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)))
        }

        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(Icons.Filled.Close, "닫기", tint = ProfileForeground)
                }
                Spacer(Modifier.weight(1f))
                IconButton(onClick = { store.togglePinned(room.id) }) {
                    Icon(
                        if (room.isPinned) Icons.Filled.Star else Icons.Filled.StarBorder,
                        if (room.isPinned) "즐겨찾기 해제" else "즐겨찾기",
                        tint = if (room.isPinned) FavoriteMark else ProfileForeground
                    )
                }
                IconButton(onClick = { editing = true }) {
                    Icon(Icons.Outlined.Edit, "프로필 편집", tint = ProfileForeground)
                }
            }

            // 위쪽을 조금 더 비웁니다. 정확히 가운데 두면 아래 단추 줄과 겹쳐 보여
            // 이름이 화면 아래쪽에 몰린 것처럼 읽힙니다.
            Spacer(Modifier.weight(1f))

            Column(
                Modifier.fillMaxWidth().padding(horizontal = Metrics.screenPadding),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                RoomAvatar(avatar, ProfileAvatar)
                Text(
                    room.profile.name,
                    style = KakaoText.screenTitle,
                    color = ProfileForeground,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 14.dp)
                )
                if (room.profile.statusMessage.isNotEmpty()) {
                    Text(
                        room.profile.statusMessage,
                        style = KakaoText.body,
                        color = ProfileForegroundDim,
                        textAlign = TextAlign.Center,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = 8.dp)
                    )
                }
            }

            Spacer(Modifier.weight(1.3f))

            // 아래 단추 줄. 위의 얇은 선은 테마의 것이 아니라 흰색 계열입니다 —
            // 바탕이 늘 어둡기 때문에 테마 선(검정 8%)은 여기서 보이지 않습니다.
            Box(Modifier.fillMaxWidth().height(1.dp).background(ProfileHairline))
            Row(
                Modifier.fillMaxWidth().navigationBarsPadding(),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                // 말풍선은 아래 탭바에서 쓰던 것을 그대로 씁니다. Material의 말풍선은
                // 꼬리 모양도 굵기도 달라서, 같은 앱 안에서 두 종류가 보입니다.
                ProfileAction(
                    icon = { ChatBubbleGlyph(ProfileForeground, Modifier.size(ProfileActionIcon)) },
                    label = "1:1 채팅"
                ) { onOpenRoom(room.id) }
                ProfileAction(
                    icon = {
                        Icon(
                            Icons.Outlined.Edit, null,
                            tint = ProfileForeground,
                            modifier = Modifier.size(ProfileActionIcon)
                        )
                    },
                    // 말투 편집은 여기 따로 두지 않습니다. 프로필 편집 안에 들어 있습니다.
                    label = "프로필 편집"
                ) { editing = true }
            }
        }
    }

    if (editing) {
        ProfileEditSheet(
            title = "프로필 편집",
            confirmLabel = "저장",
            initialName = room.profile.name,
            initialStatus = room.profile.statusMessage,
            initialAvatar = avatar,
            // 말투 편집은 프로필 편집 안에 있습니다. 아래 단추 줄에 따로 두지 않습니다.
            onEditPersona = { editing = false; onEditPersona(room.id) },
            onDismiss = { editing = false },
            onConfirm = { result ->
                store.updateProfile(room.id, result.name, result.statusMessage)
                if (result.didChangeImage) store.updateAvatar(room.id, result.image)
                editing = false
            }
        )
    }
}

@Composable
private fun ProfileAction(
    icon: @Composable () -> Unit,
    label: String,
    onClick: () -> Unit
) {
    Column(
        Modifier
            .clickable(
                // 물결을 끕니다. 어두운 바탕 위의 사각 물결은 단추가 아니라
                // 판 하나가 통째로 번쩍이는 것으로 보입니다.
                indication = null,
                interactionSource = remember { MutableInteractionSource() },
                onClick = onClick
            )
            .padding(horizontal = 28.dp, vertical = 14.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        icon()
        Text(
            label,
            style = KakaoText.caption,
            color = ProfileForeground,
            modifier = Modifier.padding(top = 6.dp)
        )
    }
}

// 사진이 없을 때의 바탕입니다. 카카오톡 기본 프로필 배경과 같은 결의 청회색입니다. (짐작)
private val ProfileBackdrop = Color(0xFF3B4650)
private val ProfileForeground = Color(0xFFFFFFFF)
private val ProfileForegroundDim = Color(0xB3FFFFFF)
private val ProfileHairline = Color(0x33FFFFFF)
private val FavoriteMark = Color(0xFFFEE500)
private val ProfileAvatar = 112.dp
private val ProfileActionIcon = 24.dp
