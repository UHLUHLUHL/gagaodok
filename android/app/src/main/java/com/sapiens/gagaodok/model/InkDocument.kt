package com.sapiens.gagaodok.model

import kotlinx.serialization.Serializable
import java.util.UUID

/** 화면 크기와 독립적인 무한 월드 좌표의 필기 원본입니다. */
@Serializable
data class InkDocument(
    @Serializable(with = UuidSerializer::class)
    val id: UUID = UUID.randomUUID(),
    val roomId: String,
    val title: String = "새 필기",
    val createdAtMillis: Long = System.currentTimeMillis(),
    val updatedAtMillis: Long = System.currentTimeMillis(),
    /** 0은 예전 0..1 정규화 좌표, 1부터는 월드 좌표입니다. */
    val coordinateSpaceVersion: Int = 0,
    val viewport: InkViewport = InkViewport(),
    val strokes: List<InkStroke> = emptyList()
)

@Serializable
data class InkViewport(
    val centerX: Float = 800f,
    val centerY: Float = 600f,
    val zoom: Float = 1f
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
