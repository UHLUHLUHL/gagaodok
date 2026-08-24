package com.sapiens.gagaodok.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.ui.components.RoomAvatar
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme

@Composable
internal fun GroupChatCreationSheet(
    rooms: List<ChatRoom>,
    avatarFor: (ChatRoom) -> android.graphics.Bitmap?,
    onDismiss: () -> Unit,
    onCreate: (title: String, participants: List<ChatRoom>) -> Unit
) {
    val personalRooms = remember(rooms) { rooms.filter { it.groupChat == null } }
    var state by remember { mutableStateOf(GroupChatUiState()) }
    val selectedRooms = state.selectedParticipantIds.mapNotNull { id -> personalRooms.firstOrNull { it.id == id } }
    val colors = KakaoTheme.colors

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Column(Modifier.fillMaxSize().background(colors.chatBackground)) {
            Row(
                Modifier.fillMaxWidth().height(64.dp).background(colors.chatHeader).padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(onClick = onDismiss) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "뒤로", tint = colors.onChatHeader)
                }
                Text("새 단톡방", style = KakaoText.roomTitle, color = colors.onChatHeader, modifier = Modifier.weight(1f))
                Text(
                    "${state.selectedParticipantIds.size}명",
                    style = KakaoText.senderName,
                    color = WorldlineTokens.accent,
                    modifier = Modifier.padding(end = 16.dp)
                )
            }

            Column(Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 20.dp)) {
                Text("함께할 캐릭터를 골라주세요", style = KakaoText.screenTitle, color = colors.textPrimary)
                Text(
                    "개인방에 있는 캐릭터만 초대할 수 있어요. 각 방의 호감도와 대화는 서로 섞이지 않아요.",
                    style = KakaoText.body,
                    color = colors.textSecondary,
                    modifier = Modifier.padding(top = 8.dp)
                )
                Row(
                    Modifier.padding(top = 16.dp).clip(CircleShape).background(WorldlineTokens.soft)
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(Modifier.size(7.dp).background(WorldlineTokens.accent, CircleShape))
                    Text(
                        "${state.selectedParticipantIds.size}명 선택됨",
                        style = KakaoText.caption,
                        color = WorldlineTokens.accent,
                        modifier = Modifier.padding(start = 6.dp)
                    )
                }

                LazyColumn(
                    Modifier.weight(1f).fillMaxWidth().padding(top = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    items(personalRooms, key = { it.id }) { room ->
                        CharacterSelectionRow(
                            room = room,
                            avatar = avatarFor(room),
                            selected = room.id in state.selectedParticipantIds,
                            onClick = { state = state.toggleParticipant(room.id) }
                        )
                    }
                }

                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(colors.sunken)
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(Icons.Filled.DarkMode, null, tint = WorldlineTokens.accent, modifier = Modifier.size(18.dp))
                    Text(
                        "방을 만든 뒤 첫 메시지를 보내기 전까지 조용히 기다려.",
                        style = KakaoText.caption,
                        color = colors.textSecondary,
                        modifier = Modifier.padding(start = 8.dp)
                    )
                }

                val buttonColor = if (state.canCreate) WorldlineTokens.accent else colors.sunken
                Box(
                    Modifier.fillMaxWidth().padding(top = 16.dp).height(52.dp)
                        .clip(RoundedCornerShape(16.dp)).background(buttonColor)
                        .clickable(enabled = state.canCreate) {
                            onCreate(defaultGroupTitle(state.selectedParticipantIds, personalRooms), selectedRooms)
                        },
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        "단톡방 만들기",
                        style = KakaoText.senderName,
                        color = if (state.canCreate) Color(0xFF1A1A1A) else colors.textTertiary
                    )
                }
            }
        }
    }
}

@Composable
private fun CharacterSelectionRow(
    room: ChatRoom,
    avatar: android.graphics.Bitmap?,
    selected: Boolean,
    onClick: () -> Unit
) {
    val colors = KakaoTheme.colors
    val border = if (selected) WorldlineTokens.accent else colors.border
    val background = if (selected) WorldlineTokens.soft else colors.surface

    Row(
        Modifier.fillMaxWidth().height(72.dp).clip(RoundedCornerShape(16.dp))
            .background(background).border(1.dp, border, RoundedCornerShape(16.dp))
            .clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        RoomAvatar(avatar, 44.dp)
        Column(Modifier.weight(1f).padding(start = 12.dp)) {
            Text(room.profile.name, style = KakaoText.senderName, color = colors.textPrimary, maxLines = 1)
            Text(
                room.profile.statusMessage,
                style = KakaoText.caption,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        Box(
            Modifier.size(24.dp).clip(CircleShape)
                .background(if (selected) WorldlineTokens.accent else colors.sunken)
                .border(1.dp, border, CircleShape),
            contentAlignment = Alignment.Center
        ) {
            if (selected) Icon(Icons.Filled.Check, "선택됨", tint = Color.White, modifier = Modifier.size(15.dp))
        }
    }
}
