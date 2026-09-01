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
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.BuildConfig
import com.sapiens.gagaodok.GagaodokApp
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.components.KakaoMenuItem
import com.sapiens.gagaodok.ui.components.LocalKakaoMenu
import com.sapiens.gagaodok.ui.components.RoomAvatar
import com.sapiens.gagaodok.ui.icons.ComposeChatIcon
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import com.sapiens.gagaodok.sync.SyncRemoteRoomCatalog
import com.sapiens.gagaodok.sync.SyncRemoteRoomRepository
import com.sapiens.gagaodok.sync.SyncRemoteRoomSnapshot
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun ChatsScreen(
    onOpenRoom: (UUID) -> Unit,
    onOpenProfile: (UUID) -> Unit,
    onEditPersona: (UUID) -> Unit
) {
    val context = LocalContext.current
    val app = context.applicationContext as GagaodokApp
    val store = app.chatStore
    val colors = KakaoTheme.colors
    val coroutineScope = rememberCoroutineScope()

    val rooms by store.rooms.collectAsState()
    val withConversation by store.roomsWithConversation.collectAsState()

    var searchVisible by remember { mutableStateOf(false) }
    var searchText by remember { mutableStateOf("") }
    var addingFriend by remember { mutableStateOf(false) }
    var creatingGroup by remember { mutableStateOf(false) }
    var editingRoom by remember { mutableStateOf<ChatRoom?>(null) }
    var remoteRooms by remember { mutableStateOf<List<SyncRemoteRoomSnapshot>>(emptyList()) }
    var selectedRemoteRoom by remember { mutableStateOf<SyncRemoteRoomSnapshot?>(null) }
    val menu = LocalKakaoMenu.current

    LaunchedEffect(Unit) {
        remoteRooms = withContext(Dispatchers.IO) {
            val viewer = if (BuildConfig.TABLET_MENTOR) "TABLET_SPACE" else "PHONE_SPACE"
            SyncRemoteRoomCatalog(
                SyncRemoteRoomRepository(File(context.filesDir, "KakaoSapiens")), viewer,
            ).refresh()
        }
    }

    fun openMenu(room: ChatRoom) = menu.show(
        KakaoMenuItem("채팅방 열기") { menu.dismiss(); onOpenRoom(room.id) },
        KakaoMenuItem("프로필 보기") { menu.dismiss(); onOpenProfile(room.id) },
        KakaoMenuItem("프로필 편집") { menu.dismiss(); editingRoom = room },
        KakaoMenuItem(if (room.isPinned) "상단 고정 해제" else "상단 고정") {
            menu.dismiss(); store.togglePinned(room.id)
        },
        KakaoMenuItem("채팅방 나가기") {
            menu.dismiss()
            coroutineScope.launch(Dispatchers.IO) { store.deleteRoom(room.id) }
        }
    )

    val query = searchText.trim()
    val listed = remember(rooms, withConversation, query) {
        store.conversationRooms(rooms, withConversation).filter { room ->
            query.isEmpty() ||
                room.profile.name.contains(query, ignoreCase = true) ||
                room.profile.statusMessage.contains(query, ignoreCase = true) ||
                store.firstMatch(room.id, query) != null
        }
    }
    val listedRemote = remember(remoteRooms, query) {
        remoteRooms.filter { remote ->
            query.isEmpty() || remote.title.contains(query, ignoreCase = true) ||
                remote.messages.any { it.text.contains(query, ignoreCase = true) }
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
            onAction = {
                if (BuildConfig.TABLET_MENTOR) {
                    addingFriend = true
                } else {
                    menu.show(
                        KakaoMenuItem("새 대화 상대") { menu.dismiss(); addingFriend = true },
                        KakaoMenuItem("새 단톡방") { menu.dismiss(); creatingGroup = true }
                    )
                }
            }
        )

        if (listed.isEmpty() && listedRemote.isEmpty()) {
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
                        onLongPress = { openMenu(room) }
                    )
                }
                if (listedRemote.isNotEmpty()) {
                    item(key = "remote-header") {
                        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
                            Text("다른 기기의 방 ${listedRemote.size}", style = KakaoText.listPreview, color = colors.textSecondary)
                            androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
                            Text("수동 확인 필요", style = KakaoText.listPreview, color = colors.textTertiary)
                        }
                    }
                    items(listedRemote, key = { "remote-${it.handle.originSpaceId}-${it.handle.roomId}" }) { remote ->
                        RemoteRoomRow(remote) { selectedRemoteRoom = remote }
                    }
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

    if (creatingGroup) {
        GroupChatCreationSheet(
            rooms = rooms,
            avatarFor = { store.avatar(it.id, it.profile) },
            onDismiss = { creatingGroup = false },
            onCreate = { title, participants ->
                val room = store.createGroupRoom(title, participants)
                creatingGroup = false
                onOpenRoom(room.id)
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
            onEditPersona = { editingRoom = null; onEditPersona(room.id) },
            onDismiss = { editingRoom = null },
            onConfirm = { result ->
                store.updateProfile(room.id, result.name, result.statusMessage)
                if (result.didChangeImage) store.updateAvatar(room.id, result.image)
                editingRoom = null
            }
        )
    }
    selectedRemoteRoom?.let { remote ->
        RemoteChatRoomScreen(snapshot = remote, onClose = { selectedRemoteRoom = null })
    }
}

@Composable
private fun RemoteRoomRow(room: SyncRemoteRoomSnapshot, onOpen: () -> Unit) {
    val colors = KakaoTheme.colors
    Row(
        Modifier.fillMaxWidth().combinedClickable(onClick = onOpen, onLongClick = {})
            .padding(horizontal = 16.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(room.title, style = KakaoText.listName, color = colors.textPrimary, maxLines = 1)
                Text(
                    if (room.handle.originSpaceId == "TABLET_SPACE") "  태블릿" else "  Mac",
                    style = KakaoText.listPreview, color = colors.textTertiary,
                )
            }
            Text(
                cleanSnippet(room.messages.lastOrNull()?.text ?: "받은 메시지가 없습니다"),
                style = KakaoText.listPreview, color = colors.textSecondary, maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        room.messages.lastOrNull()?.timestamp?.let { timestamp ->
            runCatching { java.time.Instant.parse(timestamp).toEpochMilli() }.getOrNull()?.let {
                Text(formatRoomTime(it), style = KakaoText.listTime, color = colors.textTertiary)
            }
        }
    }
}

@Composable
private fun ChatRoomRow(
    room: ChatRoom,
    preview: String,
    avatar: android.graphics.Bitmap?,
    onOpen: () -> Unit,
    onLongPress: () -> Unit
) {
    val colors = KakaoTheme.colors

    Box {
        Row(
            Modifier
                .fillMaxWidth()
                // 맥 판은 마우스를 올리면 행이 밝아졌습니다. 모바일에는 올림이 없으므로
                // 눌림 효과로 바뀝니다. 길게 누르면 맥 판의 오른쪽 클릭 메뉴가 나옵니다.
                .combinedClickable(onClick = onOpen, onLongClick = onLongPress)
                // 실측: 행 간격 285화소에서 아바타 180화소를 빼고 반씩 나눈 값입니다.
                // 오른쪽은 시각이 놓이는 자리라 따로 잰 값(63화소)을 씁니다.
                .padding(
                    start = Metrics.screenPadding,
                    end = Metrics.listTrailingPadding,
                    top = Metrics.listRowPaddingV,
                    bottom = Metrics.listRowPaddingV
                ),
            verticalAlignment = Alignment.CenterVertically
        ) {
            RoomAvatar(avatar, Metrics.listAvatar)
            Column(
                Modifier
                    .weight(1f)
                    .padding(start = Metrics.listAvatarGap)
            ) {
                // 시각이 오른쪽 끝에 붙어야 합니다.
                //
                // 전에는 이름과 빈 상자에 **각각 `weight(1f)`을 줬습니다.** 그러면 남는
                // 폭이 반씩 나뉘는데, 이름은 `fill = false`라 제 글자 폭만 쓰고 배정받은
                // 나머지를 돌려주지 않습니다. 그 반쪽이 줄 끝에 빈자리로 남아 시각이
                // 100dp나 왼쪽으로 밀려 있었습니다(실측: 시각 잉크 끝 1062화소,
                // 화면 오른쪽까지 377화소가 비어 있었습니다).
                //
                // 이름과 배지를 안쪽 줄로 묶고 시각을 그 밖에 둡니다. 안쪽에서 남는
                // 자리는 안쪽 줄 끝에서 접히므로 시각 위치에 영향을 주지 않습니다.
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Row(
                        Modifier.weight(1f),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
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
                    }
                    Text(
                        formatRoomTime(room.lastMessageTime),
                        style = KakaoText.listTime,
                        color = colors.textTertiary,
                        maxLines = 1,
                        softWrap = false,
                        // 이름이 줄 끝까지 찼을 때 시각이 이름에 닿지 않게 합니다. (짐작)
                        modifier = Modifier.padding(start = 8.dp)
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
