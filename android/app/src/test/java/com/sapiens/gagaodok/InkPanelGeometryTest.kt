package com.sapiens.gagaodok

import androidx.compose.ui.graphics.Color
import com.sapiens.gagaodok.service.InkColorCodec
import com.sapiens.gagaodok.ui.screens.InkPanelBounds
import com.sapiens.gagaodok.ui.screens.InkResizeCorner
import com.sapiens.gagaodok.ui.screens.InkResizeEdge
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

    @Test
    fun `좌우와 아래 변만 잡아도 해당 방향으로 크기를 바꾼다`() {
        val initial = InkPanelBounds(x = 100f, y = 80f, width = 500f, height = 360f)

        assertEquals(
            InkPanelBounds(70f, 80f, 530f, 360f),
            initial.resized(InkResizeEdge.LEFT, -30f, 0f, 800f, 700f, 300f, 250f)
        )
        assertEquals(
            InkPanelBounds(100f, 80f, 540f, 360f),
            initial.resized(InkResizeEdge.RIGHT, 40f, 0f, 800f, 700f, 300f, 250f)
        )
        assertEquals(
            InkPanelBounds(100f, 80f, 500f, 410f),
            initial.resized(InkResizeEdge.BOTTOM, 0f, 50f, 800f, 700f, 300f, 250f)
        )
    }
}
