package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.ui.components.PersonaLoadingStage
import com.sapiens.gagaodok.ui.components.PersonaSignalFrame
import com.sapiens.gagaodok.ui.components.personaLoadingPresentation
import com.sapiens.gagaodok.ui.components.personaSignalFrame
import com.sapiens.gagaodok.ui.components.shouldUsePersonaLoadingSignal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PersonaLoadingPresentationTest {

    @Test
    fun `조사는 실제로 도착한 절에 맞는 단계를 보여준다`() {
        assertEquals(
            PersonaLoadingStage.SOURCE,
            personaLoadingPresentation("lookup", null)?.stage
        )
        assertEquals(
            PersonaLoadingStage.VERIFY,
            personaLoadingPresentation("lookup", "찾은 자료를 살펴보고 있습니다…")?.stage
        )
        assertEquals(
            PersonaLoadingStage.COLLECT,
            personaLoadingPresentation("lookup", "대사를 모으고 있습니다… 12줄")?.stage
        )
        assertEquals(
            PersonaLoadingStage.SYNTHESIZE,
            personaLoadingPresentation("lookup", "말투 규칙을 적고 있습니다…")?.stage
        )
    }

    @Test
    fun `수집한 대사 수를 두 번째 줄에 유지한다`() {
        val presentation = personaLoadingPresentation(
            "lookup",
            "대사를 모으고 있습니다… 12줄"
        )

        assertEquals("자막에서 대사를 모으는 중", presentation?.title)
        assertEquals("확인한 대사 12줄 · 말투 표본을 정리합니다", presentation?.detail)
    }

    @Test
    fun `최초 규칙 생성만 규칙 단계이고 다듬기는 대상이 아니다`() {
        assertEquals(
            PersonaLoadingStage.SYNTHESIZE,
            personaLoadingPresentation("analyze", null)?.stage
        )
        assertNull(personaLoadingPresentation("refine", null))
    }

    @Test
    fun `스토리보드 네 순간의 위치와 크기를 따른다`() {
        assertEquals(PersonaSignalFrame(13f, 17.5f, 1f), personaSignalFrame(0f))
        assertEquals(PersonaSignalFrame(38f, 16f, 1f), personaSignalFrame(.25f))
        assertEquals(PersonaSignalFrame(61f, 18f, 1f), personaSignalFrame(.50f))
        assertEquals(PersonaSignalFrame(38f, 18f, .25f, isResting = true), personaSignalFrame(.75f))
        assertEquals(PersonaSignalFrame(38f, 18f, .25f, isResting = true), personaSignalFrame(1f))
    }

    @Test
    fun `각 순간 사이는 끊기지 않고 보간한다`() {
        val firstMove = personaSignalFrame(.125f)
        val settle = personaSignalFrame(.625f)

        assertEquals(25.5f, firstMove.centerX, .001f)
        assertEquals(16.75f, firstMove.centerY, .001f)
        assertEquals(1f, firstMove.scale, .001f)
        assertEquals(49.5f, settle.centerX, .001f)
        assertEquals(18f, settle.centerY, .001f)
        assertEquals(.625f, settle.scale, .001f)
        assertFalse(settle.isResting)
    }

    @Test
    fun `대화 신호는 phone companion에만 적용한다`() {
        assertTrue(
            shouldUsePersonaLoadingSignal(
                isTabletMentor = false,
                mode = ChatMode.COMPANION
            )
        )
        assertFalse(
            shouldUsePersonaLoadingSignal(
                isTabletMentor = true,
                mode = ChatMode.COMPANION
            )
        )
        assertFalse(
            shouldUsePersonaLoadingSignal(
                isTabletMentor = false,
                mode = ChatMode.MATH_MENTOR
            )
        )
    }
}
