package com.sapiens.gagaodok

import com.sapiens.gagaodok.service.splitMentorTextAndComplexMath
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MentorBubbleChunkerTest {

    @Test
    fun `멘토 블록 수식은 빈 줄과 tight delimiter가 있어도 한 말풍선이다`() {
        val response = """
            풀이를 정리하면,

            ${'$'}${'$'}\begin{aligned}
            g''(x) &= \frac{d}{dx}\left[(1+g(x)^3)^{\frac12}\right] \\

            &= \frac32 g(x)^2 g'(x)
            \end{aligned}${'$'}${'$'}

            따라서 정답은 ④번입니다.
        """.trimIndent()

        val chunks = splitMentorTextAndComplexMath(response)

        assertEquals(3, chunks.size)
        assertTrue(chunks[1].startsWith("${'$'}${'$'}\\begin{aligned}"))
        assertTrue(chunks[1].endsWith("\\end{aligned}${'$'}${'$'}"))
        assertTrue(chunks[1].contains("\n\n"))
    }
}
