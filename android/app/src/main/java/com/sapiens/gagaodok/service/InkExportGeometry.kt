package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.model.InkStroke
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

data class InkWorldRect(val left: Float, val top: Float, val right: Float, val bottom: Float) {
    val width: Float get() = (right - left).coerceAtLeast(0f)
    val height: Float get() = (bottom - top).coerceAtLeast(0f)
}

data class InkPixelSize(val width: Int, val height: Int)

data class InkOutputTransform(
    val scale: Float,
    val offsetX: Float,
    val offsetY: Float
) {
    fun x(worldX: Float): Float = worldX * scale + offsetX
    fun y(worldY: Float): Float = worldY * scale + offsetY
}

object InkExportGeometry {
    fun candidateBounds(strokes: List<InkStroke>): InkWorldRect? {
        var left = Float.POSITIVE_INFINITY
        var top = Float.POSITIVE_INFINITY
        var right = Float.NEGATIVE_INFINITY
        var bottom = Float.NEGATIVE_INFINITY
        var found = false
        strokes.asSequence().filterNot { it.eraser }.forEach { stroke ->
            val radius = stroke.baseWidth.takeIf { it.isFinite() }?.coerceAtLeast(0f)?.div(2f) ?: 0f
            stroke.points.forEach { point ->
                if (!point.x.isFinite() || !point.y.isFinite()) return@forEach
                found = true
                left = min(left, point.x - radius)
                top = min(top, point.y - radius)
                right = max(right, point.x + radius)
                bottom = max(bottom, point.y + radius)
            }
        }
        return if (found) InkWorldRect(left, top, right, bottom) else null
    }

    fun outputSize(
        bounds: InkWorldRect,
        minShortEdge: Int = 1600,
        maxLongEdge: Int = 4096
    ): InkPixelSize {
        val worldWidth = bounds.width.coerceAtLeast(1f)
        val worldHeight = bounds.height.coerceAtLeast(1f)
        val shortEdge = min(worldWidth, worldHeight)
        val longEdge = max(worldWidth, worldHeight)
        val scale = min(minShortEdge / shortEdge, maxLongEdge / longEdge)
        return InkPixelSize(
            width = ceil(worldWidth * scale).toInt().coerceIn(1, maxLongEdge),
            height = ceil(worldHeight * scale).toInt().coerceIn(1, maxLongEdge)
        )
    }

    fun transform(bounds: InkWorldRect, output: InkPixelSize, marginPixels: Float): InkOutputTransform {
        val drawableWidth = (output.width - marginPixels * 2f).coerceAtLeast(1f)
        val drawableHeight = (output.height - marginPixels * 2f).coerceAtLeast(1f)
        val scale = min(
            drawableWidth / bounds.width.coerceAtLeast(1f),
            drawableHeight / bounds.height.coerceAtLeast(1f)
        )
        val usedWidth = bounds.width * scale
        val usedHeight = bounds.height * scale
        return InkOutputTransform(
            scale = scale,
            offsetX = (output.width - usedWidth) / 2f - bounds.left * scale,
            offsetY = (output.height - usedHeight) / 2f - bounds.top * scale
        )
    }

    @Suppress("UNUSED_PARAMETER")
    fun outputStrokeWidth(baseWidth: Float, outputScale: Float, pressure: Float): Float {
        return (baseWidth * outputScale).coerceAtLeast(0.5f)
    }
}
