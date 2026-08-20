package com.sapiens.gagaodok.ui.screens

import kotlin.math.abs

internal data class ElasticTrackGeometry(
    val startX: Float,
    val endX: Float,
    val centerX: Float,
    val trackHeight: Float,
    val blobWidth: Float,
    val blobHeight: Float,
    val blobLeft: Float,
    val blobRight: Float,
    val activeTrackRight: Float,
    val inactiveTrackLeft: Float
) {
    companion object {
        fun calculate(
            width: Float,
            height: Float,
            progress: Float,
            directionalStretch: Float
        ): ElasticTrackGeometry {
            val start = minOf(10f, width / 2f)
            val end = maxOf(start, width - start)
            val center = start + (end - start) * progress.coerceIn(0f, 1f)
            val stretch = directionalStretch.coerceIn(-1f, 1f)
            val trackHeight = minOf(6f, height * 0.25f)
            val blobWidth = minOf(34f, 24f + abs(stretch) * 10f)
            val blobHeight = minOf(height - 4f, 18f + abs(stretch) * 2f)
            val directionalOffset = stretch * 3f
            val blobLeft = center + directionalOffset - blobWidth / 2f
            val blobRight = center + directionalOffset + blobWidth / 2f
            return ElasticTrackGeometry(
                startX = start,
                endX = end,
                centerX = center,
                trackHeight = trackHeight,
                blobWidth = blobWidth,
                blobHeight = blobHeight,
                blobLeft = blobLeft,
                blobRight = blobRight,
                activeTrackRight = center + trackHeight,
                inactiveTrackLeft = center - trackHeight
            )
        }
    }
}
