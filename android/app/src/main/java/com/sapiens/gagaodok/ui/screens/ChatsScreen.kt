package com.sapiens.gagaodok.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.TheaterComedy
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.GagaodokApp
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.components.RoomAvatar
import com.sapiens.gagaodok.ui.icons.ComposeChatIcon
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.UUID

@Composable
fun ChatsScreen(onOpenRoom: (UUID) -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as GagaodokApp
    val store = app.chatStore
    val colors = KakaoTheme.colors

    val rooms by store.rooms.collectAsState()
    val withConversation by store.roomsWithConversation.collectAsState()

    var searchVisible by remember { mutableStateOf(false) }
    var searchText by remember { mutableStateOf("") }
    var addingFriend by remember { mutableStateOf(false) }
    var editingRoom by remember { mutableStateOf<ChatRoom?>(null) }

    val query = searchText.trim()
    val listed = remember(rooms, withConversation, query) {
        store.conversationRooms(rooms, withConversation).filter { room ->
            query.isEmpty() ||
                room.profile.name.contains(query, ignoreCase = true) ||
                room.profile.statusMessage.contains(query, ignoreCase = true) ||
                store.firstMatch(room.id, query) != null
        }
    }

    Column(Modifier.fillMaxSize().background(colors.surface)) {
        ListTopBar(
            title = "채팅",
            searchVisible = searchVisible,
            searchText = searchText,
            searchPlaceholder = "채팅방 이름, 대화 내용 검색",
            onToggleSearch = {
                searchVisible = !searchVisible
                if (searchVisible) {
                    // 첫 타자에서 모든 방을 한꺼번에 읽느라 멈추지 않도록 미리 만들어 둡니다.
                    store.primeSearchIndex()
                } else {
                    searchText = ""
                }
            },
            onSearchTextChange = { searchText = it },
            actionIcon = {
                ComposeChatIcon(colors.textPrimary, Modifier.size(Metrics.headerIcon))
            },
            onAction = { addingFriend = true }
        )

        if (listed.isEmpty()) {
            EmptyState(
                title = if (query.isEmpty()) "진행 중인 대화가 없어요" else "검색 결과가 없어요",
                detail = if (query.isEmpty()) "친구 탭에서 상대를 골라 대화를 시작해 보세요." else null
            )
        } else {
            LazyColumn(Modifier.fillMaxSize()) {
                items(listed, key = { it.id }) { room ->
                    ChatRoomRow(
                        room = room,
                        // 검색 중에는 마지막 대화 대신 찾은 문장을 보여줍니다. 카카오톡과 같은 방식입니다.
                        preview = if (query.isEmpty()) room.lastMessageText
                        else store.firstMatch(room.id, query) ?: room.lastMessageText,
                        avatar = store.avatar(room.id, room.profile),
                        onOpen = { onOpenRoom(room.id) },
                        onTogglePin = { store.togglePinned(room.id) },
                        onEditProfile = { editingRoom = room },
                        onDelete = { store.deleteRoom(room.id) }
                    )
                }
            }
        }
    }

    if (addingFriend) {
        ProfileEditSheet(
            title = "새 대화 상대",
            confirmLabel = "추가",
            initialName = "",
            initialStatus = "",
            initialAvatar = null,
            onDismiss = { addingFriend = false },
            onConfirm = { result ->
                val room = store.createRoom(result.name, result.statusMessage)
                if (result.didChangeImage) store.updateAvatar(room.id, result.image)
                addingFriend = false
            }
        )
    }

    editingRoom?.let { room ->
        ProfileEditSheet(
            title = "프로필 편집",
            confirmLabel = "저장",
            initialName = room.profile.name,
            initialStatus = room.profile.statusMessage,
            initialAvatar = store.avatar(room.id, room.profile),
            onDismiss = { editingRoom = null },
            onConfirm = { result ->
                store.updateProfile(room.id, result.name, result.statusMessage)
                if (result.didChangeImage) store.updateAvatar(room.id, result.image)
                editingRoom = null
            }
        )
    }
}

@Composable
private fun ChatRoomRow(
    room: ChatRoom,
    preview: String,
    avatar: android.graphics.Bitmap?,
    onOpen: () -> Unit,
    onTogglePin: () -> Unit,
    onEditProfile: () -> Unit,
    onDelete: () -> Unit
) {
    val colors = KakaoTheme.colors
    var menuOpen by remember { mutableStateOf(false) }

    Box {
        Row(
            Modifier
                .fillMaxWidth()
                // 맥 판은 마우스를 올리면 행이 밝아졌습니다. 모바일에는 올림이 없으므로
                // 눌림 효과로 바뀝니다. 길게 누르면 맥 판의 오른쪽 클릭 메뉴가 나옵니다.
                .combinedClickable(onClick = onOpen, onLongClick = { menuOpen = true })
                // 실측: 행 간격 285화소에서 아바타 180화소를 빼고 반씩 나눈 값입니다.
                .padding(horizontal = Metrics.screenPadding, vertical = Metrics.listRowPaddingV),
            verticalAlignment = Alignment.CenterVertically
        ) {
            RoomAvatar(avatar, Metrics.listAvatar)
            Column(
                Modifier
                    .weight(1f)
                    .padding(start = Metrics.listAvatarGap)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        room.profile.name,
                        style = KakaoText.listName,
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    // 여백을 먼저, 크기를 나중에 적습니다. 순서를 바꾸면 여백이
                    // 크기 안쪽으로 파고들어 12dp 상자 안에 9dp짜리 찌그러진 그림이 남습니다.
                    if (room.isPinned) {
                        Icon(
                            Icons.Filled.PushPin, contentDescription = "상단 고정",
                            tint = colors.textTertiary,
                            modifier = Modifier.padding(start = 4.dp).size(Metrics.rowBadge)
                        )
                    }
                    if (room.profile.persona.isEnabled) {
                        Icon(
                            Icons.Filled.TheaterComedy, contentDescription = "말투 적용됨",
                            tint = colors.personaBadge,
                            modifier = Modifier.padding(start = 4.dp).size(Metrics.rowBadge)
                        )
                    }
                    Box(Modifier.weight(1f))
                    Text(
                        formatRoomTime(room.lastMessageTime),
                        style = KakaoText.listTime,
                        color = colors.textTertiary
                    )
                }
                Text(
                    cleanSnippet(preview),
                    style = KakaoText.listPreview,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    // 실측: 이름 잉크 아래와 미리보기 잉크 위 사이가 38화소입니다.
                    modifier = Modifier.padding(top = 5.dp)
                )
            }
        }

        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(text = { Text("채팅방 열기") }, onClick = { menuOpen = false; onOpen() })
            DropdownMenuItem(text = { Text("프로필 편집") }, onClick = { menuOpen = false; onEditProfile() })
            DropdownMenuItem(
                text = { Text(if (room.isPinned) "상단 고정 해제" else "상단 고정") },
                onClick = { menuOpen = false; onTogglePin() }
            )
            DropdownMenuItem(text = { Text("채팅방 나가기") }, onClick = { menuOpen = false; onDelete() })
        }
    }
}

/// 목록 미리보기에서 수식 기호를 걷어 냅니다. 원문 그대로 두면 `$\frac{1}{2}$`가
/// 그대로 보여서 무슨 대화였는지 알아볼 수 없습니다.
internal fun cleanSnippet(text: String): String =
    text.replace("$", "")
        .replace("\\frac", "")
        .replace("\\pi", "π")
        .replace("\\cos", "cos")
        .replace("\\sin", "sin")
        .replace("\\tan", "tan")
        .replace("\\theta", "θ")
        .trim()

internal fun formatRoomTime(millis: Long): String {
    val now = Calendar.getInstance()
    val then = Calendar.getInstance().apply { timeInMillis = millis }
    val sameDay = now.get(Calendar.YEAR) == then.get(Calendar.YEAR) &&
        now.get(Calendar.DAY_OF_YEAR) == then.get(Calendar.DAY_OF_YEAR)
    val pattern = if (sameDay) "a h:mm" else "M월 d일"
    return SimpleDateFormat(pattern, Locale.KOREA).format(Date(millis))
}
