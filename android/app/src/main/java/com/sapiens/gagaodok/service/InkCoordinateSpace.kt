package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.model.InkDocument
import com.sapiens.gagaodok.model.InkPoint
import com.sapiens.gagaodok.model.InkViewport

object InkCoordinateSpace {
    const val CURRENT_VERSION = 1
    const val LEGACY_WIDTH = 1600f
    const val LEGACY_HEIGHT = 1200f
    private val defaultViewport = InkViewport()

    fun toCurrent(document: InkDocument): InkDocument {
        val migrated = if (document.coordinateSpaceVersion < CURRENT_VERSION) {
            document.copy(
                coordinateSpaceVersion = CURRENT_VERSION,
                viewport = defaultViewport,
                strokes = document.strokes.map { stroke ->
                    stroke.copy(points = stroke.points.map(::legacyPointToWorld))
                }
            )
        } else {
            document
        }
        return sanitize(migrated)
    }

    fun legacyPointToWorld(point: InkPoint): InkPoint = point.copy(
        x = finiteOr(point.x, 0f).coerceIn(0f, 1f) * LEGACY_WIDTH,
        y = finiteOr(point.y, 0f).coerceIn(0f, 1f) * LEGACY_HEIGHT,
        pressure = finiteOr(point.pressure, 0.5f).coerceIn(0f, 1f)
    )

    private fun sanitize(document: InkDocument): InkDocument {
        val viewport = document.viewport
        val safeViewport = if (
            viewport.centerX.isFinite() && viewport.centerY.isFinite() &&
            viewport.zoom.isFinite() && viewport.zoom > 0f
        ) viewport else defaultViewport
        return document.copy(
            coordinateSpaceVersion = CURRENT_VERSION,
            viewport = safeViewport,
            strokes = document.strokes.map { stroke ->
                stroke.copy(
                    baseWidth = finiteOr(stroke.baseWidth, 4.5f).coerceAtLeast(0.1f),
                    points = stroke.points.map { point ->
                        point.copy(
                            x = finiteOr(point.x, 0f),
                            y = finiteOr(point.y, 0f),
                            pressure = finiteOr(point.pressure, 0.5f).coerceIn(0f, 1f)
                        )
                    }
                )
            }
        )
    }

    private fun finiteOr(value: Float, fallback: Float): Float = if (value.isFinite()) value else fallback
}
