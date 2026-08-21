package com.sapiens.gagaodok.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme

@Composable
internal fun PersonaLoadingSignal(
    presentation: PersonaLoadingPresentation,
    modifier: Modifier = Modifier
) {
    val colors = KakaoTheme.colors
    val signalPalette = if (colors.isDark) {
        PersonaSignalPalette(
            inactiveFirst = Color(0xFF444444),
            inactiveSecond = Color(0xFF444444),
            track = Color(0xFF474747),
            outline = Color(0xFF646464)
        )
    } else {
        PersonaSignalPalette(
            inactiveFirst = Color(0xFFD9DCE1),
            inactiveSecond = Color(0xFFE4E6EA),
            track = Color(0xFFD7D9DD),
            outline = Color(0xFFC5C8CE)
        )
    }

    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(72.dp)
            .background(colors.sunken, RoundedCornerShape(18.dp))
            .padding(horizontal = 16.dp, vertical = 16.dp)
            .semantics(mergeDescendants = true) {
                liveRegion = LiveRegionMode.Polite
            },
        verticalAlignment = Alignment.CenterVertically
    ) {
        PersonaSignalCanvas(
            active = colors.editConfirm,
            activeInk = colors.bubbleMineText,
            resting = colors.personaBadge,
            background = colors.sunken,
            palette = signalPalette,
            modifier = Modifier.size(width = 76.dp, height = 36.dp)
        )
        Column(
            Modifier
                .weight(1f)
                .padding(start = 14.dp),
            verticalArrangement = Arrangement.spacedBy(3.dp)
        ) {
            Text(
                text = presentation.title,
                color = colors.textPrimary,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                lineHeight = 20.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                text = presentation.detail,
                style = KakaoText.caption,
                color = colors.textSecondary,
                lineHeight = 17.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
private fun PersonaSignalCanvas(
    active: Color,
    activeInk: Color,
    resting: Color,
    background: Color,
    palette: PersonaSignalPalette,
    modifier: Modifier
) {
    val transition = rememberInfiniteTransition(label = "말투 조사 대화 신호")
    val fraction = transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1_200, easing = LinearEasing)
        ),
        label = "1.2초 대화 신호"
    )
    Canvas(modifier) {
        val scaleX = size.width / 76f
        val scaleY = size.height / 36f
        drawPersonaSignalBase(palette, background, scaleX, scaleY)
        drawPersonaSignalActive(
            frame = personaSignalFrame(fraction.value),
            active = active,
            activeInk = activeInk,
            resting = resting,
            scaleX = scaleX,
            scaleY = scaleY
        )
    }
}

private data class PersonaSignalPalette(
    val inactiveFirst: Color,
    val inactiveSecond: Color,
    val track: Color,
    val outline: Color
)

private fun DrawScope.drawPersonaSignalBase(
    palette: PersonaSignalPalette,
    background: Color,
    scaleX: Float,
    scaleY: Float
) {
    drawLine(
        color = palette.track,
        start = Offset(12f * scaleX, 18f * scaleY),
        end = Offset(64f * scaleX, 18f * scaleY),
        strokeWidth = 2f * scaleY,
        cap = StrokeCap.Round
    )
    drawRoundRect(
        color = palette.inactiveFirst,
        topLeft = Offset(1f * scaleX, 8f * scaleY),
        size = Size(24f * scaleX, 19f * scaleY),
        cornerRadius = CornerRadius(9.5f * scaleX, 9.5f * scaleY)
    )
    drawPath(
        path = Path().apply {
            moveTo(7f * scaleX, 26f * scaleY)
            lineTo(5f * scaleX, 31f * scaleY)
            lineTo(12f * scaleX, 27f * scaleY)
            close()
        },
        color = palette.inactiveFirst
    )
    drawRoundRect(
        color = palette.inactiveSecond,
        topLeft = Offset(26f * scaleX, 6f * scaleY),
        size = Size(24f * scaleX, 21f * scaleY),
        cornerRadius = CornerRadius(10.5f * scaleX, 10.5f * scaleY)
    )
    drawCircle(
        color = background,
        radius = 8f * scaleX,
        center = Offset(61f * scaleX, 18f * scaleY)
    )
    drawCircle(
        color = palette.outline,
        radius = 8f * scaleX,
        center = Offset(61f * scaleX, 18f * scaleY),
        style = Stroke(width = 2f * scaleY)
    )
}

private fun DrawScope.drawPersonaSignalActive(
    frame: PersonaSignalFrame,
    active: Color,
    activeInk: Color,
    resting: Color,
    scaleX: Float,
    scaleY: Float
) {
    if (frame.isResting) {
        drawCircle(
            color = resting,
            radius = 3f * scaleX,
            center = Offset(frame.centerX * scaleX, frame.centerY * scaleY)
        )
        return
    }

    val shapeProgress = ((frame.centerX - 38f) / 23f).coerceIn(0f, 1f)
    val baseWidth = mix(24f, 16f, shapeProgress)
    val baseHeight = if (frame.centerX <= 38f) {
        mix(19f, 22f, ((frame.centerX - 13f) / 25f).coerceIn(0f, 1f))
    } else {
        mix(22f, 16f, shapeProgress)
    }
    val width = baseWidth * frame.scale
    val height = baseHeight * frame.scale
    drawRoundRect(
        color = active,
        topLeft = Offset(
            (frame.centerX - width / 2f) * scaleX,
            (frame.centerY - height / 2f) * scaleY
        ),
        size = Size(width * scaleX, height * scaleY),
        cornerRadius = CornerRadius(height / 2f * scaleX, height / 2f * scaleY)
    )

    val tailStrength = ((61f - frame.centerX) / 23f).coerceIn(0f, 1f) *
        ((frame.scale - .25f) / .75f).coerceIn(0f, 1f)
    if (tailStrength > .02f) {
        val tail = Path().apply {
            moveTo(
                (frame.centerX - 4f) * scaleX,
                (frame.centerY + height / 2f - 1f) * scaleY
            )
            lineTo(
                (frame.centerX - 7f) * scaleX,
                (frame.centerY + height / 2f + 5f * tailStrength) * scaleY
            )
            lineTo(
                (frame.centerX + 1f) * scaleX,
                (frame.centerY + height / 2f) * scaleY
            )
            close()
        }
        drawPath(tail, active)
    }

    val dotStrength = ((frame.scale - .25f) / .75f).coerceIn(0f, 1f)
    if (dotStrength > .02f) {
        drawCircle(
            color = activeInk.copy(alpha = dotStrength),
            radius = 3f * frame.scale * scaleX,
            center = Offset(frame.centerX * scaleX, frame.centerY * scaleY)
        )
    }
}

private fun mix(start: Float, end: Float, fraction: Float): Float =
    start + (end - start) * fraction
