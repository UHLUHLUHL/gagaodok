package com.sapiens.gagaodok

import android.view.MotionEvent
import com.sapiens.gagaodok.service.InkInputMode
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InkInputModeTest {

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
