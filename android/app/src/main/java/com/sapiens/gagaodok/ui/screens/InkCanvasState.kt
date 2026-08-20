package com.sapiens.gagaodok.ui.screens

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.sapiens.gagaodok.model.InkDocument
import com.sapiens.gagaodok.model.InkPoint
import com.sapiens.gagaodok.model.InkStroke
import com.sapiens.gagaodok.service.InkInputMode
import com.sapiens.gagaodok.service.InkPoint2D
import com.sapiens.gagaodok.service.InkStrokeMath
import com.sapiens.gagaodok.service.InkViewportTransform

internal data class InkHoverCursor(
    val worldX: Float,
    val worldY: Float,
    val worldDiameter: Float
)

/** 비트맵 없이 월드 좌표 획, 뷰포트, undo/redo만 관리합니다. */
internal class InkCanvasState(initial: InkDocument) {
    var document by mutableStateOf(initial)
        private set
    private val activePoints = ArrayList<InkPoint>(256)
    private val redoStrokes = ArrayDeque<InkStroke>()
    private var toolbarStyle = InkInputMode.StrokeStyle(0xFF191919, 4.5f, false)
    var activeStyle: InkInputMode.StrokeStyle = toolbarStyle
        private set
    var activeRevision by mutableIntStateOf(0)
        private set
    var hover by mutableStateOf<InkHoverCursor?>(null)
        private set

    val active: List<InkPoint> get() = activePoints
    val canUndo: Boolean get() = document.strokes.isNotEmpty()
    val canRedo: Boolean get() = redoStrokes.isNotEmpty()
    val hoverScreenDiameter: Float
        get() = hover?.let { InkViewportTransform.hoverDiameter(it.worldDiameter, document.viewport.zoom) } ?: 0f

    fun updateToolbarStyle(style: InkInputMode.StrokeStyle) {
        toolbarStyle = style
    }

    fun beginStroke(style: InkInputMode.StrokeStyle) {
        activeStyle = style
        activePoints.clear()
        hover = null
        activeRevision++
    }

    fun appendScreenPoint(
        x: Float,
        y: Float,
        pressure: Float,
        surfaceSize: InkPoint2D,
        timeMillis: Long
    ) {
        val point = InkStrokeMath.worldPoint(
            x = x,
            y = y,
            viewport = document.viewport,
            surfaceSize = surfaceSize,
            pressure = pressure,
            timeMillis = timeMillis
        )
        if (activePoints.lastOrNull()?.let {
                InkStrokeMath.shouldKeep(it, point, document.viewport.zoom)
            } != false
        ) {
            activePoints += point
            activeRevision++
        }
    }

    fun finishStroke(): Boolean {
        if (activePoints.isEmpty()) return false
        document = document.copy(
            strokes = document.strokes + InkStroke(
                colorArgb = activeStyle.colorArgb,
                baseWidth = activeStyle.width,
                eraser = activeStyle.eraser,
                points = activePoints.toList()
            )
        )
        redoStrokes.clear()
        activePoints.clear()
        activeRevision++
        return true
    }

    fun cancelInteraction() {
        activePoints.clear()
        hover = null
        activeRevision++
    }

    fun panBy(screenDx: Float, screenDy: Float) {
        document = document.copy(viewport = InkViewportTransform.pan(document.viewport, screenDx, screenDy))
        activeRevision++
    }

    fun zoomAt(factor: Float, focal: InkPoint2D, surfaceSize: InkPoint2D) {
        document = document.copy(
            viewport = InkViewportTransform.zoomAt(document.viewport, factor, focal, surfaceSize)
        )
        activeRevision++
    }

    fun updateHover(screenX: Float, screenY: Float, worldDiameter: Float, surfaceSize: InkPoint2D) {
        val world = InkViewportTransform.screenToWorld(
            InkPoint2D(screenX, screenY),
            document.viewport,
            surfaceSize
        )
        hover = InkHoverCursor(world.x, world.y, worldDiameter)
        activeRevision++
    }

    fun clearHover() {
        if (hover != null) {
            hover = null
            activeRevision++
        }
    }

    fun onViewportSizeChanged(width: Float, height: Float) {
        // 의도적으로 무동작입니다. 패널 크기는 문서 좌표와 뷰포트를 바꾸지 않습니다.
        width.isFinite()
        height.isFinite()
    }

    fun undo(): Boolean {
        val last = document.strokes.lastOrNull() ?: return false
        redoStrokes.addLast(last)
        document = document.copy(strokes = document.strokes.dropLast(1))
        activeRevision++
        return true
    }

    fun redo(): Boolean {
        val stroke = redoStrokes.removeLastOrNull() ?: return false
        document = document.copy(strokes = document.strokes + stroke)
        activeRevision++
        return true
    }

    fun clear(): Boolean {
        if (document.strokes.isEmpty()) return false
        redoStrokes.clear()
        document = document.copy(strokes = emptyList())
        hover = null
        activeRevision++
        return true
    }
}
