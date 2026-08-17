package com.sapiens.gagaodok

import com.sapiens.gagaodok.service.ImageBudget
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// 사진을 얼마로 줄여 보낼지 정하는 계산입니다.
///
/// 요금이 화소가 아니라 **타일 수**에 비례하므로, "적당히 줄였다"가 곧
/// "돈을 아꼈다"는 뜻이 아닙니다. 그 어긋남을 여기서 붙잡습니다.
class ImageBudgetTest {

    @Test
    fun `예전 방식이 왜 타일을 버렸는지`() {
        // 긴 변만 1600으로 맞추던 시절: 4:3 사진이 1600×1200이 됩니다.
        // 1600 ÷ 768 = 2.08이라 세 번째 세로 타일이 생기는데, 거기 실린 그림은
        // 폭 64화소뿐입니다. 요금은 다른 타일과 똑같이 냅니다.
        assertEquals(6, ImageBudget.tiles(1600, 1200))
        assertEquals(4, ImageBudget.tiles(1536, 1152))
    }

    @Test
    fun `흔한 4대3 사진은 두 타일로 들어간다`() {
        val plan = ImageBudget.plan(4032, 3024)
        assertEquals(2, plan.tiles)
        assertEquals(1024, plan.width)
        assertEquals(768, plan.height)
        // 예전 1,548토큰에서 516토큰으로 3분의 1입니다.
        assertEquals(516, plan.tokens)
    }

    @Test
    fun `세로 사진도 같은 값이 나온다`() {
        val plan = ImageBudget.plan(3024, 4032)
        assertEquals(2, plan.tiles)
        assertEquals(768, plan.width)
        assertEquals(1024, plan.height)
    }

    @Test
    fun `줄인 결과가 타일 격자를 넘지 않는다`() {
        // 반올림 한 번에 타일이 하나 더 생깁니다. 그래서 내림으로 자릅니다.
        for (w in listOf(4032, 3000, 2500, 1999, 1601, 1440)) {
            for (h in listOf(3024, 2000, 1800, 1200, 901)) {
                val plan = ImageBudget.plan(w, h)
                assertEquals(
                    "격자를 넘었습니다: ${w}x$h → ${plan.width}x${plan.height}",
                    plan.tiles,
                    ImageBudget.tiles(plan.width, plan.height)
                )
            }
        }
    }

    @Test
    fun `읽을 수 있을 만큼은 남긴다`() {
        // 타일 하나까지 줄이면 긴 변이 768이 되어 작은 글씨가 뭉갭니다.
        for (w in listOf(4032, 3000, 2000)) {
            val plan = ImageBudget.plan(w, w * 3 / 4)
            assertTrue(
                "너무 작습니다: ${plan.width}x${plan.height}",
                maxOf(plan.width, plan.height) >= ImageBudget.MIN_LONG_SIDE
            )
        }
    }

    @Test
    fun `작은 사진은 건드리지 않는다`() {
        // 키우면 타일만 늘고 보이는 것은 그대로입니다.
        val plan = ImageBudget.plan(600, 400)
        assertEquals(600, plan.width)
        assertEquals(400, plan.height)
        assertEquals(1, plan.tiles)
    }

    @Test
    fun `줄일수록 타일이 늘지는 않는다`() {
        val before = ImageBudget.tiles(4032, 3024)
        val after = ImageBudget.plan(4032, 3024).tiles
        assertTrue("줄였는데 타일이 늘었습니다", after <= before)
    }

    @Test
    fun `읽어들일 배율은 목표보다 작아지지 않는다`() {
        val target = ImageBudget.plan(4032, 3024)
        val sample = ImageBudget.sampleSize(4032, 3024, target)
        assertTrue(4032 / sample >= target.width)
        assertTrue(3024 / sample >= target.height)
        // 2의 거듭제곱이어야 합니다.
        assertEquals(0, sample and (sample - 1))
    }

    @Test
    fun `크기를 못 읽어도 터지지 않는다`() {
        val plan = ImageBudget.plan(0, 0)
        assertEquals(1, plan.tiles)
    }
}
