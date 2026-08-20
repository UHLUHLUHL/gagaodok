package com.sapiens.gagaodok

import android.view.MotionEvent
import com.sapiens.gagaodok.service.InkGestureIntent
import com.sapiens.gagaodok.service.InkGestureRouter
import org.junit.Assert.assertEquals
import org.junit.Test

class InkGestureRouterTest {
    @Test
    fun `스타일러스만 스트로크로 분류한다`() {
        assertEquals(InkGestureIntent.STROKE, classify(MotionEvent.ACTION_DOWN, MotionEvent.TOOL_TYPE_STYLUS))
        assertEquals(InkGestureIntent.STROKE, classify(MotionEvent.ACTION_MOVE, MotionEvent.TOOL_TYPE_ERASER))
        assertEquals(InkGestureIntent.PAN, classify(MotionEvent.ACTION_DOWN, MotionEvent.TOOL_TYPE_FINGER))
        assertEquals(InkGestureIntent.IGNORE, classify(MotionEvent.ACTION_DOWN, MotionEvent.TOOL_TYPE_UNKNOWN))
    }

    @Test
    fun `두 손가락은 이동 확대이고 획을 만들지 않는다`() {
        assertEquals(
            InkGestureIntent.PAN_ZOOM,
            InkGestureRouter.classify(
                action = MotionEvent.ACTION_MOVE,
                toolTypes = intArrayOf(MotionEvent.TOOL_TYPE_FINGER, MotionEvent.TOOL_TYPE_FINGER),
                pointerCount = 2
            )
        )
    }

    @Test
    fun `스타일러스 호버는 접촉과 별도 상태로 분류한다`() {
        assertEquals(InkGestureIntent.HOVER, classify(MotionEvent.ACTION_HOVER_ENTER, MotionEvent.TOOL_TYPE_STYLUS))
        assertEquals(InkGestureIntent.HOVER, classify(MotionEvent.ACTION_HOVER_MOVE, MotionEvent.TOOL_TYPE_STYLUS))
        assertEquals(InkGestureIntent.HOVER, classify(MotionEvent.ACTION_HOVER_EXIT, MotionEvent.TOOL_TYPE_STYLUS))
    }

    private fun classify(action: Int, toolType: Int) = InkGestureRouter.classify(
        action = action,
        toolTypes = intArrayOf(toolType),
        pointerCount = 1
    )
}
