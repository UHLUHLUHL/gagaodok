package com.sapiens.gagaodok.service

import android.view.MotionEvent

enum class InkGestureIntent {
    STROKE,
    PAN,
    PAN_ZOOM,
    HOVER,
    IGNORE
}

object InkGestureRouter {
    fun classify(action: Int, toolTypes: IntArray, pointerCount: Int): InkGestureIntent {
        val tools = toolTypes.take(pointerCount.coerceAtMost(toolTypes.size))
        val stylusPresent = tools.any {
            it == MotionEvent.TOOL_TYPE_STYLUS || it == MotionEvent.TOOL_TYPE_ERASER
        }
        if (action == MotionEvent.ACTION_HOVER_ENTER ||
            action == MotionEvent.ACTION_HOVER_MOVE ||
            action == MotionEvent.ACTION_HOVER_EXIT
        ) return if (stylusPresent) InkGestureIntent.HOVER else InkGestureIntent.IGNORE

        if (stylusPresent) return InkGestureIntent.STROKE
        val fingers = tools.count { it == MotionEvent.TOOL_TYPE_FINGER }
        return when {
            pointerCount >= 2 && fingers == pointerCount -> InkGestureIntent.PAN_ZOOM
            pointerCount == 1 && fingers == 1 -> InkGestureIntent.PAN
            else -> InkGestureIntent.IGNORE
        }
    }
}
