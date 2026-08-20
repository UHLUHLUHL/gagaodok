package com.sapiens.gagaodok.service

import android.view.MotionEvent

/** 스타일러스 종류와 측면 버튼을 한 스트로크의 펜/지우개 모드로 해석합니다. */
object InkInputMode {
    data class StrokeStyle(
        val colorArgb: Long,
        val width: Float,
        val eraser: Boolean
    )

    fun shouldErase(toolType: Int, buttonState: Int, toolbarEraser: Boolean): Boolean {
        val sideButtonMask = MotionEvent.BUTTON_STYLUS_PRIMARY or MotionEvent.BUTTON_STYLUS_SECONDARY
        val stylusSideButton = toolType == MotionEvent.TOOL_TYPE_STYLUS && buttonState and sideButtonMask != 0
        return toolbarEraser || toolType == MotionEvent.TOOL_TYPE_ERASER || stylusSideButton
    }

    fun resolveStrokeStyle(
        toolType: Int,
        buttonState: Int,
        toolbarEraser: Boolean,
        colorArgb: Long,
        width: Float
    ) = StrokeStyle(
        colorArgb = colorArgb,
        width = width,
        eraser = shouldErase(toolType, buttonState, toolbarEraser)
    )
}
