package com.sapiens.gagaodok.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.sapiens.gagaodok.sync.SyncRemoteRoomSnapshot
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme

@Composable
fun RemoteChatRoomScreen(snapshot: SyncRemoteRoomSnapshot, onClose: () -> Unit) {
    val context = LocalContext.current
    val preferences = remember { context.getSharedPreferences("sync_remote_ui", 0) }
    var showNotice by remember { mutableStateOf(!preferences.getBoolean("behavior_notice_seen", false)) }
    LaunchedEffect(showNotice) {
        if (showNotice) preferences.edit().putBoolean("behavior_notice_seen", true).apply()
    }
    val colors = KakaoTheme.colors
    Dialog(onDismissRequest = onClose) {
        Card(Modifier.fillMaxWidth().heightIn(max = 620.dp)) {
            Column {
                Row(Modifier.fillMaxWidth().padding(16.dp)) {
                    Column {
                        Text(snapshot.title, style = KakaoText.listName, color = colors.textPrimary)
                        Text(
                            "${if (snapshot.handle.originSpaceId == "TABLET_SPACE") "태블릿" else "Mac"}에서 시작 · 수동 확인 필요",
                            style = KakaoText.listPreview, color = colors.textSecondary,
                        )
                    }
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = onClose) { Text("닫기") }
                }
                if (showNotice) {
                    Row(Modifier.fillMaxWidth().background(colors.sunken).padding(12.dp)) {
                        Text(
                            "다른 기기에서 시작한 방입니다. 답장을 열면 이 기기의 설정으로 응답합니다. 현재는 읽기만 가능합니다.",
                            style = KakaoText.listPreview, color = colors.textSecondary,
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = { showNotice = false }) { Text("확인") }
                    }
                }
                LazyColumn(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                    items(snapshot.messages, key = { it.messageId }) { message ->
                        Column(Modifier.fillMaxWidth().padding(vertical = 7.dp)) {
                            Text(message.sender, style = KakaoText.listPreview, color = colors.textSecondary)
                            Text(message.text, style = KakaoText.listName, color = colors.textPrimary)
                        }
                    }
                }
                Button(onClick = {}, enabled = false, modifier = Modifier.fillMaxWidth().padding(12.dp)) {
                    Text("원격 방 답장은 다음 단계에서 활성화됩니다")
                }
            }
        }
    }
}
