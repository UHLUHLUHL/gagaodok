package com.sapiens.gagaodok.ui.screens

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.content.ReceiveContentListener
import androidx.compose.foundation.content.TransferableContent
import androidx.compose.foundation.content.contentReceiver
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.zIndex
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.core.content.FileProvider
import com.sapiens.gagaodok.GagaodokApp
import com.sapiens.gagaodok.BuildConfig
import com.sapiens.gagaodok.model.ChatAttachment
import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.MessageHeartChange
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.InkDocument
import com.sapiens.gagaodok.service.InkAttachmentFactory
import com.sapiens.gagaodok.service.extractOpeningPhrase
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.components.LocalKakaoMenu
import com.sapiens.gagaodok.ui.components.KakaoMenuItem
import com.sapiens.gagaodok.ui.components.KakaoMenuSection
import com.sapiens.gagaodok.ui.components.MessageBubble
import com.sapiens.gagaodok.ui.components.LiquidGlassDefaults
import com.sapiens.gagaodok.ui.components.LiquidGlassRegion
import com.sapiens.gagaodok.ui.components.LiquidGlassBackdrop
import androidx.compose.ui.graphics.lerp
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.service.ConversationCompactor
import com.sapiens.gagaodok.service.ConversationDigestStatus
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import java.text.SimpleDateFormat
import java.io.File
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/// 유리 자체의 색입니다. **불투명 카드가 쓰던 색에서 출발합니다.**
///
/// 셰이더는 흐린 배경을 이 색 쪽으로 모읍니다. 그래서 이 값이 곧 글자가 놓일 바닥이 됩니다.
/// 앞 판에서는 하트색을 10%만 얹었는데, 그러면 바닥은 여전히 배경 그대로라 흰 말풍선이
/// 유리 아래를 지나갈 때 안내문이 통째로 사라졌습니다. 카드 색에서 시작하면 최악의
/// 자리에서도 불투명 카드만큼은 읽힙니다. 하트색은 이 카드의 것임을 남길 만큼만 섞습니다.
private fun HeartGlassTint(surface: Color): Color =
    lerp(surface, Color(0xFFFF5C7A), 0.12f)

private data class CameraCaptureTarget(val file: File, val uri: Uri)
private data class ConversationPane(
    val binding: ConversationBinding?,
    val messages: List<ChatMessage>
)

private fun createCameraCaptureTarget(context: android.content.Context): CameraCaptureTarget? = runCatching {
    val directory = File(context.cacheDir, "camera-captures").apply { mkdirs() }
    val file = File.createTempFile("camera-", ".jpg", directory)
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    CameraCaptureTarget(file, uri)
}.getOrNull()

// 대화방 화면입니다. 목록에 놓을 줄을 만들고 조각들을 배치합니다.
//
// 조각은 옆 파일에 있습니다 — `ChatRoomHeader`, `ChatRoomInputBar`, `ChatRoomTyping`.
@Composable
fun ChatRoomScreen(
    roomId: UUID,
    onBack: () -> Unit,
    onEditPersona: () -> Unit,
    onOpenProfile: () -> Unit,
    tabletLayout: Boolean = false
) {
    val context = LocalContext.current
    val app = context.applicationContext as GagaodokApp
    val colors = KakaoTheme.colors
    val vm: ChatRoomViewModel = viewModel()
    val coroutineScope = rememberCoroutineScope()
    val density = LocalDensity.current

    val rooms by app.chatStore.rooms.collectAsState()
    val room = rooms.firstOrNull { it.id == roomId }
    val globalModel by app.settings.selectedModel.collectAsState()
    val messages by vm.messages.collectAsState()
    val isTyping by vm.isTyping.collectAsState()
    val groupTyping by vm.groupTyping.collectAsState()
    val affectionCue by vm.affectionCue.collectAsState()
    val isResponding by vm.isResponding.collectAsState()
    val loadedBinding by vm.loadedBinding.collectAsState()
    val error by vm.errorMessage.collectAsState()

    var inputText by remember { mutableStateOf("") }
    var pendingAttachment by remember { mutableStateOf<ChatAttachment?>(null) }
    var cameraCaptureTarget by remember { mutableStateOf<CameraCaptureTarget?>(null) }
    var attachmentNotice by remember { mutableStateOf<String?>(null) }
    var receivingDrop by remember { mutableStateOf(false) }
    var activeInkDocument by remember { mutableStateOf<InkDocument?>(null) }
    var inkHistoryVisible by remember { mutableStateOf(false) }
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
    var groupUiState by remember(roomId) { mutableStateOf(GroupChatUiState()) }
    var branchDialogVisible by remember(roomId) { mutableStateOf(false) }
    var branchInProgress by remember(roomId) { mutableStateOf(false) }
    val menu = LocalKakaoMenu.current
    val inkDocuments by app.inkStore.documents.collectAsState()
    val dropReceiver = remember(context) {
        object : ReceiveContentListener {
            override fun onDragEnter() { receivingDrop = true }
            override fun onDragExit() { receivingDrop = false }
            override fun onDragEnd() { receivingDrop = false }

            override fun onReceive(transferable: TransferableContent): TransferableContent {
                val clip = transferable.clipEntry.clipData
                for (index in 0 until clip.itemCount) {
                    val uri = clip.getItemAt(index).uri ?: continue
                    val attachment = readAttachment(context, uri)
                    if (attachment == null) {
                        attachmentNotice = "이미지 또는 12MB 이하 PDF만 첨부할 수 있어요."
                    } else {
                        pendingAttachment = attachment
                        attachmentNotice = null
                    }
                }
                // 이 Column에는 텍스트 입력 receiver가 없으므로 URI를 문자열로 전달하지
                // 않습니다. 첨부 처리만 하고 기존 Compose 전달값은 그대로 돌려줍니다.
                return transferable
            }
        }
    }

    if (room == null) {
        // 방이 지워진 뒤에 남아 있던 화면입니다. 조용히 빠져나갑니다.
        LaunchedEffect(Unit) { onBack() }
        return
    }

    LaunchedEffect(roomId, room.groupChat?.activeWorldlineId) { vm.bind(roomId) }

    val activeModel = room.resolvedModel(globalModel)
    val activeMode = room.resolvedMode
    val avatar = app.chatStore.avatar(room.id, room.profile)
    val group = room.groupChat
    val participantRooms = group?.participantRoomIds.orEmpty().mapNotNull { participantId ->
        rooms.firstOrNull { it.id == participantId }
    }
    val activeWorldline = group?.activeWorldline()
    val conversationReady = loadedBinding?.matches(room.id, activeWorldline?.id) == true
    val heartsByParticipant = activeWorldline?.participantHearts.orEmpty().associate { it.participantRoomId to it.value }
    val groupParticipants = participantRooms.map { participant ->
        GroupParticipantUi(
            room = participant,
            heart = heartsByParticipant[participant.id] ?: participant.profile.baseAffection,
            avatar = app.chatStore.avatar(participant.id, participant.profile)
        )
    }

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

    // 변화 표시는 스스로 접힙니다.
    LaunchedEffect(affectionCue) {
        if (affectionCue == null) return@LaunchedEffect
        delay(AFFECTION_CUE_MILLIS)
        vm.clearAffectionCue()
    }
    // 사용자가 읽기를 시작했으면 기다리지 않고 물러납니다. 카드는 대화를 가리고 있습니다.
    LaunchedEffect(affectionCue, inputText, imeVisible) {
        if (affectionCue == null) return@LaunchedEffect
        if (inputText.isNotEmpty() || imeVisible) vm.clearAffectionCue()
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
        if (uri != null) {
            pendingAttachment = readAttachment(context, uri)
            if (pendingAttachment == null) attachmentNotice = "이미지 파일을 읽을 수 없어요."
        }
    }
    val pdfPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri != null) {
            pendingAttachment = readAttachment(context, uri)
            if (pendingAttachment == null) attachmentNotice = "12MB 이하의 PDF 파일만 첨부할 수 있어요."
        }
    }
    val cameraPicker = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { captured ->
        val target = cameraCaptureTarget
        cameraCaptureTarget = null
        if (target != null) {
            if (captured) {
                val attachment = readAttachment(context, target.uri)
                if (attachment == null) {
                    attachmentNotice = "촬영한 사진을 읽을 수 없어요."
                } else {
                    pendingAttachment = attachment
                    attachmentNotice = null
                }
            }
            target.file.delete()
        }
    }

    fun takePhoto() {
        val target = createCameraCaptureTarget(context)
        if (target == null) {
            attachmentNotice = "카메라용 임시 파일을 만들 수 없어요."
            return
        }
        cameraCaptureTarget = target
        runCatching { cameraPicker.launch(target.uri) }
            .onFailure {
                cameraCaptureTarget = null
                target.file.delete()
                attachmentNotice = "카메라를 열 수 없어요."
            }
    }

    // 요약 시트가 떠 있는가. 열 때 그 시점의 상태를 한 번 계산해 넣습니다.
    var digestStatus by remember { mutableStateOf<ConversationDigestStatus?>(null) }

    fun openNewInk() {
        InkDocument(roomId = room.id.toString(), coordinateSpaceVersion = 1).also {
            app.inkStore.save(it)
            activeInkDocument = it
        }
    }

    // 상단 바의 이름을 누르면 나오는 메뉴입니다. 지금 쓰는 모드와 모델에 체크가 붙습니다.
    fun openHeaderMenu() = menu.show(
        listOf(
            KakaoMenuSection(
                title = "모드",
                items = ChatMode.entries.map { mode ->
                    KakaoMenuItem(mode.displayName, checked = mode == activeMode) {
                        menu.dismiss(); app.chatStore.updateMode(room.id, mode)
                    }
                }
            ),
            KakaoMenuSection(
                title = "모델",
                // 멘토도 Gemini 계열이면 모두 고를 수 있어야 합니다. 예전에는 3.7만
                // 적혀 있었고, 그래서 새 모델이 들어와도 멘토 방에서는 안 보였습니다.
                items = (if (activeMode == ChatMode.COMPANION) AIModel.personalCompanionModels
                    else AIModel.entries.filter { it.isGeminiConversationModel }).map { model ->
                    KakaoMenuItem(model.displayName, checked = model == activeModel) {
                        menu.dismiss(); app.chatStore.updateModel(room.id, model)
                    }
                }
            ),
            KakaoMenuSection(
                items = buildList {
                    if (tabletLayout) {
                        add(KakaoMenuItem("새 필기") { menu.dismiss(); openNewInk() })
                        add(KakaoMenuItem("필기 기록") { menu.dismiss(); inkHistoryVisible = true })
                    }
                    add(KakaoMenuItem("프로필 보기") { menu.dismiss(); onOpenProfile() })
                    add(KakaoMenuItem("말투 편집") { menu.dismiss(); onEditPersona() })
                    add(
                        KakaoMenuItem("대화 요약") {
                            menu.dismiss()
                            digestStatus = ConversationDigestStatus.of(
                                totalTurns = ConversationCompactor.turnCount(ConversationTurn.from(messages)),
                                digest = app.chatStore.loadDigest(room.id),
                            )
                        },
                    )
                }
            )
        )
    )

    fun openGroupHeaderMenu() = menu.show(listOf(
        KakaoMenuSection(
            title = "단톡방 응답 설정",
            items = listOf(
                KakaoMenuItem("Gemini 3.7 Flash · 챗봇 모드", checked = true) { menu.dismiss() }
            )
        )
    ))

    // 말풍선을 길게 눌렀을 때 나오는 메뉴입니다.
    fun openMessageMenu(target: ChatMessage) {
        val suppressPhrase = if (
            !BuildConfig.TABLET_MENTOR &&
            activeMode == ChatMode.COMPANION &&
            target.sender == com.sapiens.gagaodok.model.MessageSender.SAPIENS
        ) {
            extractOpeningPhrase(target.text)?.takeIf { candidate ->
                room.profile.persona.suppressedExpressions.none {
                    it.trim().equals(candidate, ignoreCase = true)
                }
            }
        } else null

        menu.show(*messageMenuItems(
            context = context,
            message = target,
            onDone = { menu.dismiss() },
            onEdit = {
                menu.dismiss()
                editingMessage = target
                // 커서를 글 맨 끝에 둡니다. 0에 두면 접힌 필드에 **첫 줄**이 보이는데,
                // 원조는 마지막 줄이 보입니다.
                editValue = TextFieldValue(target.text, TextRange(target.text.length))
            },
            onResend = {
                menu.dismiss()
                vm.resendFromMessage(target, replacementText = null, room = room, model = activeModel)
            },
            onDelete = { menu.dismiss(); vm.delete(target) },
            onSuppressExpression = suppressPhrase?.let { phrase ->
                { app.chatStore.suppressExpression(room.id, phrase) }
            }
        ).toTypedArray())
    }

    Box(
        Modifier.fillMaxSize().background(colors.chatBackground),
        contentAlignment = Alignment.Center
    ) {
    Column(
        Modifier
            .fillMaxHeight()
            .fillMaxWidth()
            .then(if (tabletLayout) Modifier.widthIn(max = 1_080.dp) else Modifier)
            .then(if (tabletLayout) Modifier.contentReceiver(dropReceiver) else Modifier)
            .background(colors.chatBackground)
            // 키보드가 올라온 만큼 화면 전체를 밀어 올립니다. 이게 없으면 입력창이
            // 키보드 아래에 깔립니다. 안드로이드 채팅 앱에서 가장 흔한 실패 지점입니다.
            .imePadding()
    ) {
        val toggleSearch = {
            searchVisible = !searchVisible
            if (!searchVisible) searchText = ""
            searchIndex = 0
        }
        val moveSearch: (Int) -> Unit = { step ->
            if (hits.isNotEmpty()) {
                searchIndex = ((searchIndex + step) % hits.size + hits.size) % hits.size
            }
        }
        if (group != null && activeWorldline != null) {
            GroupChatHeader(
                title = room.profile.name,
                worldlineName = activeWorldline.name,
                participants = groupParticipants,
                searchVisible = searchVisible,
                searchText = searchText,
                hitCount = hits.size,
                hitIndex = searchIndex,
                onBack = onBack,
                onToggleSearch = toggleSearch,
                onSearchTextChange = { searchText = it; searchIndex = 0 },
                onMoveSearch = moveSearch,
                onOpenMenu = { openGroupHeaderMenu() },
                onOpenWorldlines = { groupUiState = groupUiState.showWorldlines() }
            )
        } else {
            ChatHeader(
                title = room.profile.name,
                personaOn = room.profile.persona.isEnabled,
                searchVisible = searchVisible,
                searchText = searchText,
                hitCount = hits.size,
                hitIndex = searchIndex,
                onBack = onBack,
                onToggleSearch = toggleSearch,
                onSearchTextChange = { searchText = it; searchIndex = 0 },
                onMoveSearch = moveSearch,
                onOpenMenu = { openHeaderMenu() }
            )
        }

        AnimatedContent(
            targetState = ConversationPane(loadedBinding, messages),
            contentKey = { it.binding?.worldlineId },
            modifier = Modifier.weight(1f).fillMaxWidth(),
            transitionSpec = {
                if (group == null) {
                    fadeIn(tween(120)) togetherWith fadeOut(tween(90))
                } else {
                    (slideInHorizontally(tween(220, easing = FastOutSlowInEasing)) { it / 7 } + fadeIn(tween(220))) togetherWith
                        (slideOutHorizontally(tween(220, easing = FastOutSlowInEasing)) { -it / 7 } + fadeOut(tween(160)))
                }
            },
            label = "세계선 콘텐츠"
        ) { pane ->
            val displayedBinding = pane.binding
            val displayedRows = buildRows(pane.messages)
            val displayedWorldline = group?.worldlines?.firstOrNull { it.id == displayedBinding?.worldlineId }
            val displayedHearts = displayedWorldline?.participantHearts.orEmpty()
                .associate { it.participantRoomId to it.value }
            val displayedParticipants = participantRooms.map { participant ->
                GroupParticipantUi(
                    room = participant,
                    heart = displayedHearts[participant.id] ?: participant.profile.baseAffection,
                    avatar = app.chatStore.avatar(participant.id, participant.profile)
                )
            }
            val relationshipParticipants = if (displayedWorldline != null) displayedParticipants else if (
                shouldShowRelationshipGauge(room, tabletLayout)
            ) {
                listOf(GroupParticipantUi(room, room.profile.baseAffection, avatar))
            } else emptyList()
            // 목록 상태는 **화면에 뜬 pane마다 따로** 둡니다.
            //
            // 예전에는 화면 전체에서 하나를 만들어 모든 pane이 나눠 썼습니다. 그런데
            // `AnimatedContent`는 전환하는 동안 이전 pane과 새 pane을 **동시에** 올려 둡니다.
            // 그 순간 두 `LazyColumn`이 같은 상태 객체에 서로 값을 쓰면서 측정이 끝나지
            // 않습니다. 방에 들어가는 순간 한 코어를 가득 쓰며 화면이 멈췄고, 로그에는
            // 앱 코드가 한 줄도 없는 Compose 측정 루프만 남았습니다.
            val paneListState = rememberLazyListState()

            // 새 말풍선이 붙거나 키보드가 오르내리면 맨 아래로 따라갑니다.
            LaunchedEffect(displayedRows.size, isTyping, groupTyping, imeVisible) {
                if (displayedRows.isNotEmpty()) paneListState.animateScrollToItem(displayedRows.size)
            }
            LaunchedEffect(currentHitId) {
                val id = currentHitId ?: return@LaunchedEffect
                val index = displayedRows.indexOfFirst { it is Row.Bubble && it.message.id == id }
                if (index >= 0) paneListState.animateScrollToItem(index)
            }

            // 호감도 카드가 앉은 자리입니다. 유리는 대화 목록 쪽에서 그 자리를 휘고 흐립니다.
            var glassRegion by remember { mutableStateOf<LiquidGlassRegion?>(null) }
            Box(Modifier.fillMaxSize()) {
                // 유리가 볼 바닥입니다.
                //
                // 목록에만 유리를 걸면 말풍선 사이가 **투명**이라 유리가 그 자리에서 제 색만
                // 내보입니다. 그렇다고 여기에 `Modifier.background`를 붙여도 소용없습니다 —
                // 그건 유리보다 먼저 그려져서 기록에 안 들어갑니다. 배경색을 넘겨 주면
                // 유리가 자기 기록 안에서 직접 칠합니다.
                LiquidGlassBackdrop(
                    region = glassRegion,
                    backgroundColor = colors.chatBackground,
                    // 유리 색은 **불투명 카드가 쓰던 색 그대로**입니다. 배경을 이 색으로
                    // 모으므로 글자가 놓일 바닥이 예전 카드와 같아지고, 읽기가 나빠지지
                    // 않습니다. 하트색을 살짝만 섞어 이 카드의 것임을 남깁니다.
                    tint = HeartGlassTint(colors.bubbleTheirs),
                    blurRadiusPx = with(density) { LiquidGlassDefaults.blurRadius.toPx() },
                    refractionPx = with(density) { LiquidGlassDefaults.refraction.toPx() },
                    edgeBandPx = with(density) { LiquidGlassDefaults.edgeBand.toPx() },
                    rimWidthPx = with(density) { LiquidGlassDefaults.rimWidth.toPx() },
                    // 카드가 쓰던 그림자 높이 그대로입니다. 카드가 아니라 유리 쪽에서 만듭니다.
                    shadowElevation = HeartGaugeElevation,
                    modifier = Modifier.fillMaxSize()
                ) {
                LazyColumn(
                    state = paneListState,
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(top = if (relationshipParticipants.isEmpty()) 0.dp else 56.dp)
                ) {
                    items(displayedRows.size) { index ->
                        when (val row = displayedRows[index]) {
                            is Row.DateDivider -> DateDividerView(row.timestamp)
                            is Row.Bubble -> {
                                val speakerRoom = if (group == null) null else {
                                    row.message.speakerRoomId?.let { speakerId ->
                                        participantRooms.firstOrNull { it.id == speakerId }
                                    }
                                }
                                MessageBubble(
                                    message = row.message,
                                    isFirstInGroup = row.isFirstInGroup,
                                    isLastInGroup = row.isLastInGroup,
                                    botName = speakerRoom?.profile?.name ?: room.profile.name,
                                    avatar = speakerRoom?.let { app.chatStore.avatar(it.id, it.profile) } ?: avatar,
                                    searchQuery = if (searchVisible) searchText.trim() else "",
                                    isCurrentSearchHit = row.message.id == currentHitId,
                                    onImageTapped = { viewingImage = it },
                                    onLongPress = { openMessageMenu(it) },
                                    onAvatarTapped = onOpenProfile,
                                    onResend = { vm.resend(it, room, activeModel) }
                                )
                            }
                        }
                    }
                    // 입력 표시는 턴 내내 같은 항목 자리를 씁니다.
                    //
                    // 예전에는 "대화를 준비하고 있어요"와 캐릭터 입력 표시가 서로 다른 키를
                    // 써서, 준비가 끝나는 순간 항목이 사라졌다가 다른 항목이 새로 생겼습니다.
                    // 화면에서는 표시가 내려갔다 다시 올라오는 것으로 보였습니다.
                    // 지금은 단톡방에서 이름과 아바타만 바뀝니다.
                    val typingRoom = (groupTyping as? GroupTypingState.Speaking)
                        ?.let { state -> participantRooms.firstOrNull { it.id == state.roomId } }
                    val showsGroupTyping = groupTyping != GroupTypingState.Idle
                    if (showsGroupTyping || isTyping) {
                        item("turn-indicator") {
                            when {
                                typingRoom != null -> TypingIndicator(
                                    botName = typingRoom.profile.name,
                                    avatar = app.chatStore.avatar(typingRoom.id, typingRoom.profile)
                                ) { vm.cancelResponse() }
                                // 화자를 아직 모릅니다. 추측한 이름을 오래 붙여 두는 대신
                                // 참여자 아바타만 보여줍니다.
                                showsGroupTyping -> TypingIndicator(
                                    botName = null,
                                    avatars = displayedParticipants.map { it.avatar }
                                ) { vm.cancelResponse() }
                                else -> TypingIndicator(botName = room.profile.name, avatar = avatar) { vm.cancelResponse() }
                            }
                        }
                    }
                    item("bottomSpacer") { Spacer(Modifier.height(6.dp)) }
                }
                }
                if (relationshipParticipants.isNotEmpty()) {
                    HeartGaugePanel(
                        participants = relationshipParticipants,
                        // 변화가 오면 사용자가 접어 뒀더라도 잠깐 펼쳐 보여줍니다.
                        expanded = groupUiState.heartExpanded || affectionCue != null,
                        onToggle = {
                            vm.clearAffectionCue()
                            groupUiState = groupUiState.toggleHeart()
                        },
                        modifier = Modifier.align(Alignment.TopCenter).zIndex(2f),
                        changes = affectionCue?.changes.orEmpty(),
                        // 개인방에서만 마지막 변동을 이어서 보여줍니다. 단톡방은 세계선마다
                        // 참여자별로 기록이 갈려서, 카드 아래 한 줄로 대표할 수가 없습니다.
                        lastChange = if (displayedWorldline == null) {
                            room.profile.takeIf { it.lastAffectionDelta != 0 }?.let {
                                MessageHeartChange(room.id, it.lastAffectionDelta, it.lastAffectionReason)
                            }
                        } else null,
                        onGlassBounds = { glassRegion = it }
                    )
                }
            }
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
        attachmentNotice?.let {
            Row(
                Modifier
                    .fillMaxWidth()
                    .background(Color(0x22D05050))
                    .clickable { attachmentNotice = null }
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
                    enabled = !isResponding && conversationReady,
                    enhancedAttachments = tabletLayout,
                    onTextChange = { inputText = it },
                    onPickImage = {
                        picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    },
                    onTakePhoto = { takePhoto() },
                    onPickPdf = { pdfPicker.launch(arrayOf("application/pdf")) },
                    onOpenInk = { openNewInk() },
                    onClearAttachment = { pendingAttachment = null },
                    onSend = {
                        if (vm.send(inputText, pendingAttachment, room, activeModel)) {
                            inputText = ""
                            pendingAttachment = null
                        }
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

    }
    if (receivingDrop) {
        Box(
            Modifier
                .fillMaxSize()
                .background(Color(0x22000000))
                .border(2.dp, colors.bubbleMine, RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center
        ) {
            Text("사진 또는 PDF를 놓으세요", style = KakaoText.body, color = colors.textPrimary,
                modifier = Modifier.background(colors.surface, RoundedCornerShape(20.dp)).padding(horizontal = 18.dp, vertical = 10.dp))
        }
    }
    digestStatus?.let { status ->
        ConversationDigestSheet(status = status, onDismiss = { digestStatus = null })
    }

    activeInkDocument?.let { document ->
        InkFloatingPanel(
            document = document,
            onDocumentChanged = { updated ->
                app.inkStore.save(updated)
                activeInkDocument = updated
            },
            onAttachToChat = { ink ->
                coroutineScope.launch {
                    val attachment = withContext(Dispatchers.Default) { InkAttachmentFactory.create(ink) }
                    if (attachment == null) {
                        attachmentNotice = "필기를 이미지로 만들지 못했어요."
                    } else {
                        pendingAttachment = attachment
                        activeInkDocument = null
                    }
                }
            },
            onClose = { activeInkDocument = null }
        )
    }
    if (inkHistoryVisible) {
        InkHistoryDialog(
            documents = inkDocuments.filter { it.roomId == room.id.toString() },
            onOpen = { activeInkDocument = it; inkHistoryVisible = false },
            onAttach = { ink ->
                coroutineScope.launch {
                    val attachment = withContext(Dispatchers.Default) { InkAttachmentFactory.create(ink) }
                    if (attachment == null) {
                        attachmentNotice = "필기를 PNG로 만들지 못했어요."
                    } else {
                        pendingAttachment = attachment
                        attachmentNotice = null
                        inkHistoryVisible = false
                    }
                }
            },
            onRename = { id, title -> app.inkStore.rename(id, title) },
            onDelete = { id -> app.inkStore.delete(id) },
            onDismiss = { inkHistoryVisible = false }
        )
    }
    viewingImage?.let { ImageViewerDialog(it) { viewingImage = null } }
    if (group != null && activeWorldline != null && groupUiState.worldlinePickerVisible) {
        WorldlineSwitcherSheet(
            worldlines = group.worldlines,
            activeWorldlineId = group.activeWorldlineId,
            branchEnabled = !isResponding && conversationReady && !branchInProgress,
            onSelect = { selected ->
                app.chatStore.switchWorldline(room.id, selected.id)
                groupUiState = groupUiState.hideWorldlines()
            },
            onBranch = {
                groupUiState = groupUiState.hideWorldlines()
                branchDialogVisible = true
            },
            onDismiss = { groupUiState = groupUiState.hideWorldlines() }
        )
    }
    if (group != null && activeWorldline != null && branchDialogVisible) {
        BranchWorldlineDialog(
            currentWorldline = activeWorldline,
            participants = groupParticipants,
            inProgress = branchInProgress,
            onDismiss = { if (!branchInProgress) branchDialogVisible = false },
            onConfirm = { name ->
                if (!branchInProgress) coroutineScope.launch {
                    branchInProgress = true
                    runCatching {
                        app.chatStore.branchWorldline(room.id, UUID.randomUUID(), name, System.currentTimeMillis())
                    }.onFailure { attachmentNotice = it.message ?: "세계선을 나누지 못했어요." }
                    branchInProgress = false
                    branchDialogVisible = false
                }
            }
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
            sameBubbleAuthor(previous, message) &&
            previous.kind == message.kind &&
            dayOf(previous.timestamp) == day &&
            sameMinute(previous.timestamp, message.timestamp)
        val sameAsNext = next != null &&
            sameBubbleAuthor(message, next) &&
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
