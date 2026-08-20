package com.sapiens.gagaodok.service

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.util.Base64
import com.sapiens.gagaodok.model.AttachmentType
import com.sapiens.gagaodok.model.ChatAttachment
import com.sapiens.gagaodok.model.InkDocument
import com.sapiens.gagaodok.model.InkPoint
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.min

/** 무한 벡터 문서를 남아 있는 내용 경계만큼 고해상도 PNG로 만듭니다. */
object InkAttachmentFactory {
    private const val renderMarginPixels = 64f
    private const val cropMarginPixels = 48
    private val clearMode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)

    fun create(document: InkDocument): ChatAttachment? = runCatching {
        val bounds = InkExportGeometry.candidateBounds(document.strokes) ?: return null
        val outputSize = InkExportGeometry.outputSize(bounds)
        val transform = InkExportGeometry.transform(bounds, outputSize, renderMarginPixels)
        val layer = Bitmap.createBitmap(outputSize.width, outputSize.height, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(layer)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeCap = Paint.Cap.ROUND
                strokeJoin = Paint.Join.ROUND
            }
            document.strokes.forEach { stroke ->
                if (stroke.points.isEmpty()) return@forEach
                paint.color = InkColorCodec.toArgb(stroke.colorArgb)
                paint.strokeWidth = InkExportGeometry.outputStrokeWidth(
                    stroke.baseWidth,
                    transform.scale,
                    stroke.points.first().pressure
                )
                paint.xfermode = if (stroke.eraser) clearMode else null
                drawStroke(canvas, paint, stroke.points, transform)
            }
            paint.xfermode = null

            val content = nonTransparentBounds(layer) ?: return null
            val left = max(0, content.left - cropMarginPixels)
            val top = max(0, content.top - cropMarginPixels)
            val right = min(layer.width, content.right + cropMarginPixels + 1)
            val bottom = min(layer.height, content.bottom + cropMarginPixels + 1)

            canvas.drawColor(Color.WHITE, PorterDuff.Mode.DST_OVER)
            val cropped = if (left == 0 && top == 0 && right == layer.width && bottom == layer.height) {
                layer
            } else {
                Bitmap.createBitmap(layer, left, top, right - left, bottom - top)
            }
            try {
                val bytes = ByteArrayOutputStream().use { output ->
                    check(cropped.compress(Bitmap.CompressFormat.PNG, 100, output))
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
                if (cropped !== layer) cropped.recycle()
            }
        } finally {
            layer.recycle()
        }
    }.getOrNull()

    private fun drawStroke(
        canvas: Canvas,
        paint: Paint,
        points: List<InkPoint>,
        transform: InkOutputTransform
    ) {
        if (points.size == 1) {
            val point = points.single()
            paint.style = Paint.Style.FILL
            canvas.drawCircle(transform.x(point.x), transform.y(point.y), paint.strokeWidth / 2f, paint)
            paint.style = Paint.Style.STROKE
            return
        }
        val path = Path().apply {
            val first = points.first()
            moveTo(transform.x(first.x), transform.y(first.y))
            if (points.size == 2) {
                val last = points.last()
                lineTo(transform.x(last.x), transform.y(last.y))
            } else {
                for (index in 1 until points.lastIndex) {
                    val current = points[index]
                    val next = points[index + 1]
                    val currentX = transform.x(current.x)
                    val currentY = transform.y(current.y)
                    val nextX = transform.x(next.x)
                    val nextY = transform.y(next.y)
                    quadTo(currentX, currentY, (currentX + nextX) / 2f, (currentY + nextY) / 2f)
                }
                val last = points.last()
                lineTo(transform.x(last.x), transform.y(last.y))
            }
        }
        canvas.drawPath(path, paint)
    }

    private data class PixelBounds(val left: Int, val top: Int, val right: Int, val bottom: Int)

    /** 전체 픽셀 배열을 만들지 않고 한 줄 버퍼만 재사용해 최대 해상도에서도 메모리를 제한합니다. */
    private fun nonTransparentBounds(bitmap: Bitmap): PixelBounds? {
        val row = IntArray(bitmap.width)
        var left = bitmap.width
        var top = bitmap.height
        var right = -1
        var bottom = -1
        for (y in 0 until bitmap.height) {
            bitmap.getPixels(row, 0, bitmap.width, 0, y, bitmap.width, 1)
            for (x in row.indices) {
                if (Color.alpha(row[x]) <= 8) continue
                if (x < left) left = x
                if (x > right) right = x
                if (y < top) top = y
                if (y > bottom) bottom = y
            }
        }
        return if (right < left || bottom < top) null else PixelBounds(left, top, right, bottom)
    }
}
