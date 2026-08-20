package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.InkPoint
import com.sapiens.gagaodok.model.InkStroke
import com.sapiens.gagaodok.service.InkExportGeometry
import com.sapiens.gagaodok.service.InkPixelSize
import com.sapiens.gagaodok.service.InkWorldRect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InkExportGeometryTest {
    @Test
    fun `한 점 획 경계는 굵기의 절반만큼 확장된다`() {
        val bounds = InkExportGeometry.candidateBounds(
            listOf(stroke(width = 20f, points = listOf(InkPoint(50f, 40f, .5f, 0L))))
        )

        assertEquals(InkWorldRect(40f, 30f, 60f, 50f), bounds)
    }

    @Test
    fun `지우개만 있으면 출력 후보가 없다`() {
        assertNull(
            InkExportGeometry.candidateBounds(
                listOf(stroke(width = 30f, eraser = true, points = listOf(InkPoint(10f, 10f, .5f, 0L))))
            )
        )
    }

    @Test
    fun `보통 필기는 짧은 변 1600을 확보하고 긴 변은 4096을 넘지 않는다`() {
        assertEquals(
            InkPixelSize(3200, 1600),
            InkExportGeometry.outputSize(InkWorldRect(0f, 0f, 200f, 100f))
        )
        val extreme = InkExportGeometry.outputSize(InkWorldRect(0f, 0f, 10000f, 100f))
        assertEquals(4096, extreme.width)
        assertTrue(extreme.height >= 1)
    }

    @Test
    fun `출력 굵기는 필압과 무관하다`() {
        assertEquals(20f, InkExportGeometry.outputStrokeWidth(10f, 2f, .1f), .001f)
        assertEquals(20f, InkExportGeometry.outputStrokeWidth(10f, 2f, 1f), .001f)
    }

    private fun stroke(
        width: Float,
        eraser: Boolean = false,
        points: List<InkPoint>
    ) = InkStroke(
        colorArgb = 0xFF191919,
        baseWidth = width,
        eraser = eraser,
        points = points
    )
}
