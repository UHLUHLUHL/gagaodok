package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.InkPoint
import com.sapiens.gagaodok.service.InkStrokeMath
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InkStrokeMathTest {

    @Test
    fun `필기 좌표는 패널 크기와 무관하게 정규화한다`() {
        val point = InkStrokeMath.normalized(x = 300f, y = 225f, width = 600f, height = 450f, pressure = 0.7f)

        assertEquals(0.5f, point.x, 0.0001f)
        assertEquals(0.5f, point.y, 0.0001f)
        assertEquals(0.7f, point.pressure, 0.0001f)
    }

    @Test
    fun `패널 밖 좌표와 압력은 안전한 범위로 제한한다`() {
        val point = InkStrokeMath.normalized(x = -12f, y = 900f, width = 300f, height = 400f, pressure = 4f)

        assertEquals(0f, point.x, 0.0001f)
        assertEquals(1f, point.y, 0.0001f)
        assertEquals(1f, point.pressure, 0.0001f)
    }

    @Test
    fun `너무 촘촘한 같은 압력 포인트는 그리지 않는다`() {
        val previous = InkPoint(0.5f, 0.5f, 0.6f, 0L)
        val near = InkPoint(0.5001f, 0.5001f, 0.61f, 1L)

        assertFalse(InkStrokeMath.shouldKeep(previous, near))
    }

    @Test
    fun `같은 위치여도 압력 변화는 보존한다`() {
        val previous = InkPoint(0.5f, 0.5f, 0.2f, 0L)
        val pressureChange = InkPoint(0.5001f, 0.5001f, 0.9f, 1L)

        assertTrue(InkStrokeMath.shouldKeep(previous, pressureChange))
    }
}
