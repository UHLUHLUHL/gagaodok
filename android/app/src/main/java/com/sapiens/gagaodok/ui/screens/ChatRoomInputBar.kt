package com.sapiens.gagaodok.ui.screens

import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.filled.Image
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import com.sapiens.gagaodok.model.AttachmentType
import com.sapiens.gagaodok.model.ChatAttachment
import com.sapiens.gagaodok.service.ImageBudget
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.components.Hairline
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import java.io.ByteArrayOutputStream
import android.provider.OpenableColumns
import java.util.Locale

// 메시지를 쓰고 고치는 자리입니다. 첨부를 읽어 들이는 것도 여기 있습니다.
internal enum class AttachmentAction {
    PHOTO_LIBRARY,
    CAMERA,
    PDF,
    INK
}

internal fun tabletAttachmentActions(): List<AttachmentAction> = listOf(
    AttachmentAction.PHOTO_LIBRARY,
    AttachmentAction.CAMERA,
    AttachmentAction.PDF,
    AttachmentAction.INK
)

@Composable
internal fun ChatInputBar(
    text: String,
    attachment: ChatAttachment?,
    enabled: Boolean,
    enhancedAttachments: Boolean,
    onTextChange: (String) -> Unit,
    onPickImage: () -> Unit,
    onTakePhoto: () -> Unit,
    onPickPdf: () -> Unit,
    onOpenInk: () -> Unit,
    onClearAttachment: () -> Unit,
    onSend: () -> Unit
) {
    val colors = KakaoTheme.colors
    val canSend = enabled && (text.isNotBlank() || attachment != null)
    var attachmentMenuExpanded by remember { mutableStateOf(false) }

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
                    if (attachment.type == AttachmentType.IMAGE) "${attachment.fileName} · ${attachment.formattedSize}"
                    else "${attachment.fileName} · ${attachment.formattedSize}",
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
            if (enhancedAttachments) {
                Box {
                    RoundInputButton(
                        onClick = { attachmentMenuExpanded = true },
                        contentDescription = "첨부 메뉴"
                    ) {
                        Icon(
                            Icons.Filled.Add, "첨부 메뉴",
                            tint = colors.textPrimary,
                            modifier = Modifier.size(Metrics.inputButtonGlyph + 2.dp)
                        )
                    }
                    if (attachmentMenuExpanded) {
                        AttachmentPopover(
                            items = tabletAttachmentActions().map { action ->
                                when (action) {
                                    AttachmentAction.PHOTO_LIBRARY ->
                                        AttachmentPopoverItem("사진", Icons.Filled.Image, onPickImage)
                                    AttachmentAction.CAMERA ->
                                        AttachmentPopoverItem("사진 촬영", Icons.Filled.CameraAlt, onTakePhoto)
                                    AttachmentAction.PDF ->
                                        AttachmentPopoverItem("파일", Icons.Filled.Description, onPickPdf)
                                    AttachmentAction.INK ->
                                        AttachmentPopoverItem("필기", Icons.Outlined.Edit, onOpenInk)
                                }
                            },
                            onDismiss = { attachmentMenuExpanded = false }
                        )
                    }
                }
            } else {
                RoundInputButton(onClick = onPickImage, contentDescription = "사진 첨부") {
                    Icon(Icons.Filled.Image, "사진 첨부", tint = colors.textPrimary, modifier = Modifier.size(Metrics.inputButtonGlyph))
                }
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
                        // 모서리는 **고정값**입니다. 백분율로 두면 줄이 늘 때 반지름이
                        // 같이 자라 글자가 필드 밖으로 나갑니다(`inputFieldCorner` 설명).
                        .background(colors.sunken, RoundedCornerShape(Metrics.inputFieldCorner))
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
                    Icons.AutoMirrored.Filled.Send, "보내기",
                    tint = if (canSend) colors.bubbleMineText else colors.textTertiary,
                    // 꽉 찬 삼각형이라 같은 숫자면 더 커 보입니다. 한 단 줄여 눈으로 맞춥니다.
                    modifier = Modifier.size(Metrics.inputButtonGlyph - 2.dp)
                )
            }
        }
    }
}

private data class AttachmentPopoverItem(
    val title: String,
    val icon: ImageVector,
    val action: () -> Unit
)

private class AboveAnchorPositionProvider(private val gapPx: Int) : PopupPositionProvider {
    override fun calculatePosition(
        anchorBounds: IntRect,
        windowSize: IntSize,
        layoutDirection: LayoutDirection,
        popupContentSize: IntSize
    ): IntOffset {
        val x = anchorBounds.left.coerceIn(gapPx, (windowSize.width - popupContentSize.width - gapPx).coerceAtLeast(gapPx))
        val y = (anchorBounds.top - popupContentSize.height - gapPx).coerceAtLeast(gapPx)
        return IntOffset(x, y)
    }
}

@Composable
private fun AttachmentPopover(items: List<AttachmentPopoverItem>, onDismiss: () -> Unit) {
    val density = LocalDensity.current
    val positionProvider = remember(density) {
        AboveAnchorPositionProvider(with(density) { 8.dp.roundToPx() })
    }
    val visible = remember { MutableTransitionState(false).apply { targetState = true } }
    var pendingAction by remember { mutableStateOf<(() -> Unit)?>(null) }
    LaunchedEffect(visible.currentState, visible.targetState) {
        if (visible.isIdle && !visible.currentState) {
            val action = pendingAction
            pendingAction = null
            onDismiss()
            action?.invoke()
        }
    }
    val close = { visible.targetState = false }

    Popup(
        popupPositionProvider = positionProvider,
        onDismissRequest = close,
        properties = PopupProperties(focusable = true)
    ) {
        AnimatedVisibility(
            visibleState = visible,
            enter = fadeIn(tween(120)) + scaleIn(tween(180), initialScale = 0.88f, transformOrigin = TransformOrigin(0f, 1f)),
            exit = fadeOut(tween(100)) + scaleOut(tween(130), targetScale = 0.92f, transformOrigin = TransformOrigin(0f, 1f))
        ) {
            Column(
                Modifier
                    .width(168.dp)
                    .shadow(9.dp, RoundedCornerShape(14.dp), clip = false)
                    .background(Color.White, RoundedCornerShape(14.dp))
                    .border(1.dp, Color(0xFFE0E3E7), RoundedCornerShape(14.dp))
                    .padding(vertical = 6.dp)
            ) {
                items.forEach { item ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .height(46.dp)
                            .clickable {
                                pendingAction = item.action
                                close()
                            }
                            .padding(horizontal = 15.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(item.icon, null, tint = Color(0xFF66707A), modifier = Modifier.size(19.dp))
                        Text(
                            item.title,
                            style = KakaoText.body,
                            color = Color(0xFF191919),
                            modifier = Modifier.padding(start = 12.dp)
                        )
                    }
                }
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
/// **하나. 원조는 고치기 전에 확인 단추가 아예 없습니다.**
/// 흐리게 두는 것도, 회색으로 두는 것도 아닙니다. 없습니다. 그래서 필드가 오른쪽
/// 끝(실측 x=1401)까지 차고, 뭔가 바뀌는 순간 단추가 생기며 필드가 x=1259로 줄어듭니다.
///
/// **여기서는 일부러 원조와 다르게 갑니다.** 사용자가 고친 것이 없어도 그대로 다시
/// 보낼 수 있기를 바랐습니다. 원조 규칙이면 그 경우 보낼 방법이 아예 없습니다.
/// 그래서 단추를 늘 두고, 필드는 늘 좁은 쪽(x=1259) 폭으로 둡니다. 잰 값을 버린 것이
/// 아니라 둘 중 잰 쪽을 골라 고정한 것입니다.
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
internal fun EditBar(
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

    // 빈 글은 보낼 수 없습니다. 지우려는 것이면 메뉴의 '삭제'가 따로 있습니다.
    val canConfirm = value.text.isNotBlank()
    val imeVisible = WindowInsets.ime.getBottom(density) > 0

    val lineHeight = with(density) { KakaoText.bubble.lineHeight.toDp() }
    // 접힘·폄을 높이 상한으로 다룹니다. 상한이 부드럽게 줄면 필드도 부드럽게 접힙니다.
    // 줄 수를 직접 바꾸면 글이 다시 접히면서 한 프레임 만에 튑니다.
    val fieldMaxHeight by animateDpAsState(
        targetValue = if (imeVisible) lineHeight * Metrics.editFieldMaxLines else lineHeight,
        animationSpec = tween(240, easing = FastOutSlowInEasing),
        label = "필드높이"
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
                    end = Metrics.editEndPadding,
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

            // 단추는 늘 있습니다. 빈 글일 때만 눌리지 않고, 입력바의 보내기 단추와
            // 같은 방식으로 흐려집니다. 나타났다 사라지지 않으므로 필드 폭도 고정입니다.
            Box(
                Modifier
                    .padding(start = Metrics.editConfirmGap)
                    // 실측: 단추 아래 끝이 필드 아래 끝보다 3화소 위입니다.
                    .padding(bottom = 1.dp)
                    .size(Metrics.editConfirm)
                    .background(
                        if (canConfirm) colors.editConfirm else colors.sunken,
                        CircleShape
                    )
                    .clickable(
                        enabled = canConfirm,
                        onClickLabel = "수정 완료",
                        onClick = onConfirm
                    ),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.Filled.Check, "수정 완료",
                    // 실측: 노란 원 위의 체크는 흰색입니다. 말풍선 글자색(#191919)이
                    // 아닙니다.
                    tint = if (canConfirm) Color.White else colors.textTertiary,
                    modifier = Modifier.size(Metrics.editConfirmGlyph)
                )
            }
        }
    }
}

// MARK: - 날짜 구분선

internal fun readAttachment(context: android.content.Context, uri: Uri): ChatAttachment? = runCatching {
    val resolver = context.contentResolver
    val mimeType = resolver.getType(uri)?.lowercase(Locale.ROOT).orEmpty()
    val displayName = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) cursor.getString(0) else null
    } ?: "첨부파일"
    val isPdf = mimeType == "application/pdf" || displayName.endsWith(".pdf", ignoreCase = true)
    val bytes = resolver.openInputStream(uri)?.use { input ->
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        var total = 0
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            total += read
            // 채팅 모델에 inline data로 보내는 파일은 사용자가 읽을 수 있게 제한합니다.
            if (total > 12 * 1024 * 1024) return null
            output.write(buffer, 0, read)
        }
        output.toByteArray()
    } ?: return null

    if (isPdf) {
        return ChatAttachment(
            type = AttachmentType.FILE,
            fileName = displayName,
            fileSize = bytes.size.toLong(),
            fileExtension = "pdf",
            dataBase64 = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP),
            mimeType = "application/pdf"
        )
    }

    if (!mimeType.startsWith("image/")) return null

    // 얼마로 줄여 보낼지 먼저 정합니다. 요금은 화소가 아니라 **타일 수**에 비례해서,
    // 아무 크기로나 줄이면 한 푼도 못 아낍니다(`ImageBudget` 설명).
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    val target = ImageBudget.plan(bounds.outWidth, bounds.outHeight)

    // 통째로 펼치지 않고 목표에 가깝게 읽습니다. 1200만 화소면 48MB입니다.
    val options = BitmapFactory.Options().apply {
        inSampleSize = ImageBudget.sampleSize(bounds.outWidth, bounds.outHeight, target)
    }
    val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
    val scaled = if (decoded.width > target.width || decoded.height > target.height) {
        android.graphics.Bitmap.createScaledBitmap(decoded, target.width, target.height, true)
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
