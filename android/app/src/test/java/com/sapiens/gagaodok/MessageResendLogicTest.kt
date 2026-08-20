package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.AttachmentType
import com.sapiens.gagaodok.model.ChatAttachment
import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.ui.screens.MessageResendLogic
import com.sapiens.gagaodok.ui.screens.MessageUserAction
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.UUID

class MessageResendLogicTest {
    @Test
    fun `텍스트 없는 첨부 메시지는 수정 대신 다시 보내기다`() {
        assertEquals(
            MessageUserAction.RESEND,
            MessageResendLogic.actionFor(userMessage("", imageAttachment()))
        )
    }

    @Test
    fun `텍스트 메시지는 기존처럼 수정이다`() {
        assertEquals(MessageUserAction.EDIT, MessageResendLogic.actionFor(userMessage("고쳐줘")))
    }

    @Test
    fun `상대 메시지는 수정하거나 다시 보낼 수 없다`() {
        assertEquals(
            MessageUserAction.NONE,
            MessageResendLogic.actionFor(ChatMessage(sender = MessageSender.SAPIENS, text = "답"))
        )
    }

    @Test
    fun `다시 보내면 원본 첨부를 보존하고 그 뒤 대화를 제거한다`() {
        val target = userMessage("", imageAttachment()).copy(deliveryFailed = true)
        val later = ChatMessage(sender = MessageSender.SAPIENS, text = "답")

        val result = MessageResendLogic.truncateFrom(listOf(target, later), target.id, null)

        assertEquals(1, result.size)
        assertEquals(target.attachment, result.single().attachment)
        assertEquals(false, result.single().deliveryFailed)
    }

    @Test
    fun `수정 재전송은 텍스트만 바꾸고 첨부는 보존한다`() {
        val target = userMessage("원문", imageAttachment())

        val result = MessageResendLogic.truncateFrom(listOf(target), target.id, "  수정문  ")

        assertEquals("수정문", result.single().text)
        assertEquals("수정문", result.single().canonicalText)
        assertEquals(target.attachment, result.single().attachment)
    }

    @Test
    fun `존재하지 않는 메시지는 대화를 손상시키지 않는다`() {
        val original = listOf(userMessage("질문"))

        assertEquals(original, MessageResendLogic.truncateFrom(original, UUID.randomUUID(), null))
    }

    private fun userMessage(text: String, attachment: ChatAttachment? = null) = ChatMessage(
        sender = MessageSender.USER,
        text = text,
        canonicalText = text,
        attachment = attachment
    )

    private fun imageAttachment() = ChatAttachment(
        type = AttachmentType.IMAGE,
        fileName = "필기.png",
        fileSize = 4,
        fileExtension = "png",
        dataBase64 = "AAAA",
        mimeType = "image/png"
    )
}
