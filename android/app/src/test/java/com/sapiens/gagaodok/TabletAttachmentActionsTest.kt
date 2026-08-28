package com.sapiens.gagaodok

import com.sapiens.gagaodok.ui.screens.AttachmentAction
import com.sapiens.gagaodok.ui.screens.phoneAttachmentActions
import com.sapiens.gagaodok.ui.screens.tabletAttachmentActions
import org.junit.Assert.assertEquals
import org.junit.Test

class TabletAttachmentActionsTest {

    @Test
    fun `태블릿 첨부 메뉴에서 카메라 촬영을 선택할 수 있다`() {
        assertEquals(
            listOf(
                AttachmentAction.PHOTO_LIBRARY,
                AttachmentAction.CAMERA,
                AttachmentAction.PDF,
                AttachmentAction.INK
            ),
            tabletAttachmentActions()
        )
    }

    @Test
    fun `폰 첨부 메뉴는 사진 촬영과 PDF를 제공하고 필기는 제외한다`() {
        assertEquals(
            listOf(
                AttachmentAction.PHOTO_LIBRARY,
                AttachmentAction.CAMERA,
                AttachmentAction.PDF
            ),
            phoneAttachmentActions()
        )
    }
}
