package com.sapiens.gagaodok.ui.components

import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/// 카카오톡 말풍선을 그립니다. 한 덩어리의 첫 말풍선에만 꼬리가 붙습니다.
///
/// 좌표는 맥 판에서 옮겼습니다. 맥 판은 모서리 반지름 10pt 기준으로 꼬리를
/// (-4.5, 2.5), 붙는 자리 y=11.5로 잡았습니다. 여기서는 반지름만 모바일 크기로
/// 정하고 꼬리는 그 **비율대로** 따라오게 합니다. 숫자를 따로 정하면 반지름을
/// 바꿀 때마다 꼬리가 어긋납니다.
///
/// 배경을 `Shape`로 주지 않고 직접 그립니다. `Modifier.background(shape)`는
/// 도형을 요소 크기 안으로 자르기 때문에 바깥으로 나가는 꼬리가 잘려 나갑니다.
object KakaoBubble {
    /// 맥 판은 10pt였습니다. 모바일은 글자가 커서 같은 비율로 보이려면 조금 커야 합니다.
    /// 이 값은 안드로이드 카카오톡을 재서 정한 것이 아니라 **짐작**입니다.
    val CORNER: Dp = 13.dp

    // 맥 판 기준 반지름 10에 대한 비율입니다.
    private const val TAIL_OUT = 4.5f / 10f     // 꼬리가 바깥으로 나가는 거리
    private const val TAIL_TOP = 2.5f / 10f     // 꼬리 끝의 높이
    private const val TAIL_BASE = 11.5f / 10f   // 꼬리가 몸통에 붙는 아래쪽
    private const val TAIL_INSET = 3.0f / 10f   // 꼬리가 시작하는 위쪽 변의 안쪽 지점
    private const val CTRL_OUT = 3.5f / 10f
    private const val CTRL_NEAR = 2.0f / 10f
    private const val CTRL_MID = 7.0f / 10f
    private const val CTRL_TOP = 0.5f / 10f

    /// 꼬리가 바깥으로 얼마나 나가는지입니다. 부르는 쪽이 그만큼 자리를 비워 둡니다.
    val tailWidth: Dp get() = CORNER * TAIL_OUT

    fun path(size: Size, r: Float, isFirst: Boolean, isMine: Boolean): Path {
        val w = size.width
        val h = size.height

        if (!isFirst) {
            return Path().apply {
                addRoundRect(
                    androidx.compose.ui.geometry.RoundRect(
                        Rect(0f, 0f, w, h),
                        androidx.compose.ui.geometry.CornerRadius(r, r)
                    )
                )
            }
        }

        return if (isMine) {
            val tipX = w + r * TAIL_OUT
            val topEndX = w - r * TAIL_INSET
            Path().apply {
                moveTo(r, 0f)
                lineTo(topEndX, 0f)
                quadraticBezierTo(w + r * CTRL_NEAR, r * CTRL_TOP, tipX, r * TAIL_TOP)
                quadraticBezierTo(w + r * CTRL_OUT, r * CTRL_MID, w, r * TAIL_BASE)
                lineTo(w, h - r)
                arcTo(Rect(w - 2 * r, h - 2 * r, w, h), 0f, 90f, false)
                lineTo(r, h)
                arcTo(Rect(0f, h - 2 * r, 2 * r, h), 90f, 90f, false)
                lineTo(0f, r)
                arcTo(Rect(0f, 0f, 2 * r, 2 * r), 180f, 90f, false)
                close()
            }
        } else {
            val tipX = -r * TAIL_OUT
            val topStartX = r * TAIL_INSET
            Path().apply {
                moveTo(topStartX, 0f)
                lineTo(w - r, 0f)
                arcTo(Rect(w - 2 * r, 0f, w, 2 * r), -90f, 90f, false)
                lineTo(w, h - r)
                arcTo(Rect(w - 2 * r, h - 2 * r, w, h), 0f, 90f, false)
                lineTo(r, h)
                arcTo(Rect(0f, h - 2 * r, 2 * r, h), 90f, 90f, false)
                lineTo(0f, r * TAIL_BASE)
                quadraticBezierTo(-r * CTRL_OUT, r * CTRL_MID, tipX, r * TAIL_TOP)
                quadraticBezierTo(-r * CTRL_NEAR, r * CTRL_TOP, topStartX, 0f)
                close()
            }
        }
    }
}

/// 말풍선 배경입니다. 고른 상태이면 그 위에 덧칠도 같은 도형으로 합니다.
fun Modifier.kakaoBubbleBackground(
    color: Color,
    isFirst: Boolean,
    isMine: Boolean,
    overlay: Color = Color.Transparent
): Modifier = this.drawBehind {
    val r = KakaoBubble.CORNER.toPx()
    val path = KakaoBubble.path(size, r, isFirst, isMine)
    drawPath(path, color)
    if (overlay != Color.Transparent) drawPath(path, overlay)
}
