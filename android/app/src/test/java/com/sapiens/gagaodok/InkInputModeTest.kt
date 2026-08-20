package com.sapiens.gagaodok

import android.view.MotionEvent
import com.sapiens.gagaodok.service.InkInputMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InkInputModeTest {

    @Test
    fun `측면 버튼으로 시작한 스트로크는 실시간 미리보기에서도 지우개 스타일을 유지한다`() {
        val style = InkInputMode.resolveStrokeStyle(
            toolType = MotionEvent.TOOL_TYPE_STYLUS,
            buttonState = MotionEvent.BUTTON_STYLUS_PRIMARY,
            toolbarEraser = false,
            colorArgb = 0xFF191919,
            penWidth = 4.5f,
            eraserWidth = 18f
        )

        assertTrue(style.eraser)
        assertEquals(0xFF191919, style.colorArgb)
        assertEquals(18f, style.width)
    }

    @Test
    fun `도구막대 지우개와 펜은 각자의 굵기를 사용한다`() {
        val eraserStyle = InkInputMode.resolveStrokeStyle(
            MotionEvent.TOOL_TYPE_STYLUS,
            0,
            true,
            0xFF191919,
            penWidth = 4.5f,
            eraserWidth = 24f
        )
        val penStyle = InkInputMode.resolveStrokeStyle(
            MotionEvent.TOOL_TYPE_STYLUS,
            0,
            false,
            0xFF191919,
            penWidth = 4.5f,
            eraserWidth = 24f
        )

        assertTrue(eraserStyle.eraser)
        assertEquals(24f, eraserStyle.width)
        assertFalse(penStyle.eraser)
        assertEquals(4.5f, penStyle.width)
    }

    @Test
    fun `스타일러스 측면 버튼을 누르면 해당 스트로크만 지우개가 된다`() {
        assertTrue(InkInputMode.shouldErase(MotionEvent.TOOL_TYPE_STYLUS, MotionEvent.BUTTON_STYLUS_PRIMARY, false))
        assertTrue(InkInputMode.shouldErase(MotionEvent.TOOL_TYPE_STYLUS, MotionEvent.BUTTON_STYLUS_SECONDARY, false))
        assertFalse(InkInputMode.shouldErase(MotionEvent.TOOL_TYPE_STYLUS, 0, false))
    }

    @Test
    fun `뒤집힌 펜과 도구막대 지우개도 지우개로 유지한다`() {
        assertTrue(InkInputMode.shouldErase(MotionEvent.TOOL_TYPE_ERASER, 0, false))
        assertTrue(InkInputMode.shouldErase(MotionEvent.TOOL_TYPE_STYLUS, 0, true))
    }
}
