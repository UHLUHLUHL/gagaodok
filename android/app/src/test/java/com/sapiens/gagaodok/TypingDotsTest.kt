package com.sapiens.gagaodok

import com.sapiens.gagaodok.ui.screens.typingDotLift
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// 입력 중 점 세 개가 실제로 움직이는지 봅니다.
///
/// 화면으로만 확인하면 "원래 안 움직이는 건가" 싶어 그냥 넘어가기 쉬운 자리라
/// 값으로 못 박아 둡니다.
class TypingDotsTest {

    @Test
    fun `세 점이 같은 순간에 서로 다른 높이에 있다`() {
        val lifts = (0..2).map { typingDotLift(0.3f, it) }
        assertTrue("첫 점이 떠 있어야 합니다", lifts[0] > 0.5f)
        assertEquals("나머지는 아직 바닥입니다", 0f, lifts[1], 1e-6f)
        assertEquals(0f, lifts[2], 1e-6f)
    }

    @Test
    fun `점 하나가 한 바퀴 도는 동안 떴다 가라앉는다`() {
        val samples = (0..20).map { typingDotLift(it * 3f / 20f, 0) }
        assertTrue("어느 순간에는 거의 꼭대기까지 떠야 합니다", samples.max() > 0.95f)
        assertEquals("바닥에 닿는 순간도 있어야 합니다", 0f, samples.min(), 1e-6f)
    }

    @Test
    fun `차례가 하나씩 밀린다`() {
        // 위상이 1만큼 갈 때 둘째 점은 첫째 점이 방금 있던 자리에 온다.
        for (p in listOf(0.1f, 0.25f, 0.4f, 0.5f)) {
            assertEquals(typingDotLift(p, 0), typingDotLift(p + 1f, 1), 1e-5f)
        }
    }

    @Test
    fun `위상은 세 바퀴마다 제자리로 돌아온다`() {
        for (i in 0..2) {
            assertEquals(typingDotLift(0.7f, i), typingDotLift(3.7f, i), 1e-5f)
        }
    }

    @Test
    fun `높이는 항상 0과 1 사이다`() {
        for (step in 0..300) {
            val p = step * 3f / 300f
            for (i in 0..2) {
                val v = typingDotLift(p, i)
                assertTrue("0 아래로 내려가면 안 됩니다: $v", v >= 0f)
                assertTrue("1 위로 올라가면 안 됩니다: $v", v <= 1.0001f)
            }
        }
    }
}
