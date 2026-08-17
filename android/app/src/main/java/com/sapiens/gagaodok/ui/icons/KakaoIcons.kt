package com.sapiens.gagaodok.ui.icons

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.withSign

// 카카오톡 아이콘을 맥 판에서 그대로 옮겨 왔습니다.
//
// 맥 판의 좌표는 실제 카카오톡 데스크톱 캡처를 화소 단위로 훑어 뽑은 것입니다.
// **도형(비율)만 가져오고 크기는 가져오지 않습니다.** 데스크톱의 16.5pt는
// 모바일의 16.5dp가 아닙니다. 부르는 쪽에서 모바일에 맞는 크기를 줍니다.

/// 설계 좌표를 실제 그리는 상자에 맞춰 옮깁니다.
///
/// `stretch`가 참이면 가로·세로 배율을 따로 잡아 설계 상자를 꽉 채웁니다.
/// SVG에서 옮겨 온 도형은 원본 카카오톡과 가로세로 비가 몇 %씩 다른데,
/// 비율을 지키며 맞추면 잉크 상자가 실측 비율에서 벗어납니다.
private class IconCanvas(
    private val designW: Float,
    private val designH: Float,
    private val boxW: Float,
    private val boxH: Float,
    private val stretch: Boolean = false
) {
    private val uniform = min(boxW / designW, boxH / designH)
    private val scaleX = if (stretch) boxW / designW else uniform
    private val scaleY = if (stretch) boxH / designH else uniform

    private val originX = boxW / 2f - designW * scaleX / 2f
    private val originY = boxH / 2f - designH * scaleY / 2f

    fun x(v: Float) = originX + v * scaleX
    fun y(v: Float) = originY + v * scaleY
    fun pt(px: Float, py: Float) = Offset(x(px), y(py))
    fun len(v: Float) = v * uniform
    fun lenX(v: Float) = v * scaleX
    fun lenY(v: Float) = v * scaleY
}

/// 초타원 위 한 점입니다. `n`이 2면 보통 타원이고, 커질수록 위가 평평하고
/// 옆구리가 곧아집니다. 카카오톡의 어깨 곡선이 정확히 n=2.5였습니다.
private fun superellipsePoint(
    cx: Float, cy: Float, rx: Float, ry: Float, n: Float, angleRad: Float
): Pair<Float, Float> {
    val c = cos(angleRad)
    val s = sin(angleRad)
    val e = 2f / n
    return Pair(
        cx + rx * abs(c).pow(e).withSign(c),
        cy + ry * abs(s).pow(e).withSign(s)
    )
}

/// 초타원 호를 잘게 쪼개 잇습니다. Compose의 arcTo는 정원/타원 호만 그리므로
/// 초타원이 필요하면 이렇게 직접 떠야 합니다.
private fun Path.addSuperellipseArc(
    canvas: IconCanvas, cx: Float, cy: Float, rx: Float, ry: Float,
    n: Float = 2f, fromDeg: Float, toDeg: Float, steps: Int = 72, moveFirst: Boolean
) {
    for (i in 0..steps) {
        val a = (fromDeg + (toDeg - fromDeg) * i / steps) * Math.PI.toFloat() / 180f
        val (px, py) = superellipsePoint(cx, cy, rx, ry, n, a)
        val sx = canvas.x(px)
        val sy = canvas.y(py)
        if (i == 0 && moveFirst) moveTo(sx, sy) else lineTo(sx, sy)
    }
}

// MARK: - 돋보기

/// 돋보기 — 원 하나에 45°로 뻗은 손잡이입니다.
///
/// 설계 상자 16.5 x 16.5, 원의 중심선 반지름 5.5, 획 1.5.
/// 시스템 아이콘을 쓰지 않는 이유도 재 보고 알았습니다. 원 부분 획은 원본과 같은데
/// 손잡이만 두 배 가까이 굵어, 나란히 놓으면 우리 것만 뭉툭해 보입니다.
@Composable
fun MagnifierIcon(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) { drawMagnifier(color) }
}

private fun DrawScope.drawMagnifier(color: Color) {
    val c = IconCanvas(16.5f, 16.5f, size.width, size.height)
    val cx = 6.25f
    val cy = 6.25f
    val r = 5.5f
    val exit = r / kotlin.math.sqrt(2f)

    val path = Path().apply {
        addOval(
            Rect(
                offset = c.pt(cx - r, cy - r),
                size = Size(c.len(r * 2), c.len(r * 2))
            )
        )
        val start = c.pt(cx + exit, cy + exit)
        moveTo(start.x, start.y)
        val end = c.pt(15.75f, 15.75f)
        lineTo(end.x, end.y)
    }
    drawPath(path, color, style = Stroke(width = c.len(1.5f), cap = StrokeCap.Round))
}

// MARK: - 새 대화

/// 새 대화 — 오른쪽이 트인 말풍선에 +가 붙습니다.
///
/// 설계 상자 19.5 x 16.0. 몸통은 정원이 아니라 가로로 눌린 타원이고,
/// +가 놓이는 오른쪽 72°가 통째로 비어 있습니다. 그 트임이 이 아이콘의 인상을 만듭니다.
@Composable
fun ComposeChatIcon(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) { drawComposeChat(color) }
}

private fun DrawScope.drawComposeChat(color: Color) {
    val c = IconCanvas(19.5f, 16.0f, size.width, size.height)
    val cx = 8.25f
    val cy = 7.0f
    val rx = 7.5f
    val ry = 6.25f

    val path = Path().apply {
        // 오른쪽 아래에서 시작해 바닥까지. 화면 좌표라 각도가 커지면 아래로 돕니다.
        addSuperellipseArc(c, cx, cy, rx, ry, fromDeg = 41f, toDeg = 110f, moveFirst = true)
        // 꼬리: 뾰족한 끝을 찍고 몸통 왼쪽 아래로 되돌아옵니다.
        val tail = c.pt(3.9f, 15.3f)
        lineTo(tail.x, tail.y)
        addSuperellipseArc(c, cx, cy, rx, ry, fromDeg = 134f, toDeg = 329f, moveFirst = false)

        // +. 중심 (15.5, 8.0), 획 중심선 팔 길이 3.25.
        val px = 15.5f
        val py = 8.0f
        val arm = 3.25f
        var p = c.pt(px - arm, py); moveTo(p.x, p.y)
        p = c.pt(px + arm, py); lineTo(p.x, p.y)
        p = c.pt(px, py - arm); moveTo(p.x, p.y)
        p = c.pt(px, py + arm); lineTo(p.x, p.y)
    }
    drawPath(
        path, color,
        style = Stroke(width = c.len(1.5f), cap = StrokeCap.Round, join = StrokeJoin.Round)
    )
}

// MARK: - 친구 추가

/// 친구 추가 — 외곽선 사람에 +가 붙습니다.
///
/// 설계 상자 22.0 x 17.0. 어깨는 초타원(n=2.5)의 윗반쪽을 상자 아래에서 잘라 낸
/// 호입니다. 보통 타원으로는 이 느낌이 안 납니다.
@Composable
fun AddFriendIcon(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) { drawAddFriend(color) }
}

private fun DrawScope.drawAddFriend(color: Color) {
    val c = IconCanvas(22.0f, 17.0f, size.width, size.height)

    val path = Path().apply {
        // 머리. 중심선 반지름 3.75, 획 1.5 → 바깥지름 9.
        val hr = 3.75f
        addOval(
            Rect(
                offset = c.pt(8.0f - hr, 4.5f - hr),
                size = Size(c.len(hr * 2), c.len(hr * 2))
            )
        )

        // 어깨. 중심을 상자 아래(17.5)에 두고 윗반쪽만 그리되,
        // 상자 바닥에 닿는 지점에서 끊습니다.
        val cut = 7.7f
        addSuperellipseArc(
            c, 8.0f, 17.5f, 7.5f, 6.25f, n = 2.5f,
            fromDeg = 180f + cut, toDeg = 360f - cut, moveFirst = true
        )

        // +. 중심 (18.25, 8.5), 획 중심선 팔 길이 2.9.
        val px = 18.25f
        val py = 8.5f
        val arm = 2.9f
        var p = c.pt(px - arm, py); moveTo(p.x, p.y)
        p = c.pt(px + arm, py); lineTo(p.x, p.y)
        p = c.pt(px, py - arm); moveTo(p.x, p.y)
        p = c.pt(px, py + arm); lineTo(p.x, p.y)
    }
    drawPath(
        path, color,
        style = Stroke(width = c.len(1.5f), cap = StrokeCap.Round, join = StrokeJoin.Round)
    )
}

// MARK: - 탭: 친구

/// 친구 탭 아이콘 — 머리와 어깨가 떨어져 있는 채운 실루엣입니다.
///
/// 맥 판 레일 아이콘과 같은 도형입니다. 설계 상자는 SVG의 잉크 상자 48 x 50입니다.
@Composable
fun PersonGlyph(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) { drawPersonGlyph(color) }
}

private fun DrawScope.drawPersonGlyph(color: Color) {
    val c = IconCanvas(48f, 50f, size.width, size.height, stretch = true)

    val path = Path().apply {
        // 머리: SVG는 r 13인데 12.5로 줄였습니다. 13이면 아래로 0.5 더 내려와
        // 어깨와의 틈을 먹습니다.
        addOval(
            Rect(
                offset = c.pt(11.5f, 0f),
                size = Size(c.lenX(25f), c.lenY(25f))
            )
        )

        // 어깨: 돔을 올리고 바닥은 반지름 1.5로 살짝 굴립니다.
        var p = c.pt(0f, 48.5f); moveTo(p.x, p.y)
        cubicTo(c.x(0f), c.y(37.73f), c.x(10.75f), c.y(30f), c.x(24f), c.y(30f))
        cubicTo(c.x(37.25f), c.y(30f), c.x(48f), c.y(37.73f), c.x(48f), c.y(48.5f))
        cubicTo(c.x(48f), c.y(49.33f), c.x(47.33f), c.y(50f), c.x(46.5f), c.y(50f))
        p = c.pt(1.5f, 50f); lineTo(p.x, p.y)
        cubicTo(c.x(0.67f), c.y(50f), c.x(0f), c.y(49.33f), c.x(0f), c.y(48.5f))
        close()
    }
    drawPath(path, color)
}

// MARK: - 탭: 채팅

/// 채팅 탭 아이콘 — 왼쪽 아래로 꼬리가 난 채운 말풍선입니다.
///
/// 몸통은 알약이 아니라 타원입니다. 예전에 알약으로 그렸다가 틀렸는데,
/// 그때 근거로 삼은 캡처가 안 읽은 개수 배지에 오른쪽 위를 덮여 있었습니다.
/// 가리지 않은 왼쪽 가장자리만 행마다 다시 재 보면 타원입니다.
///
/// 몸통과 꼬리를 한 Path에 넣고 **한 번만** 칠합니다. 두 도형으로 나눠 겹쳐 그리면
/// 반투명색으로 칠할 때 겹친 자리만 색이 두 번 얹혀 이음매가 그림자처럼 드러납니다.
/// 한 Path에 넣을 때는 두 도형의 감는 방향을 같게 맞춰야 합니다. 방향이 반대면
/// nonzero 규칙에서 감김수가 0이 되어 겹친 자리가 뚫립니다.
@Composable
fun ChatBubbleGlyph(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) { drawChatBubbleGlyph(color) }
}

private fun DrawScope.drawChatBubbleGlyph(color: Color) {
    val c = IconCanvas(49.68f, 47f, size.width, size.height, stretch = true)
    // 꼬리는 실측값이라 22 단위로 따로 잡습니다. 잉크 상자가 같으니
    // 두 좌표계는 화면에서 정확히 겹칩니다.
    val m = IconCanvas(22f, 22f, size.width, size.height, stretch = true)

    val path = Path().apply {
        // 몸통: 위 → 왼쪽 → 아래 → 오른쪽 순.
        var p = c.pt(24.84f, 0f); moveTo(p.x, p.y)
        cubicTo(c.x(11.12f), c.y(0f), c.x(0f), c.y(8.48f), c.x(0f), c.y(19.98f))
        cubicTo(c.x(0f), c.y(32.09f), c.x(11.12f), c.y(40.57f), c.x(24.84f), c.y(40.57f))
        cubicTo(c.x(38.56f), c.y(40.57f), c.x(49.68f), c.y(32.09f), c.x(49.68f), c.y(19.98f))
        cubicTo(c.x(49.68f), c.y(8.48f), c.x(38.56f), c.y(0f), c.x(24.84f), c.y(0f))
        close()

        // 꼬리: 몸통과 같은 방향으로 감기게 아래 끝점부터 씁니다.
        // 위쪽 두 점은 몸통 안에 넉넉히 물려 둡니다. 경계에 딱 붙이면 실틈이 보입니다.
        p = m.pt(4.05f, 22.0f); moveTo(p.x, p.y)
        p = m.pt(11.0f, 18.0f); lineTo(p.x, p.y)
        p = m.pt(4.0f, 15.0f); lineTo(p.x, p.y)
        close()
    }
    drawPath(path, color)
}

// MARK: - 탭: 설정

/// 설정 탭 아이콘 — 톱니바퀴입니다. 원본도 가는 선입니다.
///
/// 맥 판은 시스템 아이콘(`gearshape`)을 그대로 썼는데, 안드로이드에는 같은 그림이
/// 없어 직접 뜹니다. 설계 상자 24 x 24, 이 두 개는 톱니 12개를 만듭니다.
@Composable
fun GearIcon(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) { drawGear(color) }
}

private fun DrawScope.drawGear(color: Color) {
    // 설계 상자를 **잉크 상자에 맞춥니다.** 원래 24 단위 상자에 그렸는데, 톱니바퀴는
    // 바깥 반지름 9.4에 선 굵기 1.6이라 잉크가 20.4밖에 안 됐습니다. 그래서 옆의
    // 사람·말풍선(상자를 꽉 채움)과 같은 크기를 주어도 15% 작게 그려졌습니다.
    // 부르는 쪽이 "17dp"라고 하면 17dp짜리 잉크가 나오도록 여기서 맞춥니다.
    val ink = 20.4f
    val c = IconCanvas(ink, ink, size.width, size.height)
    val cx = ink / 2f
    val cy = ink / 2f
    val stroke = 1.6f

    val teeth = 8
    val outer = 9.4f
    val inner = 7.2f
    val toothHalfDeg = 11f

    val path = Path().apply {
        // 바깥 톱니 테두리. 톱니 하나마다 바깥 호와 안쪽 호를 번갈아 잇습니다.
        var first = true
        for (i in 0 until teeth) {
            val center = 360f / teeth * i
            // 바깥 호
            var a = center - toothHalfDeg
            while (a <= center + toothHalfDeg + 0.001f) {
                val rad = a * Math.PI.toFloat() / 180f
                val p = c.pt(cx + outer * cos(rad), cy + outer * sin(rad))
                if (first) { moveTo(p.x, p.y); first = false } else lineTo(p.x, p.y)
                a += 2f
            }
            // 안쪽 호 — 다음 톱니 시작 전까지
            val gapStart = center + toothHalfDeg + 6f
            val gapEnd = center + 360f / teeth - toothHalfDeg - 6f
            a = gapStart
            while (a <= gapEnd + 0.001f) {
                val rad = a * Math.PI.toFloat() / 180f
                val p = c.pt(cx + inner * cos(rad), cy + inner * sin(rad))
                lineTo(p.x, p.y)
                a += 2f
            }
        }
        close()

        // 가운데 구멍
        val hr = 3.4f
        addOval(
            Rect(
                offset = c.pt(cx - hr, cy - hr),
                size = Size(c.len(hr * 2), c.len(hr * 2))
            )
        )
    }
    drawPath(
        path, color,
        style = Stroke(width = c.len(stroke), join = StrokeJoin.Round, cap = StrokeCap.Round)
    )
}
