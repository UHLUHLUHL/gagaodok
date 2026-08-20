package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.model.InkPoint
import com.sapiens.gagaodok.model.InkViewport
import kotlin.math.hypot

/** 필기 입력 경로에서 객체 생성과 계산을 최소화하기 위한 순수 좌표 규칙입니다. */
object InkStrokeMath {
    private const val minimumScreenDistance = 0.9f

    fun worldPoint(
        x: Float,
        y: Float,
        viewport: InkViewport,
        surfaceSize: InkPoint2D,
        pressure: Float,
        timeMillis: Long = System.currentTimeMillis()
    ): InkPoint {
        val world = InkViewportTransform.screenToWorld(InkPoint2D(x, y), viewport, surfaceSize)
        return InkPoint(
            x = world.x,
            y = world.y,
            pressure = pressure.coerceIn(0f, 1f),
            timeMillis = timeMillis
        )
    }

    /**
     * 화면에서 1px보다 가까운 중복 표본은 버립니다. 고정 굵기라 압력 변화만으로는
     * 새 점을 추가하지 않습니다.
     */
    fun shouldKeep(previous: InkPoint, candidate: InkPoint, zoom: Float): Boolean {
        val distance = hypot(
            (candidate.x - previous.x).toDouble(),
            (candidate.y - previous.y).toDouble()
        )
        return distance >= minimumScreenDistance / zoom.coerceAtLeast(InkViewportTransform.MIN_ZOOM)
    }

}
