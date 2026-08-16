package com.sapiens.gagaodok.ui.screens

import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.offset
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
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Edit
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
import androidx.compose.material3.ripple
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
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
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
import com.sapiens.gagaodok.ui.components.kakaoBubbleBackground
import com.sapiens.gagaodok.ui.icons.MagnifierIcon
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import java.io.ByteArrayOutputStream
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.UUID
import kotlin.math.roundToInt
import kotlin.math.sin

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
    // 수정 중인 글은 입력창과 **따로 둡니다.** 한 칸을 같이 쓰면 수정을 시작할 때
    // 쓰던 글이 지워지고, 취소해도 돌아오지 않습니다.
    // `TextFieldValue`인 이유는 커서 자리까지 정해야 하기 때문입니다. 원조는 수정을
    // 열면 커서가 글 맨 끝에 있고, 접힌 한 줄짜리 필드에 그 마지막 줄이 보입니다.
    var editValue by remember { mutableStateOf(TextFieldValue("")) }
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

    // 수정 중에는 뒤로가기가 먼저 수정을 물립니다. 방을 나가 버리면 고치던 글이
    // 통째로 없어져, 되돌릴 방법이 없습니다.
    //
    // 길게 누르기 메뉴보다 **먼저** 걸어 둡니다. Compose는 나중에 건 것이 먼저
    // 받으므로, 수정 중에 메뉴를 열었을 때 뒤로가기가 메뉴부터 닫습니다.
    BackHandler(enabled = editingMessage != null) { editingMessage = null }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri: Uri? ->
        if (uri != null) pendingAttachment = readAttachment(context, uri)
    }

    // 길게 누르기 메뉴가 화면 **전체**를 덮어야 해서 상자로 감쌌습니다.
    // 키보드 여백(`imePadding`)은 안쪽 세로줄에만 둡니다. 상자에 걸면 키보드가
    // 올라올 때 덮개까지 줄어들어 키보드 자리만 안 어두워집니다.
    Box(Modifier.fillMaxSize()) {
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

            // 입력바와 수정 바를 갈아 끼웁니다.
            //
            // 둘은 높이가 크게 다릅니다(입력바 48dp, 수정 바 92dp 이상). `SizeTransform`이
            // 없으면 바뀌는 순간 위의 대화 목록이 그 차이만큼 툭 튀어 오릅니다.
            AnimatedContent(
                targetState = editingMessage,
                contentKey = { it != null },
                transitionSpec = {
                    // 새 바는 옛 바가 흐려진 뒤에 나타납니다. 같이 겹치면 두 겹의
                    // 흰 판이 반투명으로 포개져 한순간 회색으로 보입니다.
                    (fadeIn(tween(160, delayMillis = 90)) togetherWith fadeOut(tween(110)))
                        .using(SizeTransform(clip = false) { _, _ -> tween(260, easing = FastOutSlowInEasing) })
                },
                label = "입력바"
            ) { target ->
                if (target == null) {
                    ChatInputBar(
                        text = inputText,
                        attachment = pendingAttachment,
                        enabled = !isTyping,
                        onTextChange = { inputText = it },
                        onPickImage = {
                            picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                        },
                        onClearAttachment = { pendingAttachment = null },
                        onSend = {
                            vm.send(inputText, pendingAttachment, room, activeModel)
                            inputText = ""
                            pendingAttachment = null
                        }
                    )
                } else {
                    EditBar(
                        value = editValue,
                        original = target.text,
                        onValueChange = { editValue = it },
                        onCancel = { editingMessage = null },
                        onConfirm = {
                            vm.editAndResend(target, editValue.text, room, activeModel)
                            editingMessage = null
                        }
                    )
                }
            }
        }

        actionTarget?.let { target ->
            MessageActionSheet(
                message = target,
                onDismiss = { actionTarget = null },
                onEdit = {
                    editingMessage = target
                    // 커서를 글 맨 끝에 둡니다. 0에 두면 접힌 필드에 **첫 줄**이 보이는데,
                    // 원조는 마지막 줄이 보입니다.
                    editValue = TextFieldValue(target.text, TextRange(target.text.length))
                    actionTarget = null
                },
                onDelete = { vm.delete(target); actionTarget = null }
            )
        }
    } // 화면 전체를 덮는 상자 끝

    viewingImage?.let { ImageViewerDialog(it) { viewingImage = null } }
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
                        .clickable { menuOpen = true },
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
        // 원조 대화방에는 상단 바 아래 구분선이 없습니다. 바탕이 대화 배경과 같은 색으로
        // 그대로 이어집니다. 다크 모드는 바탕 색이 이미 달라 선 없이도 갈립니다.
    }
}

// MARK: - 입력창

@Composable
private fun ChatInputBar(
    text: String,
    attachment: ChatAttachment?,
    enabled: Boolean,
    onTextChange: (String) -> Unit,
    onPickImage: () -> Unit,
    onClearAttachment: () -> Unit,
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

        // 원조 입력바를 재서 맞췄습니다. 전체 48dp, 알약 필드 36dp, 둥근 단추 지름 28dp.
        //
        // 원조에는 `+`, 필드, `#`, 음성 이렇게 네 자리가 있습니다. 우리 앱에는 `#`과
        // 음성에 해당하는 기능이 없어서 **모양과 치수만 맞추고 단추 수는 우리 기능에
        // 맞췄습니다.** 눌러도 아무 일이 없는 단추를 모양 때문에 그려 넣지 않습니다.
        // 좌우 여백과 사이 간격을 **0으로 둡니다.** 단추의 48dp 터치 상자가 28dp 원보다
        // 사방 10dp씩 크기 때문에, 그 상자만으로 원조의 여백(왼쪽 36화소, 사이 33화소)이
        // 거의 그대로 나옵니다. 여기에 여백을 또 주면 원이 40화소 더 안쪽으로 밀립니다.
        // 오른쪽만 원조가 왼쪽보다 23화소 넓어서 그만큼 따로 줍니다.
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = Metrics.inputBarHeight)
                .padding(end = Metrics.inputBarEndPadding, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.Bottom
        ) {
            RoundInputButton(onClick = onPickImage, contentDescription = "사진 첨부") {
                Icon(
                    Icons.Filled.AddPhotoAlternate, "사진 첨부",
                    tint = colors.textPrimary,
                    modifier = Modifier.size(Metrics.inputButtonGlyph)
                )
            }

            // 필드를 단추와 같은 높이(48dp)의 상자에 넣고 가운데에 둡니다.
            // 넣지 않으면 아래끼리만 맞아서 원의 중심이 필드 중심보다 22화소 올라갑니다.
            // 원조는 둘의 중심이 같습니다. 글이 길어지면 이 상자가 같이 자랍니다.
            Box(
                Modifier.weight(1f).heightIn(min = Metrics.touchTarget),
                contentAlignment = Alignment.Center
            ) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = Metrics.inputFieldHeight)
                        // 모서리를 높이의 절반으로 두어 완전한 알약이 되게 합니다.
                        // 실측한 원조 필드도 알약이었습니다.
                        .background(colors.sunken, RoundedCornerShape(percent = 50))
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                    contentAlignment = Alignment.CenterStart
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
            }

            RoundInputButton(
                onClick = onSend,
                enabled = canSend,
                background = if (canSend) colors.bubbleMine else colors.sunken,
                contentDescription = "보내기"
            ) {
                Icon(
                    Icons.Filled.Send, "보내기",
                    tint = if (canSend) colors.bubbleMineText else colors.textTertiary,
                    // 꽉 찬 삼각형이라 같은 숫자면 더 커 보입니다. 한 단 줄여 눈으로 맞춥니다.
                    modifier = Modifier.size(Metrics.inputButtonGlyph - 2.dp)
                )
            }
        }
    }
}

/// 입력바 양옆의 둥근 단추입니다.
///
/// 보이는 원은 28dp지만 누를 수 있는 넓이는 48dp로 둡니다. 원조도 원보다 넓은 자리를
/// 받아 두었고, 28dp짜리 과녁은 손가락으로 맞히기에 작습니다.
///
/// **`IconButton`을 쓰지 않습니다.** Material3의 `IconButton`은 넘겨받은 수정자 뒤에
/// 자기 크기(40dp)와 최소 터치 넓이(48dp)를 덧붙입니다. 그래서 `.size(28.dp)`를 주어도
/// 원이 48dp로 그려졌습니다. 필드(36dp)보다 큰 원이 되어, 원조에서 필드보다 작던
/// 단추가 오히려 커 보였습니다. 크기를 내가 정해야 하는 자리에는 맞지 않는 부품입니다.
@Composable
private fun RoundInputButton(
    onClick: () -> Unit,
    enabled: Boolean = true,
    background: Color = KakaoTheme.colors.sunken,
    contentDescription: String,
    content: @Composable () -> Unit
) {
    Box(
        Modifier
            .size(Metrics.touchTarget)
            .clickable(
                enabled = enabled,
                onClickLabel = contentDescription,
                // 물결이 원 밖으로 번지지 않게 원 크기에 맞춥니다.
                indication = ripple(bounded = false, radius = Metrics.inputButton / 2),
                interactionSource = remember { MutableInteractionSource() },
                onClick = onClick
            ),
        contentAlignment = Alignment.Center
    ) {
        Box(
            Modifier.size(Metrics.inputButton).background(background, CircleShape),
            contentAlignment = Alignment.Center
        ) { content() }
    }
}

// MARK: - 메시지 수정 바

/// 보낸 말풍선을 고칠 때 입력바 자리에 들어서는 판입니다.
///
/// 원조 캡처 세 장(키보드 위 — 고치기 전·후, 키보드 아래)을 재서 맞췄습니다.
/// 세 장의 **배너 치수가 화소까지 같아서** 배너는 상태와 무관한 고정 부품입니다.
/// 상태에 따라 달라지는 것은 두 가지뿐입니다.
///
/// **하나. 고치기 전에는 확인 단추가 아예 없습니다.**
/// 흐리게 두는 것도, 회색으로 두는 것도 아닙니다. 없습니다. 그래서 필드가 오른쪽
/// 끝(실측 x=1401)까지 찹니다. 뭔가 바뀌는 순간 단추가 생기고 필드가 x=1259로
/// 줄어듭니다. 사용자가 "유아이가 바뀐다"고 한 것이 이것입니다.
///
/// **둘. 키보드를 내리면 필드가 한 줄로 접힙니다.**
/// 다섯 줄짜리 글이 그대로 든 채 필드 높이만 436화소에서 135화소가 됩니다.
///
/// 접힘의 크기와 움직임은 맞췄지만 **접힌 자리에 보이는 줄은 원조와 다릅니다.**
/// 원조는 마지막 줄을, 우리는 첫 줄을 보여 줍니다. 키보드가 내려가면서 초점이
/// 풀리면 `BasicTextField`의 스크롤이 맨 위로 돌아가는데, 이 부품은 스크롤 위치를
/// 밖에서 잡을 수 있는 손잡이를 내주지 않습니다. 커서를 끝으로 다시 찍는 편법은
/// 이미 끝에 있을 때 아무 일도 일어나지 않아 소용이 없었고, 바닥 정렬로 잘라
/// 붙이는 방법은 펴는 순간 보이는 줄이 튑니다. 지금은 그대로 둡니다.
@Composable
private fun EditBar(
    value: TextFieldValue,
    original: String,
    onValueChange: (TextFieldValue) -> Unit,
    onCancel: () -> Unit,
    onConfirm: () -> Unit
) {
    val colors = KakaoTheme.colors
    val density = LocalDensity.current
    val focusRequester = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current

    // 원조는 수정을 고르면 키보드가 이미 올라와 있습니다. 한 번 더 눌러 커서를
    // 넣게 하면 방금 고른 '수정'이 두 번에 나뉩니다.
    LaunchedEffect(Unit) {
        focusRequester.requestFocus()
        keyboard?.show()
    }

    val changed = value.text != original && value.text.isNotBlank()
    val imeVisible = WindowInsets.ime.getBottom(density) > 0

    val lineHeight = with(density) { KakaoText.bubble.lineHeight.toDp() }
    // 접힘·폄을 높이 상한으로 다룹니다. 상한이 부드럽게 줄면 필드도 부드럽게 접힙니다.
    // 줄 수를 직접 바꾸면 글이 다시 접히면서 한 프레임 만에 튑니다.
    val fieldMaxHeight by animateDpAsState(
        targetValue = if (imeVisible) lineHeight * Metrics.editFieldMaxLines else lineHeight,
        animationSpec = tween(240, easing = FastOutSlowInEasing),
        label = "필드높이"
    )
    // 단추가 없을 때는 오른쪽 여백이 왼쪽과 같아집니다(실측 38화소).
    // 단추가 서면 그 자리가 26화소로 좁아집니다.
    val endPadding by animateDpAsState(
        targetValue = if (changed) Metrics.editEndPaddingActive else Metrics.editEndPaddingIdle,
        animationSpec = tween(220, easing = FastOutSlowInEasing),
        label = "오른쪽여백"
    )

    Column(
        Modifier
            .fillMaxWidth()
            .background(colors.surface)
            .navigationBarsPadding()
    ) {
        Hairline()

        Row(
            Modifier
                .fillMaxWidth()
                .padding(start = Metrics.editSidePadding, top = Metrics.editTopPadding),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // 테두리 색을 새로 만들지 않았습니다. 실측한 #DBDBDB는 흰 바탕 위의
            // `border`(검정 14%)와 같은 값입니다.
            Box(
                Modifier
                    .size(Metrics.editIconCircle)
                    .border(1.dp, colors.border, CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.Outlined.Edit, contentDescription = null,
                    tint = colors.textPrimary,
                    modifier = Modifier.size(Metrics.editIconGlyph)
                )
            }
            Column(
                Modifier
                    .weight(1f)
                    .padding(start = Metrics.editIconGap)
            ) {
                // 제목과 미리보기를 **한 `Text` 안의 두 줄**로 씁니다.
                //
                // `Text` 두 개를 세로로 쌓으면 줄 간격을 잡을 수 없습니다. 한 줄짜리
                // 글은 Compose가 위아래 여유를 잘라 내서, 적어 둔 줄 높이(17sp)가
                // 통째로 없어지고 글꼴 본래 높이(70화소)만 남았습니다. `Trim.None`을
                // 줘도 마찬가지였습니다. 한 `Text` 안의 **줄 사이** 간격은 무엇을
                // 잘라 내든 남으므로, 여기서는 적은 값이 그대로 나옵니다(63.75화소).
                Text(
                    buildAnnotatedString {
                        withStyle(SpanStyle(fontWeight = FontWeight.Bold)) {
                            append("메시지 수정")
                        }
                        append("\n")
                        // 줄바꿈을 띄어쓰기로 폅니다. 원조 미리보기도 여러 줄짜리
                        // 원문이 한 줄로 이어져 있었습니다.
                        append(original.replace('\n', ' '))
                    },
                    style = KakaoText.editBanner,
                    color = colors.textPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Box(
                Modifier
                    .padding(end = Metrics.editCloseEndPadding)
                    .size(Metrics.editCloseBox)
                    .clickable(
                        onClickLabel = "수정 취소",
                        indication = ripple(bounded = false, radius = Metrics.editCloseBox / 2),
                        interactionSource = remember { MutableInteractionSource() },
                        onClick = onCancel
                    ),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.Filled.Close, "수정 취소",
                    tint = colors.textPrimary,
                    modifier = Modifier.size(Metrics.editCloseGlyph)
                )
            }
        }

        Spacer(Modifier.height(Metrics.editBannerGap))

        Row(
            Modifier
                .fillMaxWidth()
                .padding(
                    start = Metrics.editSidePadding,
                    end = endPadding,
                    bottom = Metrics.editBottomPadding
                ),
            verticalAlignment = Alignment.Bottom
        ) {
            Box(
                Modifier
                    .weight(1f)
                    .background(colors.sunken, RoundedCornerShape(Metrics.editFieldCorner))
                    .padding(
                        horizontal = Metrics.editFieldPaddingH,
                        vertical = Metrics.editFieldPaddingV
                    ),
                contentAlignment = Alignment.CenterStart
            ) {
                BasicTextField(
                    value = value,
                    onValueChange = onValueChange,
                    textStyle = LocalTextStyle.current.merge(KakaoText.bubble)
                        .copy(color = colors.textPrimary),
                    cursorBrush = SolidColor(colors.textPrimary),
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = lineHeight, max = fieldMaxHeight)
                        .focusRequester(focusRequester)
                )
            }

            AnimatedVisibility(
                visible = changed,
                // 폭이 자라며 자리를 만들고 그 안에서 원이 커집니다. 원만 나타나게 하면
                // 필드가 먼저 줄어든 뒤 빈자리에 원이 뒤늦게 떨어지는 것으로 보입니다.
                enter = expandHorizontally(
                    tween(220, easing = FastOutSlowInEasing),
                    expandFrom = Alignment.End
                ) + fadeIn(tween(150, delayMillis = 70)) +
                    scaleIn(tween(220, easing = FastOutSlowInEasing), initialScale = 0.55f),
                exit = shrinkHorizontally(
                    tween(200, easing = FastOutSlowInEasing),
                    shrinkTowards = Alignment.End
                ) + fadeOut(tween(110)) +
                    scaleOut(tween(200, easing = FastOutSlowInEasing), targetScale = 0.55f)
            ) {
                Box(
                    Modifier
                        .padding(start = Metrics.editConfirmGap)
                        // 실측: 단추 아래 끝이 필드 아래 끝보다 3화소 위입니다.
                        .padding(bottom = 1.dp)
                        .size(Metrics.editConfirm)
                        .background(colors.editConfirm, CircleShape)
                        .clickable(onClickLabel = "수정 완료", onClick = onConfirm),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        Icons.Filled.Check, "수정 완료",
                        // 실측: 노란 원 위의 체크는 흰색입니다. 말풍선 글자색(#191919)이
                        // 아닙니다.
                        tint = Color.White,
                        modifier = Modifier.size(Metrics.editConfirmGlyph)
                    )
                }
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
    // 말풍선과 같은 정렬 규칙을 씁니다. 위쪽 정렬이라야 아바타 위 끝이 이름 줄과 맞습니다.
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.roomPadding, vertical = Metrics.bubbleGap),
        verticalAlignment = Alignment.Top
    ) {
        RoomAvatar(avatar, Metrics.bubbleAvatar)
        Column(Modifier.padding(start = Metrics.bubbleAvatarGap)) {
            Text(botName, style = KakaoText.senderName, color = colors.textPrimary)
            // 안쪽 여백과 글줄 높이를 말풍선과 똑같이 씁니다.
            // 다른 숫자를 쓰면 답변이 도착하는 순간 말풍선 높이가 튑니다.
            Row(
                Modifier
                    .padding(top = Metrics.bubbleNameGap)
                    .kakaoBubbleBackground(
                        color = colors.bubbleTheirs,
                        isFirst = true,
                        isMine = false
                    )
                    .clickable(onClick = onCancel)
                    .padding(
                        horizontal = Metrics.bubblePaddingH,
                        vertical = Metrics.bubblePaddingV
                    ),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp)
            ) {
                TypingDots(colors.textSecondary)
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

/// 점 하나가 지금 얼마나 떠 있는지를 0(바닥)에서 1(꼭대기)로 돌려줍니다.
///
/// `phase`는 0에서 3까지 돌고 세 점이 차례로 뜹니다. 점마다 자기 차례의 `riseSpan`만큼만
/// 떴다 가라앉고 나머지 시간은 바닥에 있습니다.
///
/// 화면 없이 확인할 수 있게 밖으로 빼 두었습니다. 값이 늘 0이 되어 버리는 실수는
/// 화면을 봐도 "원래 안 움직이는 건가" 싶어 놓치기 쉽습니다.
internal fun typingDotLift(phase: Float, index: Int, riseSpan: Float = 0.55f): Float {
    val local = ((phase - index + 3f) % 3f) / riseSpan
    return if (local > 1f) 0f else sin(local * Math.PI.toFloat())
}

/// 점 세 개가 차례로 떴다 가라앉습니다.
///
/// 하나짜리 무한 애니메이션에서 세 점의 위상만 어긋나게 씁니다. 점마다 따로 돌리면
/// 프레임이 어긋나 걸음이 흐트러지고, 다시 그릴 때마다 시작점이 달라집니다.
@Composable
private fun TypingDots(color: Color) {
    val transition = rememberInfiniteTransition(label = "입력 중")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 3f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1050, easing = LinearEasing)
        ),
        label = "위상"
    )
    val density = LocalDensity.current
    // 높이를 말풍선 한 줄과 같게 잡습니다. 점만 놓으면 말풍선이 낮아져서
    // 답변이 도착하는 순간 높이가 튑니다.
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier.height(with(density) { KakaoText.bubble.lineHeight.toDp() })
    ) {
        repeat(3) { i ->
            val lift = typingDotLift(phase, i)
            Box(
                Modifier
                    // 여백이 아니라 `offset`으로 띄웁니다. 여백은 자리를 차지해서
                    // 점이 뜰 때마다 옆 글자가 밀리고, 가운데 정렬도 흐트러집니다.
                    .offset { IntOffset(0, -(5.dp.toPx() * lift).roundToInt()) }
                    .size(6.dp)
                    .background(color.copy(alpha = 0.45f + 0.55f * lift), CircleShape)
            )
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
