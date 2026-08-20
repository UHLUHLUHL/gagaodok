package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.model.InkPoint
import kotlin.math.abs
import kotlin.math.hypot

/** 필기 입력 경로에서 객체 생성과 계산을 최소화하기 위한 순수 좌표 규칙입니다. */
object InkStrokeMath {
    private const val minimumNormalizedDistance = 0.0012f
    private const val minimumPressureDelta = 0.075f

    fun normalized(
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        pressure: Float,
        timeMillis: Long = System.currentTimeMillis()
    ): InkPoint = InkPoint(
        x = (x / width.coerceAtLeast(1f)).coerceIn(0f, 1f),
        y = (y / height.coerceAtLeast(1f)).coerceIn(0f, 1f),
        pressure = pressure.coerceIn(0f, 1f),
        timeMillis = timeMillis
    )

    /**
     * 센서의 중복 표본은 버리되, 같은 자리에 머무르며 압력만 바꾼 스트로크는 보존합니다.
     * 이 규칙은 메모리와 draw 호출을 줄이면서 펜 끝의 눌림 변화는 잃지 않게 합니다.
     */
    fun shouldKeep(previous: InkPoint, candidate: InkPoint): Boolean {
        val distance = hypot(
            (candidate.x - previous.x).toDouble(),
            (candidate.y - previous.y).toDouble()
        )
        return distance >= minimumNormalizedDistance ||
            abs(candidate.pressure - previous.pressure) >= minimumPressureDelta
    }
}
