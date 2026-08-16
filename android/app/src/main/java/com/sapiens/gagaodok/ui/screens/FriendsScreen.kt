package com.sapiens.gagaodok.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.TheaterComedy
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.GagaodokApp
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.components.Hairline
import com.sapiens.gagaodok.ui.components.RoomAvatar
import com.sapiens.gagaodok.ui.icons.AddFriendIcon
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import java.util.UUID

@Composable
fun FriendsScreen(onOpenRoom: (UUID) -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as GagaodokApp
    val store = app.chatStore
    val colors = KakaoTheme.colors

    val rooms by store.rooms.collectAsState()
    val myProfile by app.myProfile.profile.collectAsState()
    val myAvatar by app.myProfile.avatar.collectAsState()

    var searchVisible by remember { mutableStateOf(false) }
    var searchText by remember { mutableStateOf("") }
    var addingFriend by remember { mutableStateOf(false) }
    var editingRoom by remember { mutableStateOf<ChatRoom?>(null) }
    var editingMyProfile by remember { mutableStateOf(false) }
    var favoritesCollapsed by remember { mutableStateOf(false) }
    var friendsCollapsed by remember { mutableStateOf(false) }

    val query = searchText.trim()
    fun matches(room: ChatRoom) = query.isEmpty() ||
        room.profile.name.contains(query, ignoreCase = true) ||
        room.profile.statusMessage.contains(query, ignoreCase = true) ||
        store.firstMatch(room.id, query) != null

    val favorites = rooms.filter { it.isPinned }.sortedBy { it.profile.name }.filter(::matches)
    val others = rooms.filterNot { it.isPinned }.sortedBy { it.profile.name }.filter(::matches)

    Column(Modifier.fillMaxSize().background(colors.surface)) {
        ListTopBar(
            title = "친구",
            searchVisible = searchVisible,
            searchText = searchText,
            searchPlaceholder = "친구 검색",
            onToggleSearch = {
                searchVisible = !searchVisible
                if (searchVisible) store.primeSearchIndex() else searchText = ""
            },
            onSearchTextChange = { searchText = it },
            actionIcon = { AddFriendIcon(colors.textPrimary, Modifier.size(Metrics.headerIcon)) },
            onAction = { addingFriend = true }
        )

        LazyColumn(Modifier.fillMaxSize()) {
            item("me") {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { editingMyProfile = true }
                        .padding(horizontal = Metrics.screenPadding, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    RoomAvatar(myAvatar, Metrics.myProfileAvatar)
                    Column(Modifier.weight(1f).padding(start = Metrics.listAvatarGap)) {
                        Text(myProfile.name, style = KakaoText.listName, color = colors.textPrimary)
                        if (myProfile.statusMessage.isNotEmpty()) {
                            Text(
                                myProfile.statusMessage,
                                style = KakaoText.listPreview,
                                color = colors.textSecondary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.padding(top = 2.dp)
                            )
                        }
                    }
                }
                Hairline(Modifier.padding(start = Metrics.screenPadding))
            }

            if (favorites.isNotEmpty()) {
                item("favHeader") {
                    SectionHeader("즐겨찾는 친구", favorites.size, favoritesCollapsed) {
                        favoritesCollapsed = !favoritesCollapsed
                    }
                }
                if (!favoritesCollapsed) {
                    items(favorites, key = { "fav_${it.id}" }) { room ->
                        FriendRow(room, store, onOpenRoom, onEdit = { editingRoom = room })
                    }
                }
            }

            if (others.isNotEmpty()) {
                item("friendHeader") {
                    SectionHeader("친구", others.size, friendsCollapsed) {
                        friendsCollapsed = !friendsCollapsed
                    }
                }
                if (!friendsCollapsed) {
                    items(others, key = { "fr_${it.id}" }) { room ->
                        FriendRow(room, store, onOpenRoom, onEdit = { editingRoom = room })
                    }
                }
            }

            if (favorites.isEmpty() && others.isEmpty()) {
                item("empty") {
                    EmptyState(
                        title = if (query.isEmpty()) "아직 친구가 없어요" else "검색 결과가 없어요",
                        detail = if (query.isEmpty()) "오른쪽 위 버튼을 눌러 대화 상대를 만들어 보세요." else null
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

    if (editingMyProfile) {
        ProfileEditSheet(
            title = "프로필 편집",
            confirmLabel = "저장",
            initialName = myProfile.name,
            initialStatus = myProfile.statusMessage,
            initialAvatar = myAvatar,
            onDismiss = { editingMyProfile = false },
            onConfirm = { result ->
                app.myProfile.update(result.name, result.statusMessage)
                if (result.didChangeImage) app.myProfile.setAvatar(result.image)
                editingMyProfile = false
            }
        )
    }
}

@Composable
private fun SectionHeader(title: String, count: Int, collapsed: Boolean, onToggle: () -> Unit) {
    val colors = KakaoTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .padding(horizontal = Metrics.screenPadding)
            .padding(top = 16.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(title, style = KakaoText.sectionHeader, color = colors.textSecondary)
        Text(
            "$count",
            style = KakaoText.sectionHeader,
            color = colors.textTertiary,
            modifier = Modifier.padding(start = 5.dp)
        )
        Box(Modifier.weight(1f))
        Icon(
            if (collapsed) Icons.Filled.ExpandMore else Icons.Filled.ExpandLess,
            contentDescription = if (collapsed) "펼치기" else "접기",
            tint = colors.textTertiary,
            modifier = Modifier.size(18.dp)
        )
    }
}

@Composable
private fun FriendRow(
    room: ChatRoom,
    store: com.sapiens.gagaodok.data.ChatStore,
    onOpenRoom: (UUID) -> Unit,
    onEdit: () -> Unit
) {
    val colors = KakaoTheme.colors
    var menuOpen by remember { mutableStateOf(false) }

    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .combinedClickable(
                    onClick = { onOpenRoom(room.id) },
                    onLongClick = { menuOpen = true }
                )
                // 실측: 아바타 150화소, 행 간격 211화소.
                .padding(horizontal = Metrics.screenPadding, vertical = Metrics.friendRowPaddingV),
            verticalAlignment = Alignment.CenterVertically
        ) {
            RoomAvatar(store.avatar(room.id, room.profile), Metrics.friendAvatar)
            Column(Modifier.weight(1f).padding(start = Metrics.listAvatarGap)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        room.profile.name,
                        style = KakaoText.listName,
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    if (room.profile.persona.isEnabled) {
                        Icon(
                            Icons.Filled.TheaterComedy,
                            contentDescription = "말투 적용됨",
                            tint = colors.personaBadge,
                            modifier = Modifier.size(12.dp).padding(start = 4.dp)
                        )
                    }
                }
                if (room.profile.statusMessage.isNotEmpty()) {
                    Text(
                        room.profile.statusMessage,
                        style = KakaoText.listPreview,
                        color = colors.textTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = 2.dp)
                    )
                }
            }
        }

        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(text = { Text("대화 시작") }, onClick = { menuOpen = false; onOpenRoom(room.id) })
            DropdownMenuItem(text = { Text("프로필 편집") }, onClick = { menuOpen = false; onEdit() })
            DropdownMenuItem(
                text = { Text(if (room.isPinned) "즐겨찾기 해제" else "즐겨찾기") },
                onClick = { menuOpen = false; store.togglePinned(room.id) }
            )
            DropdownMenuItem(text = { Text("삭제") }, onClick = { menuOpen = false; store.deleteRoom(room.id) })
        }
    }
}
