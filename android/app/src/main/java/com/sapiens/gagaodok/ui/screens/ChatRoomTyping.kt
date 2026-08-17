package com.sapiens.gagaodok.ui.screens

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.components.RoomAvatar
import com.sapiens.gagaodok.ui.components.kakaoBubbleBackground
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import kotlin.math.roundToInt
import kotlin.math.sin

// 답변을 기다릴 때의 "..." 표시입니다.
@Composable
internal fun TypingIndicator(
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
