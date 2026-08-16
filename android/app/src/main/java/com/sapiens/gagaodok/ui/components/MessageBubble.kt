package com.sapiens.gagaodok.ui.components

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.model.ChatAttachment
import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.MessageKind
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme

/// 말풍선 한 줄입니다.
///
/// 상황 묘사는 말풍선에 넣지 않습니다. 카카오톡에는 이미 "누가 들어왔습니다" 같은
/// 안내를 가운데에 흐리게 놓는 자리가 있습니다. 그 자리를 그대로 빌려 씁니다.
/// 새 모양을 만들지 않아도 사람들이 이미 "이건 누가 한 말이 아니다"로 읽는 자리라
/// 설명 없이도 바로 통합니다.
@Composable
fun MessageBubble(
    message: ChatMessage,
    isFirstInGroup: Boolean,
    isLastInGroup: Boolean,
    botName: String,
    avatar: Bitmap?,
    isSelected: Boolean = false,
    searchQuery: String = "",
    isCurrentSearchHit: Boolean = false,
    onImageTapped: ((ChatAttachment) -> Unit)? = null,
    onLongPress: ((ChatMessage) -> Unit)? = null,
    onAvatarTapped: (() -> Unit)? = null,
    onResend: ((ChatMessage) -> Unit)? = null
) {
    if (message.kind == MessageKind.NARRATION) {
        NarrationLine(message, isSelected, searchQuery, isCurrentSearchHit, onLongPress)
    } else {
        SpeechRow(
            message, isFirstInGroup, isLastInGroup, botName, avatar,
            isSelected, searchQuery, isCurrentSearchHit,
            onImageTapped, onLongPress, onAvatarTapped, onResend
        )
    }
}

/// 상황 묘사입니다. 프로필 사진도 이름도 시간도 붙이지 않습니다.
/// 말한 사람이 없기 때문입니다.
@Composable
private fun NarrationLine(
    message: ChatMessage,
    isSelected: Boolean,
    searchQuery: String,
    isCurrentSearchHit: Boolean,
    onLongPress: ((ChatMessage) -> Unit)?
) {
    val colors = KakaoTheme.colors
    Box(
        Modifier
            .fillMaxWidth()
            .background(if (isSelected) colors.selection else Color.Transparent)
            .let {
                if (onLongPress == null) it
                else it.combinedClickable(onClick = {}, onLongClick = { onLongPress(message) })
            }
            // 말풍선보다 확실히 안쪽으로 넣습니다. 폭이 다르면 훑어볼 때 먼저 갈립니다.
            .padding(horizontal = Metrics.narrationInset, vertical = 7.dp)
    ) {
        Text(
            highlighted(message.text, searchQuery, isCurrentSearchHit, colors.searchHit, colors.searchHitCurrent),
            style = KakaoText.narration,
            color = colors.dateDividerText,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )
    }
}

@Composable
private fun SpeechRow(
    message: ChatMessage,
    isFirstInGroup: Boolean,
    isLastInGroup: Boolean,
    botName: String,
    avatar: Bitmap?,
    isSelected: Boolean,
    searchQuery: String,
    isCurrentSearchHit: Boolean,
    onImageTapped: ((ChatAttachment) -> Unit)?,
    onLongPress: ((ChatMessage) -> Unit)?,
    onAvatarTapped: (() -> Unit)?,
    onResend: ((ChatMessage) -> Unit)?
) {
    val colors = KakaoTheme.colors
    val isMine = message.sender == MessageSender.USER
    val screenWidth = LocalConfiguration.current.screenWidthDp.dp
    val maxBubbleWidth = screenWidth * Metrics.bubbleMaxWidthFraction

    // 세로 정렬이 위쪽입니다. **아래쪽으로 두면 아바타가 이름 아래로 밀립니다.**
    //
    // 원조는 아바타의 위 끝이 이름 줄의 위 끝과 같습니다(실측: 아바타 위 1024,
    // 이름 잉크 위 1043 — 그 19화소는 글꼴 자체의 윗여백입니다).
    // 아래쪽 정렬이면 이름+말풍선을 담은 세로줄이 아바타보다 길어서 아바타가 바닥에
    // 붙고, 이름이 제 줄을 통째로 차지한 것처럼 보입니다. 첫 판이 그래서 어긋나 보였습니다.
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.roomPadding)
            .padding(
                top = if (isFirstInGroup) Metrics.bubbleGap else Metrics.bubbleGapSameSender,
                bottom = if (isLastInGroup) Metrics.bubbleGap else Metrics.bubbleGapSameSender
            ),
        horizontalArrangement = if (isMine) Arrangement.End else Arrangement.Start,
        verticalAlignment = if (isMine || !isFirstInGroup) Alignment.Bottom else Alignment.Top
    ) {
        if (isMine) {
            // 실패 표시나 보낸 시각은 말풍선 바로 왼쪽에 붙습니다.
            SideMarker(message, isLastInGroup, onResend)
            Spacer(Modifier.width(Metrics.bubbleTimeGap))
            Column(horizontalAlignment = Alignment.End) {
                message.attachment?.let {
                    AttachmentView(it, isMine = true, onImageTapped = onImageTapped)
                    if (message.text.isNotEmpty()) Spacer(Modifier.padding(top = 3.dp))
                }
                if (message.text.isNotEmpty()) {
                    BubbleBody(
                        message, isFirstInGroup, isMine = true, isSelected = isSelected,
                        searchQuery = searchQuery, isCurrentSearchHit = isCurrentSearchHit,
                        maxWidth = maxBubbleWidth, onLongPress = onLongPress
                    )
                }
            }
            // 꼬리가 오른쪽으로 나가므로 그만큼 비워 둡니다.
            Spacer(Modifier.width(KakaoBubble.tailWidth))
        } else {
            if (isFirstInGroup) {
                Box(
                    Modifier
                        .size(Metrics.bubbleAvatar)
                        .let {
                            if (onAvatarTapped == null) it
                            else it.combinedClickable(onClick = onAvatarTapped, onLongClick = {})
                        }
                ) {
                    RoomAvatar(avatar, Metrics.bubbleAvatar)
                }
            } else {
                Spacer(Modifier.width(Metrics.bubbleAvatar))
            }
            Spacer(Modifier.width(Metrics.bubbleAvatarGap))

            Column(horizontalAlignment = Alignment.Start) {
                if (isFirstInGroup) {
                    Text(
                        botName,
                        style = KakaoText.senderName,
                        color = colors.textPrimary,
                        maxLines = 1,
                        modifier = Modifier.padding(bottom = Metrics.bubbleNameGap)
                    )
                }
                message.attachment?.let {
                    AttachmentView(it, isMine = false, onImageTapped = onImageTapped)
                    if (message.text.isNotEmpty()) Spacer(Modifier.padding(top = 3.dp))
                }
                if (message.text.isNotEmpty()) {
                    Row(verticalAlignment = Alignment.Bottom) {
                        BubbleBody(
                            message, isFirstInGroup, isMine = false, isSelected = isSelected,
                            searchQuery = searchQuery, isCurrentSearchHit = isCurrentSearchHit,
                            maxWidth = maxBubbleWidth, onLongPress = onLongPress
                        )
                        if (isLastInGroup) {
                            Text(
                                message.formattedTime,
                                style = KakaoText.timestamp,
                                color = colors.chatTimestamp,
                                // 좁은 화면에서 "오전 / 8:06"으로 접히지 않게 합니다.
                                // 접히면 시각이 말풍선 두 줄 높이를 차지해 줄 간격이 흐트러집니다.
                                softWrap = false,
                                maxLines = 1,
                                modifier = Modifier.padding(start = Metrics.bubbleTimeGap, bottom = 1.dp)
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun BubbleBody(
    message: ChatMessage,
    isFirstInGroup: Boolean,
    isMine: Boolean,
    isSelected: Boolean,
    searchQuery: String,
    isCurrentSearchHit: Boolean,
    maxWidth: androidx.compose.ui.unit.Dp,
    onLongPress: ((ChatMessage) -> Unit)?
) {
    val colors = KakaoTheme.colors
    Box(
        Modifier
            .widthIn(max = maxWidth)
            .kakaoBubbleBackground(
                color = if (isMine) colors.bubbleMine else colors.bubbleTheirs,
                isFirst = isFirstInGroup,
                isMine = isMine,
                overlay = if (isSelected) colors.selection else Color.Transparent
            )
            .let {
                if (onLongPress == null) it
                else it.combinedClickable(onClick = {}, onLongClick = { onLongPress(message) })
            }
            .padding(horizontal = Metrics.bubblePaddingH, vertical = Metrics.bubblePaddingV)
    ) {
        RichMessageText(
            text = message.text,
            isMine = isMine,
            searchQuery = searchQuery,
            isCurrentSearchHit = isCurrentSearchHit
        )
    }
}

/// 내 말풍선 왼편에 붙는 표시입니다. 실패했으면 재전송을, 아니면 보낸 시각을 놓습니다.
@Composable
private fun SideMarker(
    message: ChatMessage,
    isLastInGroup: Boolean,
    onResend: ((ChatMessage) -> Unit)?
) {
    val colors = KakaoTheme.colors
    when {
        message.deliveryFailed -> {
            Row(
                Modifier
                    .background(Color(0x22D05050), RoundedCornerShape(9.dp))
                    .combinedClickable(onClick = { onResend?.invoke(message) }, onLongClick = {})
                    .padding(horizontal = 7.dp, vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    Icons.Filled.Refresh, contentDescription = "다시 보내기",
                    tint = Color(0xFFD05050), modifier = Modifier.size(12.dp)
                )
                Text(
                    "재전송",
                    style = KakaoText.timestamp,
                    color = Color(0xFFD05050),
                    modifier = Modifier.padding(start = 3.dp)
                )
            }
        }
        isLastInGroup -> {
            Text(
                message.formattedTime,
                style = KakaoText.timestamp,
                color = colors.chatTimestamp,
                softWrap = false,
                maxLines = 1
            )
        }
    }
}

@Composable
private fun AttachmentView(
    attachment: ChatAttachment,
    isMine: Boolean,
    onImageTapped: ((ChatAttachment) -> Unit)?
) {
    val colors = KakaoTheme.colors
    val bitmap = AttachmentImageCache.bitmap(attachment)

    if (bitmap != null) {
        // 카카오톡은 사진 아래에 파일명을 쓰지 않습니다.
        Image(
            bitmap = bitmap.asImageBitmap(),
            contentDescription = "첨부 사진",
            contentScale = ContentScale.Fit,
            modifier = Modifier
                .widthIn(max = 260.dp)
                .heightIn(max = 260.dp)
                .clip(RoundedCornerShape(10.dp))
                .combinedClickable(
                    onClick = { onImageTapped?.invoke(attachment) },
                    onLongClick = {}
                )
        )
    } else {
        Row(
            Modifier
                .background(
                    if (isMine) colors.bubbleMine else colors.bubbleTheirs,
                    RoundedCornerShape(9.dp)
                )
                .padding(10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                Icons.Filled.Description, contentDescription = null,
                tint = colors.textSecondary, modifier = Modifier.size(22.dp)
            )
            Column(Modifier.padding(start = 8.dp)) {
                Text(
                    attachment.fileName,
                    style = KakaoText.caption,
                    color = if (isMine) colors.bubbleMineText else colors.bubbleTheirsText,
                    maxLines = 1
                )
                Text(
                    attachment.formattedSize,
                    style = KakaoText.timestamp,
                    color = colors.textSecondary
                )
            }
        }
    }
}

/// 검색어가 있으면 그 부분만 칠한 글을 돌려줍니다.
internal fun highlighted(
    text: String,
    query: String,
    isCurrent: Boolean,
    hit: Color,
    hitCurrent: Color
): AnnotatedString {
    if (query.isBlank()) return AnnotatedString(text)
    val needle = query.lowercase()
    val haystack = text.lowercase()
    return buildAnnotatedString {
        var index = 0
        while (true) {
            val found = haystack.indexOf(needle, index)
            if (found < 0) {
                append(text.substring(index))
                break
            }
            append(text.substring(index, found))
            withStyle(SpanStyle(background = if (isCurrent) hitCurrent else hit)) {
                append(text.substring(found, found + needle.length))
            }
            index = found + needle.length
        }
    }
}
