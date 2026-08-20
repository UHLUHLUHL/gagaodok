package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.InkDocument
import com.sapiens.gagaodok.model.InkPoint
import com.sapiens.gagaodok.model.InkStroke
import com.sapiens.gagaodok.service.InkInputMode
import com.sapiens.gagaodok.service.InkPoint2D
import com.sapiens.gagaodok.ui.screens.InkCanvasState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InkCanvasStateTest {
    @Test
    fun `패널 리사이즈는 획과 뷰포트를 바꾸지 않는다`() {
        val initial = documentWithStroke()
        val state = InkCanvasState(initial)

        state.onViewportSizeChanged(1200f, 800f)

        assertEquals(initial, state.document)
    }

    @Test
    fun `취소 이벤트는 부분 획과 호버를 버린다`() {
        val state = InkCanvasState(emptyDocument())
        state.beginStroke(InkInputMode.StrokeStyle(0xFF191919, 4.5f, false))
        state.appendScreenPoint(100f, 100f, .7f, InkPoint2D(600f, 400f), 1L)
        state.updateHover(120f, 100f, 18f, InkPoint2D(600f, 400f))

        state.cancelInteraction()

        assertTrue(state.active.isEmpty())
        assertNull(state.hover)
        assertTrue(state.document.strokes.isEmpty())
    }

    @Test
    fun `이동과 확대는 실행취소 기록에 들어가지 않는다`() {
        val state = InkCanvasState(emptyDocument())

        state.panBy(20f, 10f)
        state.zoomAt(2f, InkPoint2D(100f, 100f), InkPoint2D(600f, 400f))

        assertFalse(state.canUndo)
        assertEquals(2f, state.document.viewport.zoom, 0.001f)
    }

    @Test
    fun `스트로크 도중 도구막대 변경과 필압은 현재 굵기를 바꾸지 않는다`() {
        val state = InkCanvasState(emptyDocument())
        state.beginStroke(InkInputMode.StrokeStyle(0xFF191919, 4.5f, false))
        state.appendScreenPoint(100f, 100f, .1f, InkPoint2D(600f, 400f), 1L)
        state.updateToolbarStyle(InkInputMode.StrokeStyle(0xFF191919, 30f, true))
        state.appendScreenPoint(150f, 150f, 1f, InkPoint2D(600f, 400f), 2L)

        assertTrue(state.finishStroke())
        assertEquals(4.5f, state.document.strokes.single().baseWidth, 0.001f)
        assertFalse(state.document.strokes.single().eraser)
    }

    @Test
    fun `호버 지름은 월드 지우개 굵기를 보존한다`() {
        val state = InkCanvasState(emptyDocument())
        state.zoomAt(2f, InkPoint2D(300f, 200f), InkPoint2D(600f, 400f))

        state.updateHover(300f, 200f, 18f, InkPoint2D(600f, 400f))

        assertEquals(18f, state.hover!!.worldDiameter, 0.001f)
        assertEquals(36f, state.hoverScreenDiameter, 0.001f)
    }

    @Test
    fun `지우개가 화면에 닿아 스트로크를 시작해도 크기 커서를 유지한다`() {
        val state = InkCanvasState(emptyDocument())
        state.updateHover(300f, 200f, 18f, InkPoint2D(600f, 400f))

        state.beginStroke(InkInputMode.StrokeStyle(0xFF191919, 18f, true))

        assertEquals(18f, state.hover!!.worldDiameter, 0.001f)
    }

    private fun emptyDocument() = InkDocument(roomId = "room", coordinateSpaceVersion = 1)

    private fun documentWithStroke() = emptyDocument().copy(
        strokes = listOf(
            InkStroke(
                colorArgb = 0xFF191919,
                baseWidth = 4.5f,
                points = listOf(InkPoint(800f, 600f, .5f, 1L))
            )
        )
    )
}
