package com.sapiens.gagaodok.model

import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * 화면 크기와 분할 화면 여부에 영향을 받지 않는 필기 원본입니다.
 *
 * 점은 0..1 좌표계로 저장하고, 화면에 그릴 때만 현재 패널 크기로 환산합니다. 따라서
 * PNG를 매번 보관하거나 패널을 늘릴 때마다 비트맵을 복제할 필요가 없습니다.
 */
@Serializable
data class InkDocument(
    @Serializable(with = UuidSerializer::class)
    val id: UUID = UUID.randomUUID(),
    val roomId: String,
    val title: String = "새 필기",
    val createdAtMillis: Long = System.currentTimeMillis(),
    val updatedAtMillis: Long = System.currentTimeMillis(),
    val strokes: List<InkStroke> = emptyList()
)

@Serializable
data class InkStroke(
    @Serializable(with = UuidSerializer::class)
    val id: UUID = UUID.randomUUID(),
    val colorArgb: Long,
    /** 논리 픽셀 기준 굵기입니다. 실제 출력에서는 현재 밀도를 적용합니다. */
    val baseWidth: Float,
    /** 지우개는 흰 바탕을 그리는 별도 벡터 스트로크로 보관합니다. */
    val eraser: Boolean = false,
    val points: List<InkPoint>
)

@Serializable
data class InkPoint(
    val x: Float,
    val y: Float,
    /** Android stylus pressure를 0..1로 정규화한 값입니다. */
    val pressure: Float,
    val timeMillis: Long
)
