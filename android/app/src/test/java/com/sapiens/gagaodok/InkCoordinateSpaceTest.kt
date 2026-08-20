package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.InkDocument
import com.sapiens.gagaodok.model.InkPoint
import com.sapiens.gagaodok.model.InkStroke
import com.sapiens.gagaodok.model.InkViewport
import com.sapiens.gagaodok.service.InkCoordinateSpace
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class InkCoordinateSpaceTest {
    @Test
    fun `버전 없는 정규화 좌표를 기본 월드 캔버스로 한 번 변환한다`() {
        val old = document(
            version = 0,
            points = listOf(InkPoint(0.5f, 0.25f, 0.9f, 1L))
        )

        val migrated = InkCoordinateSpace.toCurrent(old)
        val point = migrated.strokes.single().points.single()

        assertEquals(1, migrated.coordinateSpaceVersion)
        assertEquals(800f, point.x, 0.001f)
        assertEquals(300f, point.y, 0.001f)
        assertEquals(4.5f, migrated.strokes.single().baseWidth, 0.001f)
    }

    @Test
    fun `이미 변환된 문서는 다시 확대하지 않는다`() {
        val current = document(
            version = 1,
            points = listOf(InkPoint(800f, 300f, 0.5f, 1L))
        )

        assertEquals(current, InkCoordinateSpace.toCurrent(current))
    }

    @Test
    fun `레거시 dp 굵기는 기기 밀도를 적용해 월드 픽셀 굵기로 변환한다`() {
        val old = document(
            version = 0,
            points = listOf(InkPoint(0.5f, 0.25f, 0.5f, 1L))
        )

        val migrated = InkCoordinateSpace.toCurrent(old, legacyDensity = 2f)

        assertEquals(9f, migrated.strokes.single().baseWidth, 0.001f)
    }

    @Test
    fun `비정상 뷰포트와 좌표는 유한한 기본값으로 복구한다`() {
        val broken = document(
            version = 1,
            viewport = InkViewport(Float.NaN, Float.POSITIVE_INFINITY, 0f),
            points = listOf(InkPoint(Float.NaN, Float.NEGATIVE_INFINITY, 2f, 1L))
        )

        val repaired = InkCoordinateSpace.toCurrent(broken)

        assertTrue(repaired.viewport.centerX.isFinite())
        assertTrue(repaired.viewport.centerY.isFinite())
        assertTrue(repaired.viewport.zoom.isFinite())
        assertTrue(repaired.viewport.zoom > 0f)
        assertTrue(repaired.strokes.single().points.all { it.x.isFinite() && it.y.isFinite() })
    }

    private fun document(
        version: Int,
        viewport: InkViewport = InkViewport(),
        points: List<InkPoint>
    ) = InkDocument(
        roomId = "room",
        coordinateSpaceVersion = version,
        viewport = viewport,
        strokes = listOf(
            InkStroke(
                colorArgb = 0xFF191919,
                baseWidth = 4.5f,
                points = points
            )
        )
    )
}
