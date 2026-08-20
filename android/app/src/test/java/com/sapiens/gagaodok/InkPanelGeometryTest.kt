package com.sapiens.gagaodok

import androidx.compose.ui.graphics.Color
import com.sapiens.gagaodok.service.InkColorCodec
import com.sapiens.gagaodok.ui.screens.InkPanelBounds
import com.sapiens.gagaodok.ui.screens.InkResizeCorner
import org.junit.Assert.assertEquals
import org.junit.Test

class InkPanelGeometryTest {

    @Test
    fun `저장된 Compose 색상은 PNG용 ARGB로 복원한다`() {
        val stored = Color(0xFF191919).value.toLong()

        assertEquals(0xFF191919.toInt(), InkColorCodec.toArgb(stored))
    }

    @Test
    fun `네 모서리 리사이즈는 반대쪽 모서리를 고정한다`() {
        val initial = InkPanelBounds(x = 100f, y = 80f, width = 500f, height = 360f)

        assertEquals(
            InkPanelBounds(80f, 60f, 520f, 380f),
            initial.resized(InkResizeCorner.TOP_LEFT, -20f, -20f, 800f, 700f, 300f, 250f)
        )
        assertEquals(
            InkPanelBounds(100f, 60f, 530f, 380f),
            initial.resized(InkResizeCorner.TOP_RIGHT, 30f, -20f, 800f, 700f, 300f, 250f)
        )
        assertEquals(
            InkPanelBounds(80f, 80f, 520f, 390f),
            initial.resized(InkResizeCorner.BOTTOM_LEFT, -20f, 30f, 800f, 700f, 300f, 250f)
        )
        assertEquals(
            InkPanelBounds(100f, 80f, 530f, 390f),
            initial.resized(InkResizeCorner.BOTTOM_RIGHT, 30f, 30f, 800f, 700f, 300f, 250f)
        )
    }

    @Test
    fun `왼쪽 위 리사이즈는 최소 크기와 화면 경계를 지킨다`() {
        val initial = InkPanelBounds(x = 100f, y = 80f, width = 500f, height = 360f)

        assertEquals(
            InkPanelBounds(0f, 0f, 600f, 440f),
            initial.resized(InkResizeCorner.TOP_LEFT, -500f, -500f, 800f, 700f, 300f, 250f)
        )
        assertEquals(
            InkPanelBounds(300f, 190f, 300f, 250f),
            initial.resized(InkResizeCorner.TOP_LEFT, 500f, 500f, 800f, 700f, 300f, 250f)
        )
    }
}
