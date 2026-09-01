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
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.sapiens.gagaodok.sync.SyncRemoteRoomSnapshot
import com.sapiens.gagaodok.sync.SyncRemoteContinuationCapability
import com.sapiens.gagaodok.sync.SyncRemoteReplyCoordinator
import com.sapiens.gagaodok.sync.SyncRemoteReplyJournal
import com.sapiens.gagaodok.sync.SyncConnectionLoadResult
import com.sapiens.gagaodok.sync.SyncConnectionStateStore
import com.sapiens.gagaodok.sync.SyncOutbox
import com.sapiens.gagaodok.sync.SyncSecretLoadResult
import com.sapiens.gagaodok.sync.SyncSecretStore
import com.sapiens.gagaodok.BuildConfig
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.service.AIService
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun RemoteChatRoomScreen(snapshot: SyncRemoteRoomSnapshot, onClose: () -> Unit) {
    val context = LocalContext.current
    val preferences = remember { context.getSharedPreferences("sync_remote_ui", 0) }
    val scope = rememberCoroutineScope()
    var showNotice by remember { mutableStateOf(!preferences.getBoolean("behavior_notice_seen", false)) }
    var replyText by remember { mutableStateOf("") }
    var preparingReply by remember { mutableStateOf(false) }
    var replyStatus by remember { mutableStateOf<String?>(null) }
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
                            if (snapshot.continuationCapability == SyncRemoteContinuationCapability.CHATBOT)
                                "다른 기기에서 시작한 개인 챗봇 방입니다. 답장은 이 기기의 Gemini 설정으로 준비됩니다."
                            else "이 방은 이어쓰기 capability가 없어 읽기 전용입니다.",
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
                if (snapshot.continuationCapability == SyncRemoteContinuationCapability.CHATBOT) {
                    OutlinedTextField(
                        value = replyText,
                        onValueChange = { replyText = it },
                        label = { Text("답장") },
                        enabled = !preparingReply,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                    )
                    Button(
                        onClick = {
                            val text = replyText.trim()
                            if (text.isEmpty()) return@Button
                            preparingReply = true
                            scope.launch {
                                val prepared = prepareRemoteReply(context, snapshot, text)
                                preparingReply = false
                                if (prepared) {
                                    replyText = ""
                                    replyStatus = "답장을 이 기기의 동기화 대기열에 보관했습니다."
                                } else {
                                    replyStatus = "답장을 준비하지 못했습니다. 기존 원격 대화는 변경되지 않았습니다."
                                }
                            }
                        },
                        enabled = !preparingReply && replyText.trim().isNotEmpty(),
                        modifier = Modifier.fillMaxWidth().padding(12.dp),
                    ) { Text(if (preparingReply) "준비 중" else "보내기") }
                    replyStatus?.let { Text(it, style = KakaoText.listPreview, color = colors.textSecondary, modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) }
                } else {
                    Text(
                        "원격 방 답장은 지원되는 개인 챗봇 방에서만 가능합니다.",
                        style = KakaoText.listPreview, color = colors.textSecondary,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
        }
    }
}

/** Generates only with Gemini, journals exact encrypted operations, then queues delivery. */
private suspend fun prepareRemoteReply(
    context: android.content.Context,
    snapshot: SyncRemoteRoomSnapshot,
    userText: String,
): Boolean = withContext(Dispatchers.IO) {
    runCatching {
        val root = File(context.filesDir, "sync")
        val secrets = (SyncSecretStore(context).load() as? SyncSecretLoadResult.Available)?.secrets
            ?: return@runCatching false
        val connection = (SyncConnectionStateStore(File(root, "connection.json")).load() as? SyncConnectionLoadResult.Available)?.configuration
            ?: return@runCatching false
        val turns = snapshot.messages.map { message ->
            ConversationTurn(
                UUID.fromString(message.turnId),
                if (message.sender == "나") MessageSender.USER else MessageSender.SAPIENS,
                message.text,
            )
        } + ConversationTurn(UUID.randomUUID(), MessageSender.USER, userText)
        val response = AIService.get(context).streamResponse(
            conversation = turns,
            botName = snapshot.title,
            roomId = UUID.fromString(snapshot.handle.roomId),
            model = AIModel.GEMINI_37_FLASH,
            persona = null,
            mode = ChatMode.COMPANION,
            roleplayInProgress = false,
            onBubble = {},
        )
        val writerSpace = if (BuildConfig.TABLET_MENTOR) "TABLET_SPACE" else "PHONE_SPACE"
        SyncRemoteReplyCoordinator(
            connection.accountId, connection.deviceId, secrets.accountMasterKey,
            SyncRemoteReplyJournal(File(root, "remote-replies.bin")),
        ).prepare(snapshot, writerSpace, userText, response, AIModel.GEMINI_37_FLASH, SyncOutbox(File(root, "outbox.bin")))
        true
    }.getOrDefault(false)
}
