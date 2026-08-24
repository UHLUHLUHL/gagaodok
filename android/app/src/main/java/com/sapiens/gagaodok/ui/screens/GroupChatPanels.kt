package com.sapiens.gagaodok.ui.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateDp
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.updateTransition
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AccountTree
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.WorldlineState
import com.sapiens.gagaodok.ui.components.RoomAvatar
import com.sapiens.gagaodok.ui.icons.MagnifierIcon
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme

internal object WorldlineTokens {
    val accent = Color(0xFF9B8CFF)
    val soft = Color(0xFF26233A)
}

private object HeartGaugeTokens {
    val heart = Color(0xFFFF5C7A)
    val soft = Color(0xFF3B2028)
}

private val RelationshipMotionEasing = CubicBezierEasing(0.22f, 1f, 0.36f, 1f)

internal data class GroupParticipantUi(
    val room: ChatRoom,
    val heart: Int,
    val avatar: android.graphics.Bitmap?
)

@Composable
internal fun GroupChatHeader(
    title: String,
    worldlineName: String,
    participants: List<GroupParticipantUi>,
    searchVisible: Boolean,
    searchText: String,
    hitCount: Int,
    hitIndex: Int,
    onBack: () -> Unit,
    onToggleSearch: () -> Unit,
    onSearchTextChange: (String) -> Unit,
    onMoveSearch: (Int) -> Unit,
    onOpenMenu: () -> Unit,
    onOpenWorldlines: () -> Unit
) {
    if (searchVisible) {
        ChatHeader(
            title = title,
            personaOn = false,
            searchVisible = true,
            searchText = searchText,
            hitCount = hitCount,
            hitIndex = hitIndex,
            onBack = onBack,
            onToggleSearch = onToggleSearch,
            onSearchTextChange = onSearchTextChange,
            onMoveSearch = onMoveSearch,
            onOpenMenu = onOpenMenu
        )
        return
    }

    val colors = KakaoTheme.colors
    val topInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    Row(
        Modifier.fillMaxWidth().background(colors.chatHeader).padding(top = topInset)
            .height(68.dp).padding(start = 4.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        IconButton(onClick = onBack) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, "뒤로", tint = colors.onChatHeader)
        }
        Box(Modifier.width(48.dp).height(38.dp)) {
            participants.take(2).forEachIndexed { index, participant ->
                RoomAvatar(
                    participant.avatar,
                    34.dp,
                    Modifier.offset(x = (index * 14).dp, y = 2.dp)
                        .border(2.dp, colors.chatHeader, RoundedCornerShape(12.dp))
                )
            }
        }
        Column(
            Modifier.weight(1f).padding(start = 4.dp).clickable(onClick = onOpenMenu),
            verticalArrangement = Arrangement.Center
        ) {
            Text(title, style = KakaoText.roomTitle, color = colors.onChatHeader, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                "${participants.size}명 · $worldlineName",
                style = KakaoText.caption,
                color = colors.onChatHeaderDim,
                maxLines = 1
            )
        }
        IconButton(onClick = onToggleSearch) {
            MagnifierIcon(colors.onChatHeader, Modifier.size(22.dp))
        }
        IconButton(onClick = onOpenWorldlines) {
            WorldlineIcon(WorldlineTokens.accent, Modifier.size(22.dp))
        }
    }
}

@Composable
internal fun HeartGaugePanel(
    participants: List<GroupParticipantUi>,
    expanded: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier
) {
    val colors = KakaoTheme.colors
    val average = if (participants.isEmpty()) 0 else participants.sumOf { it.heart } / participants.size
    val transition = updateTransition(expanded, label = "호감도 카드")
    val width by transition.animateDp(
        transitionSpec = { tween(380, easing = RelationshipMotionEasing) }, label = "너비"
    ) { if (it) 336.dp else 84.dp }
    val height by transition.animateDp(
        transitionSpec = { tween(380, easing = RelationshipMotionEasing) }, label = "높이"
    ) { if (it) (if (participants.size > 2) 192.dp else 154.dp) else 36.dp }
    val radius by transition.animateDp(
        transitionSpec = { tween(380, easing = RelationshipMotionEasing) }, label = "모서리"
    ) { if (it) 16.dp else 18.dp }
    val detailsAlpha by transition.animateFloat(
        transitionSpec = { tween(if (targetState) 260 else 120, delayMillis = if (targetState) 80 else 0) },
        label = "상세 내용"
    ) { if (it) 1f else 0f }
    val compactAlpha by transition.animateFloat(
        transitionSpec = { tween(140) }, label = "접힌 점수"
    ) { if (it) 0f else 1f }
    val heartX by transition.animateDp(
        transitionSpec = { tween(380, easing = RelationshipMotionEasing) }, label = "하트 위치 X"
    ) { if (it) 16.dp else 10.dp }
    val heartY by transition.animateDp(
        transitionSpec = { tween(380, easing = RelationshipMotionEasing) }, label = "하트 위치 Y"
    ) { if (it) 14.dp else 8.dp }
    val chevronProgress by transition.animateFloat(
        transitionSpec = { tween(380, easing = RelationshipMotionEasing) }, label = "펼침 화살표"
    ) { if (it) 1f else 0f }
    val shape = RoundedCornerShape(radius)

    Box(modifier.fillMaxWidth().height(if (participants.size > 2) 212.dp else 174.dp).padding(top = 12.dp), contentAlignment = Alignment.TopCenter) {
        Box(
            Modifier.width(width).height(height).shadow(if (expanded) 12.dp else 0.dp, shape, clip = false)
                .clip(shape).background(colors.bubbleTheirs).border(1.dp, colors.border, shape)
                .clickable(onClick = onToggle)
        ) {
            Row(
                Modifier.fillMaxSize().graphicsLayer { alpha = compactAlpha }.padding(horizontal = 10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Spacer(Modifier.width(20.dp))
                Spacer(Modifier.weight(1f))
                Text("$average", style = KakaoText.body, color = HeartGaugeTokens.heart)
                Spacer(Modifier.width(16.dp))
            }
            Column(
                Modifier.fillMaxSize().graphicsLayer { alpha = detailsAlpha }
                    .padding(horizontal = 16.dp, vertical = 10.dp)
            ) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Spacer(Modifier.width(20.dp))
                    Text(
                        if (participants.size == 1) "호감도" else "이 세계선의 호감도",
                        style = KakaoText.sectionHeader,
                        color = colors.textPrimary,
                        modifier = Modifier.padding(start = 8.dp)
                    )
                    Spacer(Modifier.weight(1f))
                    if (participants.size > 1) Text("평균 $average", style = KakaoText.caption, color = colors.textSecondary)
                    Spacer(Modifier.width(16.dp))
                }
                Box(Modifier.fillMaxWidth().padding(top = 8.dp).height(1.dp).background(colors.border))
                participants.take(3).forEach { participant ->
                    Row(
                        Modifier.fillMaxWidth().height(38.dp).padding(top = 6.dp),
                        verticalAlignment = Alignment.Top
                    ) {
                        RoomAvatar(participant.avatar, 28.dp)
                        Column(Modifier.weight(1f).padding(start = 8.dp)) {
                            Row(Modifier.fillMaxWidth()) {
                                Text(participant.room.profile.name, style = KakaoText.senderName, color = colors.textPrimary)
                                Spacer(Modifier.weight(1f))
                                Text("${participant.heart}", style = KakaoText.senderName, color = HeartGaugeTokens.heart)
                            }
                            Box(Modifier.fillMaxWidth().padding(top = 4.dp).height(4.dp).clip(CircleShape).background(HeartGaugeTokens.soft)) {
                                Box(
                                    Modifier.fillMaxWidth((participant.heart.coerceIn(0, 100) / 100f).coerceAtLeast(0.01f))
                                        .height(4.dp).background(HeartGaugeTokens.heart, CircleShape)
                                )
                            }
                        }
                    }
                }
                if (participants.size <= 3) {
                    Text(
                        if (participants.size == 1) "앞으로의 대화에 따라 변화합니다."
                        else "기본 호감도를 이어받아 이 세계선에서 변화합니다.",
                        style = KakaoText.timestamp,
                        color = colors.textTertiary,
                        maxLines = 1,
                        modifier = Modifier.padding(top = 2.dp)
                    )
                }
            }
            RelationshipHeart(Modifier.offset(x = heartX, y = heartY).size(20.dp))
            RelationshipChevron(
                chevronProgress,
                colors.textSecondary,
                Modifier.align(Alignment.TopEnd).padding(top = 11.dp, end = 8.dp).size(14.dp)
            )
        }
    }
}

@Composable
private fun RelationshipHeart(modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val sx = size.width / 20f
        val sy = size.height / 20f
        val path = Path().apply {
            moveTo(10f * sx, 17.1f * sy)
            lineTo(3.2f * sx, 10.5f * sy)
            cubicTo(1.4f * sx, 8.8f * sy, 1.5f * sx, 5.9f * sy, 3.4f * sx, 4.3f * sy)
            cubicTo(5.2f * sx, 2.8f * sy, 7.8f * sx, 3.1f * sy, 9.3f * sx, 4.8f * sy)
            lineTo(10f * sx, 5.6f * sy)
            lineTo(10.7f * sx, 4.8f * sy)
            cubicTo(12.2f * sx, 3.1f * sy, 14.8f * sx, 2.8f * sy, 16.6f * sx, 4.3f * sy)
            cubicTo(18.5f * sx, 5.9f * sy, 18.6f * sx, 8.8f * sy, 16.8f * sx, 10.5f * sy)
            close()
        }
        drawPath(path, HeartGaugeTokens.heart)
    }
}

@Composable
private fun RelationshipChevron(progress: Float, color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier.graphicsLayer { rotationZ = progress * 180f }) {
        val strokeWidth = 1.4.dp.toPx()
        drawLine(color, start = androidx.compose.ui.geometry.Offset(size.width * 0.28f, size.height * 0.42f), end = androidx.compose.ui.geometry.Offset(size.width * 0.5f, size.height * 0.64f), strokeWidth = strokeWidth, cap = StrokeCap.Round)
        drawLine(color, start = androidx.compose.ui.geometry.Offset(size.width * 0.5f, size.height * 0.64f), end = androidx.compose.ui.geometry.Offset(size.width * 0.72f, size.height * 0.42f), strokeWidth = strokeWidth, cap = StrokeCap.Round)
    }
}

@Composable
private fun WorldlineIcon(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val stroke = Stroke(width = 1.6.dp.toPx(), cap = StrokeCap.Round)
        val p = Path().apply {
            moveTo(size.width * 0.27f, size.height * 0.32f)
            cubicTo(size.width * 0.27f, size.height * 0.55f, size.width * 0.58f, size.height * 0.48f, size.width * 0.73f, size.height * 0.73f)
            moveTo(size.width * 0.27f, size.height * 0.32f)
            lineTo(size.width * 0.27f, size.height * 0.73f)
        }
        drawPath(p, color, style = stroke)
        drawCircle(color, size.width * 0.09f, androidx.compose.ui.geometry.Offset(size.width * 0.27f, size.height * 0.23f))
        drawCircle(color, size.width * 0.09f, androidx.compose.ui.geometry.Offset(size.width * 0.27f, size.height * 0.82f))
        drawCircle(color, size.width * 0.09f, androidx.compose.ui.geometry.Offset(size.width * 0.77f, size.height * 0.82f))
    }
}

@Composable
internal fun WorldlineSwitcherSheet(
    worldlines: List<WorldlineState>,
    activeWorldlineId: java.util.UUID,
    branchEnabled: Boolean,
    onSelect: (WorldlineState) -> Unit,
    onBranch: () -> Unit,
    onDismiss: () -> Unit
) {
    val colors = KakaoTheme.colors
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = colors.surface,
        scrimColor = Color.Black.copy(alpha = 0.56f),
        dragHandle = null
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
            Box(Modifier.align(Alignment.CenterHorizontally).width(38.dp).height(4.dp).background(colors.border, CircleShape))
            Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("세계선", style = KakaoText.screenTitle, color = colors.textPrimary)
                    Text("같은 시작에서 갈라진 대화를 선택해 이어가세요.", style = KakaoText.caption, color = colors.textSecondary)
                }
                Row(
                    Modifier.clip(CircleShape).background(WorldlineTokens.soft)
                        .clickable(enabled = branchEnabled, onClick = onBranch)
                        .padding(horizontal = 10.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    val branchColor = if (branchEnabled) WorldlineTokens.accent else colors.textTertiary
                    Icon(Icons.Filled.Add, null, tint = branchColor, modifier = Modifier.size(14.dp))
                    Text(if (branchEnabled) "분기" else "응답 중", style = KakaoText.caption, color = branchColor, modifier = Modifier.padding(start = 4.dp))
                }
            }
            AnimatedContent(
                targetState = activeWorldlineId,
                transitionSpec = {
                    (slideInHorizontally(tween(220, easing = FastOutSlowInEasing)) { it / 8 } + fadeIn(tween(220))) togetherWith
                        (slideOutHorizontally(tween(220, easing = FastOutSlowInEasing)) { -it / 8 } + fadeOut(tween(160)))
                },
                label = "세계선 전환"
            ) { selectedId ->
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    worldlines.forEach { worldline ->
                        WorldlineRow(worldline, worldline.id == selectedId) { onSelect(worldline) }
                    }
                }
            }
            Text(
                "분기하면 현재 대화와 하트를 상속하고, 이후 값은 이 세계선에서만 변합니다.",
                style = KakaoText.caption,
                color = colors.textTertiary,
                modifier = Modifier.padding(top = 12.dp, bottom = 20.dp)
            )
        }
    }
}

@Composable
private fun WorldlineRow(worldline: WorldlineState, selected: Boolean, onClick: () -> Unit) {
    val colors = KakaoTheme.colors
    val border = if (selected) WorldlineTokens.accent else colors.border
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
            .background(if (selected) WorldlineTokens.soft else colors.sunken)
            .border(1.dp, border, RoundedCornerShape(16.dp)).clickable(onClick = onClick)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(Icons.Filled.AccountTree, null, tint = if (selected) WorldlineTokens.accent else colors.textTertiary, modifier = Modifier.size(22.dp))
        Column(Modifier.weight(1f).padding(start = 10.dp)) {
            Text(worldline.name, style = KakaoText.senderName, color = if (selected) WorldlineTokens.accent else colors.textPrimary)
            Text("이 세계선의 대화를 이어가요", style = KakaoText.caption, color = colors.textSecondary)
        }
        Text("♥ ${activeHeartAverage(worldline)}", style = KakaoText.caption, color = HeartGaugeTokens.heart,
            modifier = Modifier.clip(CircleShape).background(HeartGaugeTokens.soft).padding(horizontal = 8.dp, vertical = 4.dp))
    }
}

@Composable
internal fun BranchWorldlineDialog(
    currentWorldline: WorldlineState,
    participants: List<GroupParticipantUi>,
    inProgress: Boolean,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit
) {
    val colors = KakaoTheme.colors
    var name by remember { mutableStateOf("새 세계선") }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).clip(RoundedCornerShape(20.dp))
                .background(colors.surface).border(1.dp, colors.border, RoundedCornerShape(20.dp))
                .padding(horizontal = 18.dp, vertical = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Box(Modifier.size(44.dp).background(WorldlineTokens.soft, CircleShape), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.AccountTree, null, tint = WorldlineTokens.accent, modifier = Modifier.size(24.dp))
            }
            Text("여기서 세계선을 나누시겠어요?", style = KakaoText.screenTitle, color = colors.textPrimary)
            Text(
                "현재 대화와 각 캐릭터의 하트 값을 그대로 복사합니다. 이후의 대화와 하트 변화는 새 세계선에만 남습니다.",
                style = KakaoText.body,
                color = colors.textSecondary
            )
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(HeartGaugeTokens.soft)
                    .padding(horizontal = 12.dp, vertical = 10.dp)
            ) {
                Text("현재 ${currentWorldline.name}에서 상속", style = KakaoText.caption, color = colors.textSecondary)
                Text(
                    participants.joinToString("  ·  ") { "${it.room.profile.name} ♥ ${it.heart}" },
                    style = KakaoText.senderName,
                    color = HeartGaugeTokens.heart
                )
            }
            BasicTextField(
                value = name,
                onValueChange = { name = it },
                singleLine = true,
                textStyle = KakaoText.body.copy(color = colors.textPrimary),
                cursorBrush = SolidColor(WorldlineTokens.accent),
                modifier = Modifier.fillMaxWidth().height(44.dp).clip(RoundedCornerShape(12.dp))
                    .background(colors.sunken).border(1.dp, colors.border, RoundedCornerShape(12.dp))
                    .padding(horizontal = 12.dp, vertical = 11.dp)
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                DialogAction("취소", false, Modifier.weight(1f), enabled = !inProgress, onClick = onDismiss)
                DialogAction(if (inProgress) "복사 중…" else "분기하기", true, Modifier.weight(1f), enabled = !inProgress) {
                    name.trim().takeIf { it.isNotEmpty() }?.let(onConfirm)
                }
            }
        }
    }
}

@Composable
private fun DialogAction(
    label: String,
    primary: Boolean,
    modifier: Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit
) {
    val colors = KakaoTheme.colors
    Box(
        modifier.height(44.dp).clip(RoundedCornerShape(12.dp))
            .background(if (primary) WorldlineTokens.accent else colors.sunken)
            .then(if (primary) Modifier else Modifier.border(1.dp, colors.border, RoundedCornerShape(12.dp)))
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Text(label, style = KakaoText.senderName, color = if (primary) Color(0xFF1A1A1A) else colors.textSecondary)
    }
}
