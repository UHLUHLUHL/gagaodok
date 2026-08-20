package com.sapiens.gagaodok

import com.sapiens.gagaodok.ui.screens.InkToolbarControl
import com.sapiens.gagaodok.ui.screens.InkToolbarEvent
import org.junit.Assert.assertEquals
import org.junit.Test

class InkToolbarControlTest {

    @Test
    fun `펜 굵기 조절이 끝나면 자동으로 축소된다`() {
        val expanded = InkToolbarControl.reduce(InkToolbarControl.NONE, InkToolbarEvent.OPEN_PEN)
        val collapsed = InkToolbarControl.reduce(expanded, InkToolbarEvent.ADJUSTMENT_FINISHED)

        assertEquals(InkToolbarControl.PEN, expanded)
        assertEquals(InkToolbarControl.NONE, collapsed)
    }

    @Test
    fun `지우개를 길게 누르면 펜 설정 대신 지우개 버튼이 확장된다`() {
        val expanded = InkToolbarControl.reduce(InkToolbarControl.PEN, InkToolbarEvent.OPEN_ERASER)

        assertEquals(InkToolbarControl.ERASER, expanded)
    }
}
