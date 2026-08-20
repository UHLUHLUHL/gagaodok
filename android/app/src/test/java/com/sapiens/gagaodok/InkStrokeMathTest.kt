package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.InkPoint
import com.sapiens.gagaodok.model.InkViewport
import com.sapiens.gagaodok.service.InkPoint2D
import com.sapiens.gagaodok.service.InkStrokeMath
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InkStrokeMathTest {

    @Test
    fun `화면 입력은 현재 뷰포트의 월드 좌표로 저장한다`() {
        val point = InkStrokeMath.worldPoint(
            x = 500f,
            y = 350f,
            viewport = InkViewport(centerX = 800f, centerY = 600f, zoom = 2f),
            surfaceSize = InkPoint2D(1000f, 700f),
            pressure = 0.7f
        )

        assertEquals(800f, point.x, 0.0001f)
        assertEquals(600f, point.y, 0.0001f)
        assertEquals(0.7f, point.pressure, 0.0001f)
    }

    @Test
    fun `월드 좌표는 패널 밖으로도 이어지고 압력만 호환 범위로 제한한다`() {
        val point = InkStrokeMath.worldPoint(
            x = -100f,
            y = 900f,
            viewport = InkViewport(),
            surfaceSize = InkPoint2D(300f, 400f),
            pressure = 4f
        )

        assertEquals(550f, point.x, 0.0001f)
        assertEquals(1300f, point.y, 0.0001f)
        assertEquals(1f, point.pressure, 0.0001f)
    }

    @Test
    fun `너무 촘촘한 같은 압력 포인트는 그리지 않는다`() {
        val previous = InkPoint(0.5f, 0.5f, 0.6f, 0L)
        val near = InkPoint(0.5001f, 0.5001f, 0.61f, 1L)

        assertFalse(InkStrokeMath.shouldKeep(previous, near, zoom = 1f))
    }

    @Test
    fun `고정 굵기에서는 압력 변화만 있는 포인트를 버린다`() {
        val previous = InkPoint(0.5f, 0.5f, 0.2f, 0L)
        val pressureChange = InkPoint(0.5001f, 0.5001f, 0.9f, 1L)

        assertFalse(InkStrokeMath.shouldKeep(previous, pressureChange, zoom = 1f))
    }

    @Test
    fun `확대 상태에서는 더 촘촘한 월드 표본을 보존한다`() {
        val previous = InkPoint(10f, 10f, 0.5f, 0L)
        val candidate = InkPoint(10.6f, 10f, 0.5f, 1L)

        assertFalse(InkStrokeMath.shouldKeep(previous, candidate, zoom = 1f))
        assertTrue(InkStrokeMath.shouldKeep(previous, candidate, zoom = 2f))
    }
}
