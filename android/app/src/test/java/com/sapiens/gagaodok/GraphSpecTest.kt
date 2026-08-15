package com.sapiens.gagaodok

import com.sapiens.gagaodok.service.MathGraphSpec
import com.sapiens.gagaodok.service.MathGraphRenderer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// 그래프 태그를 읽는 부분만 시험합니다.
///
/// 실제로 그리는 부분은 안드로이드 `Canvas`를 쓰므로 여기서는 돌지 않습니다.
/// 대신 "그릴 수 있는 식인지"를 여기서 확실히 가려 둡니다. 해석하지 못한 식을
/// 조용히 다른 그래프로 그리는 것이 가장 나쁜 실패이기 때문입니다.
class GraphSpecTest {

    @Test
    fun `태그를 읽고 본문에서 걷어낸다`() {
        val text = "아래를 보세요.\n[GRAPH: type=cartesian, func=sin(x), xmin=-6.28, xmax=6.28, title=\"y = sin(x)\"]"
        val (cleaned, specs) = MathGraphRenderer.extractGraphSpecs(text)
        assertEquals("아래를 보세요.", cleaned)
        assertEquals(1, specs.size)
        assertEquals(MathGraphSpec.Type.CARTESIAN, specs[0].type)
        assertEquals("sin(x)", specs[0].yExpr)
        assertEquals("y = sin(x)", specs[0].title)
        assertEquals(-6.28, specs[0].xMin, 1e-9)
    }

    @Test
    fun `매개변수 곡선도 읽는다`() {
        val text = "[GRAPH: type=parametric, x=t*cos(t), y=t*sin(t), tmin=0, tmax=6.28]"
        val (_, specs) = MathGraphRenderer.extractGraphSpecs(text)
        assertEquals(MathGraphSpec.Type.PARAMETRIC, specs[0].type)
        assertEquals("t*cos(t)", specs[0].xExpr)
        assertEquals("t*sin(t)", specs[0].yExpr)
    }

    @Test
    fun `접선과 접점을 읽는다`() {
        val text = "[GRAPH: func=x^2, slope=2, point=1:1]"
        val (_, specs) = MathGraphRenderer.extractGraphSpecs(text)
        assertEquals(2.0, specs[0].tangentSlope!!, 1e-9)
        assertEquals(1.0, specs[0].tangentPointX!!, 1e-9)
        assertEquals(1.0, specs[0].tangentPointY!!, 1e-9)
    }

    @Test
    fun `해석하지 못하는 식은 그리지 않는다`() {
        // 틀린 그래프를 조용히 내보내는 것보다 아무것도 안 그리는 편이 낫습니다.
        assertFalse(MathGraphRenderer.canRender(MathGraphSpec(yExpr = "foo(x)")))
        assertFalse(MathGraphRenderer.canRender(MathGraphSpec(yExpr = "sin(x")))
        assertTrue(MathGraphRenderer.canRender(MathGraphSpec(yExpr = "sin(x)")))
    }

    @Test
    fun `정의역이 통째로 비면 그리지 않는다`() {
        // 표시 구간 어디에서도 값이 없으면 빈 판만 나옵니다.
        assertFalse(
            MathGraphRenderer.canRender(
                MathGraphSpec(yExpr = "ln(x)", xMin = -10.0, xMax = -1.0)
            )
        )
    }

    @Test
    fun `태그가 없으면 본문을 건드리지 않는다`() {
        val text = "그냥 평범한 답변입니다."
        val (cleaned, specs) = MathGraphRenderer.extractGraphSpecs(text)
        assertEquals(text, cleaned)
        assertTrue(specs.isEmpty())
    }
}
