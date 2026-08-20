package com.sapiens.gagaodok.service

enum class InkRenderMode { SOURCE_OVER, CLEAR }

object InkRenderPolicy {
    fun mode(eraser: Boolean): InkRenderMode =
        if (eraser) InkRenderMode.CLEAR else InkRenderMode.SOURCE_OVER
}

object InkDefaults {
    const val DEFAULT_PEN_WIDTH_DP = 3f
    const val DEFAULT_ERASER_WIDTH_DP = 18f

    fun widthInWorldPixels(widthDp: Float, density: Float): Float =
        widthDp.coerceAtLeast(0f) * density.coerceAtLeast(0f)
}
