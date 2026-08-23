package com.sapiens.gagaodok

import com.sapiens.gagaodok.ui.screens.AttachmentAction
import com.sapiens.gagaodok.ui.screens.tabletAttachmentActions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TabletAttachmentActionsTest {

    @Test
    fun `태블릿 첨부 메뉴에서 카메라 촬영을 선택할 수 있다`() {
        val actions = tabletAttachmentActions()

        assertEquals(4, actions.size)
        assertTrue(actions.contains(AttachmentAction.CAMERA))
        assertTrue(actions.containsAll(listOf(
            AttachmentAction.PHOTO_LIBRARY,
            AttachmentAction.PDF,
            AttachmentAction.INK
        )))
    }
}
