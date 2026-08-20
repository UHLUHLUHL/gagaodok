package com.sapiens.gagaodok

import com.sapiens.gagaodok.ui.screens.ElasticTrackGeometry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class InkElasticSliderTest {
    @Test
    fun `현재 위치의 두꺼운 부분은 양쪽 트랙과 겹쳐 빈틈이 없다`() {
        val geometry = ElasticTrackGeometry.calculate(
            width = 200f,
            height = 38f,
            progress = .5f,
            directionalStretch = 1f
        )

        assertTrue(geometry.blobLeft < geometry.centerX)
        assertTrue(geometry.blobRight > geometry.centerX)
        assertTrue(geometry.activeTrackRight >= geometry.blobLeft)
        assertTrue(geometry.inactiveTrackLeft <= geometry.blobRight)
        assertTrue(geometry.blobHeight > geometry.trackHeight)
    }

    @Test
    fun `진행률과 변형은 유효 범위로 제한한다`() {
        val left = ElasticTrackGeometry.calculate(100f, 30f, -3f, -5f)
        val right = ElasticTrackGeometry.calculate(100f, 30f, 4f, 5f)

        assertEquals(left.startX, left.centerX, 0.001f)
        assertEquals(right.endX, right.centerX, 0.001f)
        assertTrue(left.blobWidth <= 40f)
        assertTrue(right.blobWidth <= 40f)
    }
}
