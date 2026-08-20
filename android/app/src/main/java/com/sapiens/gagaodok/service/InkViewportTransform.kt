package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.model.InkViewport

data class InkPoint2D(val x: Float, val y: Float)

object InkViewportTransform {
    const val MIN_ZOOM = 0.2f
    const val MAX_ZOOM = 8f

    fun worldToScreen(point: InkPoint2D, viewport: InkViewport, size: InkPoint2D): InkPoint2D = InkPoint2D(
        x = size.x / 2f + (point.x - viewport.centerX) * viewport.zoom,
        y = size.y / 2f + (point.y - viewport.centerY) * viewport.zoom
    )

    fun screenToWorld(point: InkPoint2D, viewport: InkViewport, size: InkPoint2D): InkPoint2D {
        val zoom = viewport.zoom.takeIf { it.isFinite() && it > 0f } ?: 1f
        return InkPoint2D(
            x = viewport.centerX + (point.x - size.x / 2f) / zoom,
            y = viewport.centerY + (point.y - size.y / 2f) / zoom
        )
    }

    fun pan(viewport: InkViewport, screenDx: Float, screenDy: Float): InkViewport {
        val zoom = viewport.zoom.coerceIn(MIN_ZOOM, MAX_ZOOM)
        return viewport.copy(
            centerX = viewport.centerX - screenDx / zoom,
            centerY = viewport.centerY - screenDy / zoom,
            zoom = zoom
        )
    }

    fun zoomAt(
        viewport: InkViewport,
        factor: Float,
        focalScreen: InkPoint2D,
        size: InkPoint2D
    ): InkViewport {
        val safeViewport = viewport.copy(zoom = viewport.zoom.coerceIn(MIN_ZOOM, MAX_ZOOM))
        val focalWorld = screenToWorld(focalScreen, safeViewport, size)
        val newZoom = (safeViewport.zoom * factor.takeIf { it.isFinite() && it > 0f }.orOne())
            .coerceIn(MIN_ZOOM, MAX_ZOOM)
        return InkViewport(
            centerX = focalWorld.x - (focalScreen.x - size.x / 2f) / newZoom,
            centerY = focalWorld.y - (focalScreen.y - size.y / 2f) / newZoom,
            zoom = newZoom
        )
    }

    fun hoverDiameter(worldWidth: Float, zoom: Float): Float =
        (worldWidth.coerceAtLeast(0f) * zoom.coerceIn(MIN_ZOOM, MAX_ZOOM)).coerceAtLeast(0f)

    private fun Float?.orOne(): Float = this ?: 1f
}
