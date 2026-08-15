package com.sapiens.gagaodok.ui.screens

import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AddPhotoAlternate
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.TheaterComedy
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.sapiens.gagaodok.GagaodokApp
import com.sapiens.gagaodok.model.AttachmentType
import com.sapiens.gagaodok.model.ChatAttachment
import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.components.Hairline
import com.sapiens.gagaodok.ui.components.MessageBubble
import com.sapiens.gagaodok.ui.components.RoomAvatar
import com.sapiens.gagaodok.ui.icons.MagnifierIcon
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import java.io.ByteArrayOutputStream
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.UUID

@Composable
fun ChatRoomScreen(
    roomId: UUID,
    onBack: () -> Unit,
    onEditPersona: () -> Unit
) {
    val context = LocalContext.current
    val app = context.applicationContext as GagaodokApp
    val colors = KakaoTheme.colors
    val vm: ChatRoomViewModel = viewModel()

    LaunchedEffect(roomId) { vm.bind(roomId) }

    val rooms by app.chatStore.rooms.collectAsState()
    val room = rooms.firstOrNull { it.id == roomId }
    val globalModel by app.settings.selectedModel.collectAsState()
    val messages by vm.messages.collectAsState()
    val isTyping by vm.isTyping.collectAsState()
    val error by vm.errorMessage.collectAsState()

    var inputText by remember { mutableStateOf("") }
    var pendingAttachment by remember { mutableStateOf<ChatAttachment?>(null) }
    var editingMessage by remember { mutableStateOf<ChatMessage?>(null) }
    var searchVisible by remember { mutableStateOf(false) }
    var searchText by remember { mutableStateOf("") }
    var searchIndex by remember { mutableIntStateOf(0) }
    var viewingImage by remember { mutableStateOf<ChatAttachment?>(null) }
    var actionTarget by remember { mutableStateOf<ChatMessage?>(null) }

    if (room == null) {
        // 방이 지워진 뒤에 남아 있던 화면입니다. 조용히 빠져나갑니다.
        LaunchedEffect(Unit) { onBack() }
        return
    }

    val activeModel = room.resolvedModel(globalModel)
    val activeMode = room.resolvedMode
    val avatar = app.chatStore.avatar(room.id, room.profile)

    val listState = rememberLazyListState()
    val rendered = remember(messages) { buildRows(messages) }

    // 검색 결과는 아래에서 위로 훑습니다. 최근 대화가 더 자주 찾는 대상입니다.
    val hits = remember(messages, searchText) {
        val needle = searchText.trim().lowercase()
        if (needle.isEmpty()) emptyList()
        else messages.filter { it.text.lowercase().contains(needle) }.map { it.id }.asReversed()
    }
    val currentHitId = hits.getOrNull(searchIndex)

    // 키보드가 올라오면 화면이 그만큼 줄어듭니다. 그때 맨 아래로 따라가지 않으면
    // 방금 쓰던 대화가 키보드 뒤로 밀려 올라가 버립니다.
    val imeVisible = WindowInsets.ime.getBottom(LocalDensity.current) > 0

    // 새 말풍선이 붙거나 키보드가 오르내리면 맨 아래로 따라갑니다.
    LaunchedEffect(rendered.size, isTyping, imeVisible) {
        if (rendered.isNotEmpty()) listState.animateScrollToItem(rendered.size)
    }
    LaunchedEffect(currentHitId) {
        val id = currentHitId ?: return@LaunchedEffect
        val index = rendered.indexOfFirst { it is Row.Bubble && it.message.id == id }
        if (index >= 0) listState.animateScrollToItem(index)
    }

    // 검색 중이면 뒤로가기가 먼저 검색을 닫습니다.
    BackHandler(enabled = searchVisible) {
        searchVisible = false
        searchText = ""
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri: Uri? ->
        if (uri != null) pendingAttachment = readAttachment(context, uri)
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(colors.chatBackground)
            // 키보드가 올라온 만큼 화면 전체를 밀어 올립니다. 이게 없으면 입력창이
            // 키보드 아래에 깔립니다. 안드로이드 채팅 앱에서 가장 흔한 실패 지점입니다.
            .imePadding()
    ) {
        ChatHeader(
            title = room.profile.name,
            avatar = avatar,
            personaOn = room.profile.persona.isEnabled,
            activeModel = activeModel,
            activeMode = activeMode,
            searchVisible = searchVisible,
            searchText = searchText,
            hitCount = hits.size,
            hitIndex = searchIndex,
            onBack = onBack,
            onToggleSearch = {
                searchVisible = !searchVisible
                if (!searchVisible) searchText = ""
                searchIndex = 0
            },
            onSearchTextChange = { searchText = it; searchIndex = 0 },
            onMoveSearch = { step ->
                if (hits.isNotEmpty()) {
                    searchIndex = ((searchIndex + step) % hits.size + hits.size) % hits.size
                }
            },
            onSelectModel = { app.chatStore.updateModel(room.id, it) },
            onSelectMode = { app.chatStore.updateMode(room.id, it) },
            onEditPersona = onEditPersona
        )

        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f).fillMaxWidth()
        ) {
            items(rendered.size) { index ->
                when (val row = rendered[index]) {
                    is Row.DateDivider -> DateDividerView(row.timestamp)
                    is Row.Bubble -> MessageBubble(
                        message = row.message,
                        isFirstInGroup = row.isFirstInGroup,
                        isLastInGroup = row.isLastInGroup,
                        botName = room.profile.name,
                        avatar = avatar,
                        searchQuery = if (searchVisible) searchText.trim() else "",
                        isCurrentSearchHit = row.message.id == currentHitId,
                        onImageTapped = { viewingImage = it },
                        onLongPress = { actionTarget = it },
                        onResend = { vm.resend(it, room, activeModel) }
                    )
                }
            }
            if (isTyping) {
                item("typing") {
                    TypingIndicator(botName = room.profile.name, avatar = avatar) { vm.cancelResponse() }
                }
            }
            item("bottomSpacer") { Spacer(Modifier.height(6.dp)) }
        }

        error?.let {
            Row(
                Modifier
                    .fillMaxWidth()
                    .background(Color(0x22D05050))
                    .clickable { vm.clearError() }
                    .padding(horizontal = Metrics.screenPadding, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(it, style = KakaoText.caption, color = Color(0xFFD05050), modifier = Modifier.weight(1f))
                Icon(Icons.Filled.Close, "닫기", tint = Color(0xFFD05050), modifier = Modifier.size(16.dp))
            }
        }

        ChatInputBar(
            text = inputText,
            attachment = pendingAttachment,
            editing = editingMessage != null,
            enabled = !isTyping,
            onTextChange = { inputText = it },
            onPickImage = {
                picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            },
            onClearAttachment = { pendingAttachment = null },
            onCancelEdit = { editingMessage = null; inputText = "" },
            onSend = {
                val target = editingMessage
                if (target != null) {
                    vm.editAndResend(target, inputText, room, activeModel)
                    editingMessage = null
                } else {
                    vm.send(inputText, pendingAttachment, room, activeModel)
                }
                inputText = ""
                pendingAttachment = null
            }
        )
    }

    viewingImage?.let { ImageViewerDialog(it) { viewingImage = null } }

    actionTarget?.let { target ->
        MessageActionSheet(
            message = target,
            onDismiss = { actionTarget = null },
            onEdit = {
                editingMessage = target
                inputText = target.text
                actionTarget = null
            },
            onDelete = { vm.delete(target); actionTarget = null }
        )
    }
}

// MARK: - 목록에 놓을 줄

private sealed interface Row {
    data class DateDivider(val timestamp: Long) : Row
    data class Bubble(
        val message: ChatMessage,
        val isFirstInGroup: Boolean,
        val isLastInGroup: Boolean
    ) : Row
}

/// 메시지 목록에 날짜 구분선을 끼우고, 같은 사람이 이어 말한 덩어리를 표시합니다.
///
/// 묘사는 덩어리에 넣지 않습니다. 말한 사람이 없으므로 그 앞뒤는 서로 다른 덩어리입니다.
private fun buildRows(messages: List<ChatMessage>): List<Row> {
    val rows = mutableListOf<Row>()
    var lastDay: Int? = null

    fun dayOf(millis: Long): Int {
        val c = Calendar.getInstance().apply { timeInMillis = millis }
        return c.get(Calendar.YEAR) * 1000 + c.get(Calendar.DAY_OF_YEAR)
    }

    for ((index, message) in messages.withIndex()) {
        val day = dayOf(message.timestamp)
        if (day != lastDay) {
            rows += Row.DateDivider(message.timestamp)
            lastDay = day
        }

        val previous = messages.getOrNull(index - 1)
        val next = messages.getOrNull(index + 1)
        val sameAsPrevious = previous != null &&
            previous.sender == message.sender &&
            previous.kind == message.kind &&
            dayOf(previous.timestamp) == day &&
            sameMinute(previous.timestamp, message.timestamp)
        val sameAsNext = next != null &&
            next.sender == message.sender &&
            next.kind == message.kind &&
            dayOf(next.timestamp) == day &&
            sameMinute(next.timestamp, message.timestamp)

        rows += Row.Bubble(message, isFirstInGroup = !sameAsPrevious, isLastInGroup = !sameAsNext)
    }
    return rows
}

/// 시각은 분 단위로만 보여주므로, 같은 분 안의 연속 발화만 한 덩어리로 묶습니다.
/// 그래야 마지막 말풍선에만 붙는 시각이 실제로 그 덩어리의 시각이 됩니다.
private fun sameMinute(a: Long, b: Long): Boolean = a / 60_000 == b / 60_000

// MARK: - 상단 바

@Composable
private fun ChatHeader(
    title: String,
    avatar: android.graphics.Bitmap?,
    personaOn: Boolean,
    activeModel: AIModel,
    activeMode: ChatMode,
    searchVisible: Boolean,
    searchText: String,
    hitCount: Int,
    hitIndex: Int,
    onBack: () -> Unit,
    onToggleSearch: () -> Unit,
    onSearchTextChange: (String) -> Unit,
    onMoveSearch: (Int) -> Unit,
    onSelectModel: (AIModel) -> Unit,
    onSelectMode: (ChatMode) -> Unit,
    onEditPersona: () -> Unit
) {
    val colors = KakaoTheme.colors
    val statusInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    var menuOpen by remember { mutableStateOf(false) }

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
                    Icon(Icons.Filled.Close, "검색 닫기", tint = colors.onChatHeader)
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
                IconButton(onClick = { onMoveSearch(1) }, enabled = hitCount > 0) {
                    Icon(Icons.Filled.KeyboardArrowUp, "이전 결과", tint = colors.onChatHeader)
                }
                IconButton(onClick = { onMoveSearch(-1) }, enabled = hitCount > 0) {
                    Icon(Icons.Filled.KeyboardArrowDown, "다음 결과", tint = colors.onChatHeader)
                }
            }
        } else {
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(Metrics.topBarHeight)
                    .padding(start = 4.dp, end = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "뒤로", tint = colors.onChatHeader)
                }
                RoomAvatar(avatar, 30.dp)
                Column(
                    Modifier
                        .weight(1f)
                        .padding(start = 9.dp)
                        .clickable { menuOpen = true }
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            title,
                            style = KakaoText.roomName,
                            color = colors.onChatHeader,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false)
                        )
                        if (personaOn) {
                            Icon(
                                Icons.Filled.TheaterComedy, "말투 적용됨",
                                tint = colors.personaBadge,
                                modifier = Modifier.size(12.dp).padding(start = 4.dp)
                            )
                        }
                    }
                    Text(
                        "${activeModel.shortName} · ${activeMode.shortName}",
                        style = KakaoText.timestamp,
                        color = colors.onChatHeaderDim
                    )
                }
                IconButton(onClick = onToggleSearch) {
                    MagnifierIcon(colors.onChatHeader, Modifier.size(Metrics.headerIcon))
                }

                Box {
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        Text(
                            "모드",
                            style = KakaoText.caption,
                            color = colors.textTertiary,
                            modifier = Modifier.padding(start = 14.dp, top = 8.dp, bottom = 2.dp)
                        )
                        ChatMode.entries.forEach { mode ->
                            DropdownMenuItem(
                                text = { Text(if (mode == activeMode) "✓ ${mode.displayName}" else mode.displayName) },
                                onClick = { menuOpen = false; onSelectMode(mode) }
                            )
                        }
                        Hairline()
                        Text(
                            "모델",
                            style = KakaoText.caption,
                            color = colors.textTertiary,
                            modifier = Modifier.padding(start = 14.dp, top = 8.dp, bottom = 2.dp)
                        )
                        AIModel.entries.forEach { model ->
                            DropdownMenuItem(
                                text = { Text(if (model == activeModel) "✓ ${model.displayName}" else model.displayName) },
                                onClick = { menuOpen = false; onSelectModel(model) }
                            )
                        }
                        Hairline()
                        DropdownMenuItem(
                            text = { Text("말투 편집") },
                            onClick = { menuOpen = false; onEditPersona() }
                        )
                    }
                }
            }
        }
        Hairline()
    }
}

// MARK: - 입력창

@Composable
private fun ChatInputBar(
    text: String,
    attachment: ChatAttachment?,
    editing: Boolean,
    enabled: Boolean,
    onTextChange: (String) -> Unit,
    onPickImage: () -> Unit,
    onClearAttachment: () -> Unit,
    onCancelEdit: () -> Unit,
    onSend: () -> Unit
) {
    val colors = KakaoTheme.colors
    val canSend = enabled && (text.isNotBlank() || attachment != null)

    Column(
        Modifier
            .fillMaxWidth()
            .background(colors.surface)
            .navigationBarsPadding()
    ) {
        Hairline()

        if (editing) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = Metrics.screenPadding, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("메시지 수정 중", style = KakaoText.caption, color = colors.textSecondary)
                Spacer(Modifier.weight(1f))
                Text(
                    "취소",
                    style = KakaoText.caption,
                    color = colors.textPrimary,
                    modifier = Modifier.clickable(onClick = onCancelEdit)
                )
            }
        }

        if (attachment != null) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = Metrics.screenPadding, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    "사진 1장 첨부됨",
                    style = KakaoText.caption,
                    color = colors.textSecondary,
                    modifier = Modifier.weight(1f)
                )
                Icon(
                    Icons.Filled.Close, "첨부 취소",
                    tint = colors.textSecondary,
                    modifier = Modifier.size(16.dp).clickable(onClick = onClearAttachment)
                )
            }
        }

        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 7.dp),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            IconButton(onClick = onPickImage, modifier = Modifier.size(Metrics.touchTarget)) {
                Icon(Icons.Filled.AddPhotoAlternate, "사진 첨부", tint = colors.textSecondary)
            }

            Box(
                Modifier
                    .weight(1f)
                    .background(colors.sunken, RoundedCornerShape(20.dp))
                    .padding(horizontal = 14.dp, vertical = 11.dp)
            ) {
                if (text.isEmpty()) {
                    Text("메시지 입력", style = KakaoText.bubble, color = colors.textTertiary)
                }
                BasicTextField(
                    value = text,
                    onValueChange = onTextChange,
                    // 여러 줄을 받되 너무 자라지 않게 잘라 둡니다. 그 뒤로는 안에서 스크롤됩니다.
                    maxLines = 5,
                    textStyle = LocalTextStyle.current.merge(KakaoText.bubble).copy(color = colors.textPrimary),
                    cursorBrush = SolidColor(colors.textPrimary),
                    modifier = Modifier.fillMaxWidth().heightIn(max = 120.dp)
                )
            }

            IconButton(
                onClick = onSend,
                enabled = canSend,
                modifier = Modifier
                    .size(Metrics.touchTarget)
                    .padding(3.dp)
                    .background(
                        if (canSend) colors.bubbleMine else colors.sunken,
                        CircleShape
                    )
            ) {
                Icon(
                    Icons.Filled.Send, "보내기",
                    tint = if (canSend) colors.bubbleMineText else colors.textTertiary,
                    modifier = Modifier.size(18.dp)
                )
            }
        }
    }
}

// MARK: - 날짜 구분선

@Composable
private fun DateDividerView(timestamp: Long) {
    val colors = KakaoTheme.colors
    Box(
        Modifier.fillMaxWidth().padding(vertical = 12.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            SimpleDateFormat("yyyy년 M월 d일 EEEE", Locale.KOREA).format(Date(timestamp)),
            style = KakaoText.timestamp,
            color = colors.dateDividerText,
            modifier = Modifier
                .background(colors.dateDivider, RoundedCornerShape(50))
                .padding(horizontal = 11.dp, vertical = 4.dp)
        )
    }
}

// MARK: - 답변 대기 표시

@Composable
private fun TypingIndicator(
    botName: String,
    avatar: android.graphics.Bitmap?,
    onCancel: () -> Unit
) {
    val colors = KakaoTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = Metrics.bubbleGap),
        verticalAlignment = Alignment.Bottom
    ) {
        RoomAvatar(avatar, Metrics.bubbleAvatar)
        Column(Modifier.padding(start = 7.dp)) {
            Text(botName, style = KakaoText.caption, color = colors.textSecondary)
            Row(
                Modifier
                    .padding(top = 3.dp)
                    .background(colors.bubbleTheirs, RoundedCornerShape(13.dp))
                    .clickable(onClick = onCancel)
                    .padding(horizontal = 14.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                repeat(3) {
                    Box(
                        Modifier
                            .size(6.dp)
                            .background(colors.textTertiary, CircleShape)
                    )
                }
                Text(
                    "· 눌러서 중지",
                    style = KakaoText.timestamp,
                    color = colors.textTertiary,
                    modifier = Modifier.padding(start = 4.dp)
                )
            }
        }
    }
}

// MARK: - 첨부 읽기

private fun readAttachment(context: android.content.Context, uri: Uri): ChatAttachment? = runCatching {
    val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return null
    // 원본 해상도를 그대로 올리면 요청이 커지고 토큰도 그만큼 듭니다.
    // 긴 변 1600px이면 Gemini가 읽는 데 충분하고, 타일 수도 크게 늘지 않습니다.
    val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
    val longest = maxOf(decoded.width, decoded.height)
    val scaled = if (longest > 1600) {
        val ratio = 1600f / longest
        android.graphics.Bitmap.createScaledBitmap(
            decoded, (decoded.width * ratio).toInt(), (decoded.height * ratio).toInt(), true
        )
    } else decoded

    val stream = ByteArrayOutputStream()
    scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 88, stream)
    val out = stream.toByteArray()
    ChatAttachment(
        type = AttachmentType.IMAGE,
        fileName = "사진.jpg",
        fileSize = out.size.toLong(),
        fileExtension = "jpg",
        dataBase64 = android.util.Base64.encodeToString(out, android.util.Base64.NO_WRAP),
        mimeType = "image/jpeg"
    )
}.getOrNull()
