package com.sapiens.gagaodok

import com.sapiens.gagaodok.service.InkDefaults
import com.sapiens.gagaodok.service.InkRenderMode
import com.sapiens.gagaodok.service.InkRenderPolicy
import org.junit.Assert.assertEquals
import org.junit.Test

class InkRenderPolicyTest {
    @Test
    fun `지우개 획은 흰색 덧칠이 아니라 기존 잉크 삭제로 합성한다`() {
        assertEquals(InkRenderMode.CLEAR, InkRenderPolicy.mode(eraser = true))
        assertEquals(InkRenderMode.SOURCE_OVER, InkRenderPolicy.mode(eraser = false))
    }

    @Test
    fun `새 펜 기본 굵기는 3dp를 화면 밀도에 맞춰 저장한다`() {
        assertEquals(3f, InkDefaults.DEFAULT_PEN_WIDTH_DP, 0.001f)
        assertEquals(6f, InkDefaults.widthInWorldPixels(3f, density = 2f), 0.001f)
    }
}
