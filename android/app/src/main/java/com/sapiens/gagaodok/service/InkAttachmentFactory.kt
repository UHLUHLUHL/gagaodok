package com.sapiens.gagaodok.service

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.Base64
import com.sapiens.gagaodok.model.AttachmentType
import com.sapiens.gagaodok.model.ChatAttachment
import com.sapiens.gagaodok.model.InkDocument
import kotlin.math.max
import kotlin.math.min

/** PNG는 오직 사용자가 AI 첨부를 요청할 때만 제한된 해상도로 생성합니다. */
object InkAttachmentFactory {
    private const val exportWidth = 1600
    private const val exportHeight = 1200

    fun create(document: InkDocument): ChatAttachment? = runCatching {
        val bitmap = Bitmap.createBitmap(exportWidth, exportHeight, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            canvas.drawColor(Color.WHITE)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeCap = Paint.Cap.ROUND
                strokeJoin = Paint.Join.ROUND
            }
            document.strokes.forEach { stroke ->
                if (stroke.points.isEmpty()) return@forEach
                paint.color = if (stroke.eraser) Color.WHITE else stroke.colorArgb.toInt()
                val points = stroke.points
                if (points.size == 1) {
                    val point = points.single()
                    paint.style = Paint.Style.FILL
                    paint.strokeWidth = 1f
                    paint.color = if (stroke.eraser) Color.WHITE else stroke.colorArgb.toInt()
                    canvas.drawCircle(point.x * exportWidth, point.y * exportHeight, stroke.baseWidth, paint)
                    paint.style = Paint.Style.STROKE
                } else {
                    for (index in 1 until points.size) {
                        val from = points[index - 1]
                        val to = points[index]
                        val pressure = ((from.pressure + to.pressure) / 2f).coerceIn(0.15f, 1f)
                        paint.strokeWidth = max(1.2f, stroke.baseWidth * (0.38f + pressure * 0.62f))
                        canvas.drawLine(
                            from.x * exportWidth,
                            from.y * exportHeight,
                            to.x * exportWidth,
                            to.y * exportHeight,
                            paint
                        )
                    }
                }
            }
            val bytes = java.io.ByteArrayOutputStream().use { output ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                output.toByteArray()
            }
            ChatAttachment(
                type = AttachmentType.IMAGE,
                fileName = "필기-${document.title.take(32)}.png",
                fileSize = bytes.size.toLong(),
                fileExtension = "png",
                dataBase64 = Base64.encodeToString(bytes, Base64.NO_WRAP),
                mimeType = "image/png"
            )
        } finally {
            bitmap.recycle()
        }
    }.getOrNull()
}
