package com.sapiens.gagaodok.ui.screens

import kotlin.math.max

internal enum class InkResizeCorner {
    TOP_LEFT,
    TOP_RIGHT,
    BOTTOM_LEFT,
    BOTTOM_RIGHT
}

internal data class InkPanelBounds(
    val x: Float,
    val y: Float,
    val width: Float,
    val height: Float
) {
    fun constrained(maxWidth: Float, maxHeight: Float, minWidth: Float, minHeight: Float): InkPanelBounds {
        val safeMaxWidth = max(0f, maxWidth)
        val safeMaxHeight = max(0f, maxHeight)
        val safeMinWidth = minWidth.coerceAtMost(safeMaxWidth)
        val safeMinHeight = minHeight.coerceAtMost(safeMaxHeight)
        val nextWidth = width.coerceIn(safeMinWidth, safeMaxWidth)
        val nextHeight = height.coerceIn(safeMinHeight, safeMaxHeight)
        return copy(
            x = x.coerceIn(0f, max(0f, safeMaxWidth - nextWidth)),
            y = y.coerceIn(0f, max(0f, safeMaxHeight - nextHeight)),
            width = nextWidth,
            height = nextHeight
        )
    }

    fun movedBy(dx: Float, dy: Float, maxWidth: Float, maxHeight: Float): InkPanelBounds = copy(
        x = (x + dx).coerceIn(0f, max(0f, maxWidth - width)),
        y = (y + dy).coerceIn(0f, max(0f, maxHeight - height))
    )

    fun resized(
        corner: InkResizeCorner,
        dx: Float,
        dy: Float,
        maxWidth: Float,
        maxHeight: Float,
        minWidth: Float,
        minHeight: Float
    ): InkPanelBounds {
        val right = x + width
        val bottom = y + height
        val nextLeft = when (corner) {
            InkResizeCorner.TOP_LEFT, InkResizeCorner.BOTTOM_LEFT ->
                (x + dx).coerceIn(0f, right - minWidth.coerceAtMost(right))
            else -> x
        }
        val nextTop = when (corner) {
            InkResizeCorner.TOP_LEFT, InkResizeCorner.TOP_RIGHT ->
                (y + dy).coerceIn(0f, bottom - minHeight.coerceAtMost(bottom))
            else -> y
        }
        val nextRight = when (corner) {
            InkResizeCorner.TOP_RIGHT, InkResizeCorner.BOTTOM_RIGHT ->
                (right + dx).coerceIn(nextLeft + minWidth.coerceAtMost(maxWidth - nextLeft), maxWidth)
            else -> right
        }
        val nextBottom = when (corner) {
            InkResizeCorner.BOTTOM_LEFT, InkResizeCorner.BOTTOM_RIGHT ->
                (bottom + dy).coerceIn(nextTop + minHeight.coerceAtMost(maxHeight - nextTop), maxHeight)
            else -> bottom
        }
        return InkPanelBounds(nextLeft, nextTop, nextRight - nextLeft, nextBottom - nextTop)
            .constrained(maxWidth, maxHeight, minWidth, minHeight)
    }
}
