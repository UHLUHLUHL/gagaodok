package com.sapiens.gagaodok.ui.components

import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.withSign

/// 모서리가 매끄럽게 이어지는 둥근 사각형입니다.
///
/// 맥 판은 `RoundedRectangle(style: .continuous)`를 썼습니다. 그냥 둥근 사각형과
/// 다릅니다. 보통 둥근 사각형은 직선이 원호로 갑자기 바뀌어 모서리에서 곡률이 튀는데,
/// 매끄러운 쪽은 곡률이 서서히 올라갑니다. 겉보기 크기가 같아도 종류가 다르면
/// 나란히 놓았을 때 계속 어색합니다.
///
/// 안드로이드에는 같은 도형이 없습니다. 모서리의 원호를 초타원 4분호로 바꿔
/// 같은 결을 냅니다. `n`이 2면 원호 그대로이고, 커질수록 모서리가 실제 꼭짓점 쪽으로
/// 부풀어 곡률이 완만해집니다. 애플의 매끄러운 모서리와 같은 종류의 곡선입니다.
///
/// 네 모서리를 같은 식으로 뜨므로 대칭이 저절로 보장됩니다.
class SmoothRoundedShape(
    private val cornerFraction: Float,
    private val exponent: Float = 4f,
    private val steps: Int = 16
) : Shape {

    override fun createOutline(
        size: Size,
        layoutDirection: LayoutDirection,
        density: Density
    ): Outline {
        val minSide = min(size.width, size.height)
        // 반지름이 변의 절반을 넘으면 마주 보는 모서리끼리 겹칩니다.
        val r = min(cornerFraction * minSide, minSide / 2f)
        return Outline.Generic(path(size.width, size.height, r))
    }

    private fun path(w: Float, h: Float, r: Float): Path = Path().apply {
        // 각 모서리의 곡선 중심과, 그 모서리를 도는 각도 범위입니다.
        // 화면 좌표라 y가 아래로 자라므로 시계 방향으로 돌면 각도가 커집니다.
        val corners = listOf(
            Triple(w - r, r, 270f),      // 오른쪽 위: 270° → 360°
            Triple(w - r, h - r, 0f),    // 오른쪽 아래: 0° → 90°
            Triple(r, h - r, 90f),       // 왼쪽 아래: 90° → 180°
            Triple(r, r, 180f)           // 왼쪽 위: 180° → 270°
        )

        var started = false
        for ((cx, cy, from) in corners) {
            for (i in 0..steps) {
                val deg = from + 90f * i / steps
                val rad = deg * Math.PI.toFloat() / 180f
                val c = cos(rad)
                val s = sin(rad)
                val e = 2f / exponent
                val x = cx + r * abs(c).pow(e).withSign(c)
                val y = cy + r * abs(s).pow(e).withSign(s)
                if (!started) { moveTo(x, y); started = true } else lineTo(x, y)
            }
        }
        close()
    }
}

/// 프로필 사진의 테두리입니다.
///
/// **둥근 사각형이 아니라 초타원입니다.** 둘은 겉보기 크기가 같아도 계속 달라 보입니다.
/// 둥근 사각형은 곧은 변이 있다가 모서리에서 원호로 꺾이는데, 초타원은 변이 아예 없이
/// 처음부터 끝까지 휩니다.
///
/// 지수는 실기기 캡처에서 뽑았습니다. 채팅 목록의 180×180 화소 아바타에서
/// 180개 행의 폭을 재어 맞춘 값이 **2.70**이고, 잔차는 0.0001입니다.
/// (타원인 2.0은 0.0203, 4.0은 0.0349로 뚜렷하게 나쁩니다.)
/// 맨 윗줄 한 행만 앤티에일리어싱 때문에 6화소 어긋나고 나머지는 전부 1화소 안쪽입니다.
///
///     |x/a|^2.70 + |y/a|^2.70 = 1
class SuperellipseShape(
    private val exponent: Float = 2.70f,
    private val steps: Int = 24
) : Shape {

    override fun createOutline(
        size: Size,
        layoutDirection: LayoutDirection,
        density: Density
    ): Outline = Outline.Generic(path(size.width / 2f, size.height / 2f))

    private fun path(a: Float, b: Float): Path = Path().apply {
        val e = 2f / exponent
        // 한 바퀴를 매개변수로 훑습니다. 네 사분면을 같은 식으로 뜨므로
        // 대칭이 저절로 보장됩니다. 모서리 네 개를 따로 쓰면 어긋날 자리가 생깁니다.
        val total = steps * 4
        for (i in 0..total) {
            val rad = 2f * Math.PI.toFloat() * i / total
            val c = cos(rad)
            val s = sin(rad)
            val x = a + a * abs(c).pow(e).withSign(c)
            val y = b + b * abs(s).pow(e).withSign(s)
            if (i == 0) moveTo(x, y) else lineTo(x, y)
        }
        close()
    }
}

/// 아바타에 쓰는 도형입니다. 실측 지수 2.70을 씁니다.
val AvatarSquircle: Shape = SuperellipseShape()
