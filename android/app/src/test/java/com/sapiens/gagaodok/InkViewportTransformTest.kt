package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.InkViewport
import com.sapiens.gagaodok.service.InkPoint2D
import com.sapiens.gagaodok.service.InkViewportTransform
import org.junit.Assert.assertEquals
import org.junit.Test

class InkViewportTransformTest {
    @Test
    fun `월드와 화면 좌표는 왕복해 원래 점으로 돌아온다`() {
        val viewport = InkViewport(800f, 600f, 2f)
        val size = InkPoint2D(1000f, 700f)
        val world = InkPoint2D(900f, 650f)

        val screen = InkViewportTransform.worldToScreen(world, viewport, size)
        val restored = InkViewportTransform.screenToWorld(screen, viewport, size)

        assertPoint(world, restored)
        assertPoint(InkPoint2D(700f, 450f), screen)
    }

    @Test
    fun `화면 이동량은 확대율로 나눈 월드 이동량이 된다`() {
        val moved = InkViewportTransform.pan(InkViewport(800f, 600f, 2f), 100f, -40f)

        assertEquals(750f, moved.centerX, 0.001f)
        assertEquals(620f, moved.centerY, 0.001f)
    }

    @Test
    fun `확대 초점의 월드 좌표는 화면의 같은 위치에 남는다`() {
        val size = InkPoint2D(1000f, 700f)
        val focal = InkPoint2D(300f, 200f)
        val before = InkViewport(800f, 600f, 1f)
        val focalWorld = InkViewportTransform.screenToWorld(focal, before, size)

        val after = InkViewportTransform.zoomAt(before, 2f, focal, size)

        assertPoint(focalWorld, InkViewportTransform.screenToWorld(focal, after, size))
        assertEquals(2f, after.zoom, 0.001f)
    }

    @Test
    fun `확대율과 호버 지름은 안전 범위를 지킨다`() {
        assertEquals(8f, InkViewportTransform.zoomAt(InkViewport(zoom = 4f), 10f, InkPoint2D(0f, 0f), InkPoint2D(100f, 100f)).zoom, 0.001f)
        assertEquals(0.2f, InkViewportTransform.zoomAt(InkViewport(zoom = 1f), 0.01f, InkPoint2D(0f, 0f), InkPoint2D(100f, 100f)).zoom, 0.001f)
        assertEquals(36f, InkViewportTransform.hoverDiameter(18f, 2f), 0.001f)
    }

    private fun assertPoint(expected: InkPoint2D, actual: InkPoint2D) {
        assertEquals(expected.x, actual.x, 0.001f)
        assertEquals(expected.y, actual.y, 0.001f)
    }
}
