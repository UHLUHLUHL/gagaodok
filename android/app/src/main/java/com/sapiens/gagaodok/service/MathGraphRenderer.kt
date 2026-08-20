package com.sapiens.gagaodok.service

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import kotlin.math.abs
import kotlin.math.max

data class MathGraphSpec(
    val title: String = "수학 그래프",
    val type: Type = Type.CARTESIAN,
    val xExpr: String = "t",
    val yExpr: String = "x",
    val tangentSlope: Double? = null,
    val tangentPointX: Double? = null,
    val tangentPointY: Double? = null,
    val tMin: Double = 0.0,
    val tMax: Double = Math.PI * 2,
    val xMin: Double = -5.0,
    val xMax: Double = 5.0,
    val yMin: Double = -5.0,
    val yMax: Double = 5.0
) {
    enum class Type { PARAMETRIC, CARTESIAN }
}

object MathGraphRenderer {

    // MARK: - [GRAPH: ...] 태그 파싱

    private val tagRegex = Regex("""\[GRAPH:([^\]]+)\]""")

    fun extractGraphSpecs(text: String): Pair<String, List<MathGraphSpec>> {
        val specs = mutableListOf<MathGraphSpec>()
        var cleaned = text
        for (match in tagRegex.findAll(text)) {
            parseSpec(match.groupValues[1])?.let { specs += it }
            cleaned = cleaned.replace(match.value, "")
        }
        return cleaned.trim() to specs
    }

    private fun parseSpec(source: String): MathGraphSpec? {
        var spec = MathGraphSpec()
        for (component in source.split(",")) {
            val pair = component.split("=", limit = 2)
            if (pair.size != 2) continue
            val key = pair[0].trim().lowercase()
            val value = pair[1].trim().replace("\"", "")

            spec = when (key) {
                "title" -> spec.copy(title = value)
                "type" -> spec.copy(
                    type = if (value == "parametric") MathGraphSpec.Type.PARAMETRIC
                    else MathGraphSpec.Type.CARTESIAN
                )
                "x" -> spec.copy(xExpr = value)
                "y", "func", "function" -> spec.copy(yExpr = value)
                "tmin", "t_min" -> spec.copy(tMin = value.toDoubleOrNull() ?: 0.0)
                "tmax", "t_max" -> spec.copy(tMax = value.toDoubleOrNull() ?: (Math.PI * 2))
                "xmin", "x_min" -> spec.copy(xMin = value.toDoubleOrNull() ?: -5.0)
                "xmax", "x_max" -> spec.copy(xMax = value.toDoubleOrNull() ?: 5.0)
                "ymin", "y_min" -> spec.copy(yMin = value.toDoubleOrNull() ?: -5.0)
                "ymax", "y_max" -> spec.copy(yMax = value.toDoubleOrNull() ?: 5.0)
                "slope", "m" -> spec.copy(tangentSlope = value.toDoubleOrNull())
                "point" -> {
                    val xy = value.split(":")
                    val px = xy.getOrNull(0)?.toDoubleOrNull()
                    val py = xy.getOrNull(1)?.toDoubleOrNull()
                    if (px != null && py != null) spec.copy(tangentPointX = px, tangentPointY = py)
                    else spec
                }
                else -> spec
            }
        }
        return spec
    }

    /// 그래프를 그릴 수 있는 식인지 미리 확인합니다.
    /// 해석하지 못하는 식이면 그래프 자체를 만들지 않는 편이 틀린 그림보다 낫습니다.
    fun canRender(spec: MathGraphSpec): Boolean {
        if (spec.type == MathGraphSpec.Type.PARAMETRIC) {
            val x = MathExpression.parse(spec.xExpr) ?: return false
            val y = MathExpression.parse(spec.yExpr) ?: return false
            return samples(spec.tMin, spec.tMax).any {
                x.value(mapOf("t" to it)) != null && y.value(mapOf("t" to it)) != null
            }
        }
        val formula = MathExpression.parse(spec.yExpr) ?: return false
        return samples(spec.xMin, spec.xMax).any { formula.value(mapOf("x" to it)) != null }
    }

    private fun samples(from: Double, to: Double): List<Double> {
        val step = max((to - from) / 12, 0.0001)
        val out = mutableListOf<Double>()
        var v = from
        while (v <= to) { out += v; v += step }
        return out
    }

    // MARK: - 그리기
    //
    // 맥 판은 CoreGraphics로 그렸습니다. 명령이 거의 1:1이라 좌표와 색을 그대로 옮겼습니다.
    // 다만 **y축 방향이 반대**입니다. CoreGraphics는 위로 자라고 안드로이드 Canvas는
    // 아래로 자랍니다. 화면 좌표로 옮기는 함수 한 곳에서만 뒤집어 처리합니다.

    // 채팅 안에서는 축소해서 보이더라도 원본을 다시 열거나 PNG로 내보낼 때 선명해야 합니다.
    // 논리적인 800×600 도안을 2배 픽셀 밀도로 렌더링합니다.
    private const val WIDTH = 1600
    private const val HEIGHT = 1200
    private const val PADDING = 120f

    fun render(spec: MathGraphSpec): Bitmap {
        val bitmap = Bitmap.createBitmap(WIDTH, HEIGHT, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)

        // 1. 부드러운 배경
        paint.color = Color.rgb(250, 251, 253)
        canvas.drawRect(0f, 0f, WIDTH.toFloat(), HEIGHT.toFloat(), paint)

        val left = PADDING
        val right = WIDTH - PADDING
        val top = PADDING + 60f
        val bottom = HEIGHT - PADDING
        paint.color = Color.WHITE
        canvas.drawRect(left, top, right, bottom, paint)

        fun sx(x: Double): Float =
            left + ((x - spec.xMin) / (spec.xMax - spec.xMin)).toFloat() * (right - left)

        // 화면 y는 아래로 자라므로 뒤집습니다.
        fun sy(y: Double): Float =
            bottom - ((y - spec.yMin) / (spec.yMax - spec.yMin)).toFloat() * (bottom - top)

        // 2. 격자선
        paint.color = Color.rgb(230, 235, 240)
        paint.strokeWidth = 2f
        paint.style = Paint.Style.STROKE
        val xStep = (spec.xMax - spec.xMin) / 10.0
        for (i in 0..10) {
            val x = sx(spec.xMin + i * xStep)
            canvas.drawLine(x, top, x, bottom, paint)
        }
        val yStep = (spec.yMax - spec.yMin) / 8.0
        for (i in 0..8) {
            val y = sy(spec.yMin + i * yStep)
            canvas.drawLine(left, y, right, y, paint)
        }

        // 3. 축
        paint.color = Color.rgb(64, 71, 82)
        paint.strokeWidth = 3.6f
        val originY = sy(0.0)
        val originX = sx(0.0)
        if (originY in top..bottom) canvas.drawLine(left, originY, right, originY, paint)
        if (originX in left..right) canvas.drawLine(originX, top, originX, bottom, paint)

        // 4. 곡선
        canvas.save()
        canvas.clipRect(left, top, right, bottom)

        paint.color = Color.rgb(41, 128, 242)
        paint.strokeWidth = 6f
        paint.strokeCap = Paint.Cap.ROUND
        paint.strokeJoin = Paint.Join.ROUND

        val path = Path()
        var penDown = false

        if (spec.type == MathGraphSpec.Type.PARAMETRIC) {
            val steps = 400
            val dt = (spec.tMax - spec.tMin) / steps
            // 식은 한 번만 파싱하고 점마다 값만 구합니다.
            val xf = MathExpression.parse(spec.xExpr)
            val yf = MathExpression.parse(spec.yExpr)
            for (i in 0..steps) {
                val t = spec.tMin + i * dt
                val x = xf?.value(mapOf("t" to t))
                val y = yf?.value(mapOf("t" to t))
                if (x == null || y == null) {
                    // 정의되지 않는 지점에서는 선을 끊습니다.
                    penDown = false
                    continue
                }
                if (penDown) path.lineTo(sx(x), sy(y)) else { path.moveTo(sx(x), sy(y)); penDown = true }
            }
        } else {
            val steps = 500
            val dx = (spec.xMax - spec.xMin) / steps
            val formula = MathExpression.parse(spec.yExpr)
            // 세로 점근선을 가로지르며 화면을 종단하는 가짜 선이 생기지 않도록,
            // 값이 표시 범위를 크게 벗어나면 선을 끊습니다. (tan(x), 1/x 등)
            val guard = abs((spec.yMax - spec.yMin) * 4) + abs(spec.yMax) + abs(spec.yMin)
            for (i in 0..steps) {
                val x = spec.xMin + i * dx
                val y = formula?.value(mapOf("x" to x))
                if (y == null || abs(y) >= guard) {
                    penDown = false
                    continue
                }
                if (penDown) path.lineTo(sx(x), sy(y)) else { path.moveTo(sx(x), sy(y)); penDown = true }
            }
        }
        canvas.drawPath(path, paint)

        // 5. 접선과 접점
        val slope = spec.tangentSlope
        val px = spec.tangentPointX
        val py = spec.tangentPointY
        if (slope != null && px != null && py != null) {
            paint.color = Color.argb(217, 240, 64, 64)
            paint.strokeWidth = 4f
            paint.pathEffect = DashPathEffect(floatArrayOf(12f, 8f), 0f)
            val y1 = slope * (spec.xMin - px) + py
            val y2 = slope * (spec.xMax - px) + py
            canvas.drawLine(left, sy(y1), right, sy(y2), paint)
            paint.pathEffect = null

            paint.style = Paint.Style.FILL
            paint.color = Color.rgb(240, 64, 64)
            canvas.drawCircle(sx(px), sy(py), 10f, paint)
            paint.style = Paint.Style.STROKE
            paint.color = Color.WHITE
            paint.strokeWidth = 4f
            canvas.drawCircle(sx(px), sy(py), 10f, paint)
        }

        canvas.restore()

        // 6. 외곽 테두리
        paint.style = Paint.Style.STROKE
        paint.color = Color.rgb(204, 209, 217)
        paint.strokeWidth = 2.4f
        canvas.drawRect(left, top, right, bottom, paint)

        // 7. 제목
        paint.style = Paint.Style.FILL
        paint.color = Color.rgb(38, 38, 38)
        paint.textSize = 44f
        paint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        canvas.drawText(graphTitle(spec.title), PADDING, PADDING + 24f, paint)

        return bitmap
    }

    /** 이미지 안에 TeX 명령이 그대로 남는 일을 피하기 위한 안전한 최소 정리입니다. */
    private fun graphTitle(raw: String): String = raw
        .replace("$", "")
        .replace('\\'.toString() + "cdot", "·")
        .replace('\\'.toString() + "pi", "π")
        .replace('\\'.toString() + "sqrt{", "√(")
        .replace("}", ")")
}
