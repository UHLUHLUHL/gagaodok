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
/// 꼬리 윤곽은 **실기기 캡처에서 화소 단위로 뽑았습니다.** 모서리 반지름 49화소짜리
/// 받은 말풍선에서, 몸통의 왼쪽 위 모서리를 원점으로 삼아 열마다 맨 위 흰 화소를 재고
/// 반지름으로 나눠 비율로 바꿨습니다. 반지름을 바꿔도 꼬리가 따라오게 하기 위해서입니다.
///
/// 앞판에서 한 번 틀렸던 자리를 적어 둡니다. **꼬리는 뿔보다 골이 중요합니다.**
/// 뿔이 몸통 밖으로 나가는 거리는 7화소(반지름의 0.14배)로 작습니다. 그런데도 원조가
/// 깃발처럼 뚜렷하게 읽히는 것은 뿔과 윗변 사이가 (15, 15)까지 깊게 파여 있기 때문입니다.
/// 처음에는 이 골 없이 완만한 이차 곡선으로만 부풀렸는데, 꼬리를 그려 넣고도
/// 화면에서는 "꼬리가 없다"고 읽혔습니다.
///
/// 배경을 `Shape`로 주지 않고 직접 그립니다. `Modifier.background(shape)`는
/// 도형을 요소 크기 안으로 자르기 때문에 바깥으로 나가는 꼬리가 잘려 나갑니다.
object KakaoBubble {
    /// 실측 49화소 ÷ 밀도 3.75 = 13.07dp.
    val CORNER: Dp = 13.dp

    /// 꼬리 윤곽입니다. 반지름을 1로 놓은 비율이고, 몸통의 왼쪽 위 모서리가 원점입니다.
    /// 윗변에서 출발해 골을 지나 뿔 끝을 찍고, 다시 내려와 왼쪽 변에 붙습니다.
    private val TAIL = floatArrayOf(
        1.000f, 0.000f,   // 평평한 윗변이 시작되는 곳
        0.816f, 0.020f,
        0.714f, 0.061f,
        0.612f, 0.102f,
        0.490f, 0.163f,
        0.388f, 0.224f,
        0.306f, 0.306f,   // 골 — 가장 깊이 파인 곳
        0.245f, 0.265f,
        0.163f, 0.204f,
        0.082f, 0.143f,
        0.000f, 0.122f,
        -0.061f, 0.102f,
        -0.143f, 0.092f,  // 뿔 끝
        -0.122f, 0.143f,
        -0.102f, 0.163f,
        -0.082f, 0.224f,
        -0.061f, 0.286f,
        -0.041f, 0.367f,
        -0.020f, 0.490f,
        0.000f, 0.510f    // 왼쪽 변에 붙는 곳
    )

    private const val TAIL_OUT = 0.143f   // 뿔이 몸통 밖으로 나가는 거리 (반지름 대비)

    /// 꼬리가 바깥으로 얼마나 나가는지입니다. 부르는 쪽이 그만큼 자리를 비워 둡니다.
    val tailWidth: Dp get() = CORNER * TAIL_OUT

    fun path(size: Size, r: Float, isFirst: Boolean, isMine: Boolean): Path {
        val w = size.width
        val h = size.height
        // 말풍선이 아주 낮으면 반지름이 높이의 절반을 넘어 모서리끼리 겹칩니다.
        val rr = minOf(r, w / 2f, h / 2f)

        if (!isFirst) {
            return Path().apply {
                addRoundRect(
                    androidx.compose.ui.geometry.RoundRect(
                        Rect(0f, 0f, w, h),
                        androidx.compose.ui.geometry.CornerRadius(rr, rr)
                    )
                )
            }
        }

        val n = TAIL.size / 2
        return Path().apply {
            if (isMine) {
                // 꼬리가 오른쪽 위에 붙습니다. 받은 말풍선을 좌우로 뒤집은 모양입니다.
                //
                // 뒤집으면 경로를 도는 방향도 뒤집힙니다. **호의 각도도 같이 뒤집어야 합니다.**
                // 시작 각도만 옮기고 회전 방향을 그대로 두면 호가 반대편에서 시작해
                // 모서리마다 직선이 가로질러 꼬리가 찢어져 보입니다. 한 번 그렇게 냈습니다.
                moveTo(w - TAIL[0] * rr, TAIL[1] * rr)
                lineTo(rr, 0f)
                arcTo(Rect(0f, 0f, 2 * rr, 2 * rr), 270f, -90f, false)
                lineTo(0f, h - rr)
                arcTo(Rect(0f, h - 2 * rr, 2 * rr, h), 180f, -90f, false)
                lineTo(w - rr, h)
                arcTo(Rect(w - 2 * rr, h - 2 * rr, w, h), 90f, -90f, false)
                lineTo(w, TAIL[2 * (n - 1) + 1] * rr)
                for (i in n - 2 downTo 0) lineTo(w - TAIL[2 * i] * rr, TAIL[2 * i + 1] * rr)
            } else {
                moveTo(TAIL[0] * rr, TAIL[1] * rr)
                lineTo(w - rr, 0f)
                arcTo(Rect(w - 2 * rr, 0f, w, 2 * rr), -90f, 90f, false)
                lineTo(w, h - rr)
                arcTo(Rect(w - 2 * rr, h - 2 * rr, w, h), 0f, 90f, false)
                lineTo(rr, h)
                arcTo(Rect(0f, h - 2 * rr, 2 * rr, h), 90f, 90f, false)
                lineTo(0f, TAIL[2 * (n - 1) + 1] * rr)
                for (i in n - 2 downTo 0) lineTo(TAIL[2 * i] * rr, TAIL[2 * i + 1] * rr)
            }
            close()
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
