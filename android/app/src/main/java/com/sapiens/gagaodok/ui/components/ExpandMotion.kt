package com.sapiens.gagaodok.ui.components

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.tween

/**
 * 접었다 펴는 카드의 모션입니다.
 *
 * 호감도 카드에서 쓰던 값을 그대로 꺼냈습니다. 그 카드에만 두면 다른 화면이
 * 같은 결을 내려고 숫자를 베껴 적게 되고, 한쪽만 고치면 두 곳이 갈라집니다.
 *
 * 뒤로 빠르게 밀고 천천히 안착하는 곡선이라, 크기가 변하는 동안 내용이 튀지
 * 않습니다.
 */
object ExpandMotion {
    val Easing = CubicBezierEasing(0.22f, 1f, 0.36f, 1f)

    /** 크기·모서리·화살표처럼 카드 자체가 변하는 것에 씁니다. */
    const val ShapeMillis = 380

    /** 펼칠 때 상세 내용이 뒤따라 나타나는 시간입니다. */
    const val RevealMillis = 260

    /** 크기가 먼저 자란 뒤에 내용이 오도록 늦추는 시간입니다. */
    const val RevealDelayMillis = 80

    /** 접을 때는 내용이 먼저 빠지고 크기가 줄어듭니다. */
    const val HideMillis = 120

    fun <T> shape(): FiniteAnimationSpec<T> = tween(ShapeMillis, easing = Easing)

    /**
     * 상세 내용의 투명도입니다.
     *
     * 펼칠 때와 접을 때가 다릅니다. 같은 시간을 쓰면 접는 동안 글자가 카드
     * 바깥으로 삐져나온 채로 남습니다.
     */
    fun <T> reveal(expanding: Boolean): FiniteAnimationSpec<T> =
        if (expanding) tween(RevealMillis, delayMillis = RevealDelayMillis) else tween(HideMillis)
}

/**
 * 접었다 펴는 것을 가리키는 화살표입니다.
 *
 * 호감도 카드가 쓰던 것을 그대로 꺼냈습니다. 접히면 아래를, 펼치면 위를
 * 가리키도록 180도 돕니다.
 *
 * @param progress 0이면 접힘, 1이면 펼침.
 */
@Composable
fun ExpandChevron(progress: Float, color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier.graphicsLayer { rotationZ = progress * 180f }) {
        val strokeWidth = 1.4.dp.toPx()
        drawLine(
            color,
            start = Offset(size.width * 0.28f, size.height * 0.42f),
            end = Offset(size.width * 0.5f, size.height * 0.64f),
            strokeWidth = strokeWidth,
            cap = StrokeCap.Round,
        )
        drawLine(
            color,
            start = Offset(size.width * 0.5f, size.height * 0.64f),
            end = Offset(size.width * 0.72f, size.height * 0.42f),
            strokeWidth = strokeWidth,
            cap = StrokeCap.Round,
        )
    }
}
