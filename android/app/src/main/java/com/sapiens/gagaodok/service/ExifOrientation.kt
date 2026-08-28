package com.sapiens.gagaodok.service

/** Pure EXIF-orientation mapping kept separate from Android bitmap APIs. */
object ExifOrientation {
    data class Size(val width: Int, val height: Int)

    data class Transform(
        val rotationDegrees: Int,
        val flipHorizontal: Boolean
    ) {
        fun orientedSize(width: Int, height: Int): Size =
            if (rotationDegrees == 90 || rotationDegrees == 270) Size(height, width)
            else Size(width, height)
    }

    fun transform(orientation: Int): Transform = when (orientation) {
        2 -> Transform(0, true)
        3 -> Transform(180, false)
        4 -> Transform(180, true)
        5 -> Transform(90, true)
        6 -> Transform(90, false)
        7 -> Transform(270, true)
        8 -> Transform(270, false)
        else -> Transform(0, false)
    }
}
