package com.sapiens.gagaodok.service

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb

/** Compose가 저장한 64비트 색상을 Android Bitmap용 ARGB로 변환합니다. */
object InkColorCodec {
    fun toArgb(storedColor: Long): Int = Color(storedColor.toULong()).toArgb()
}
