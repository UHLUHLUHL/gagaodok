package com.sapiens.gagaodok

import com.sapiens.gagaodok.data.createGroupChatRoom
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.RoomProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.UUID

class GroupChatRoomFactoryTest {
    @Test
    fun createsIndependentQuietGroupFromDistinctPersonalRooms() {
        val first = ChatRoom(profile = RoomProfile(name = "A", baseAffection = 21))
        val second = ChatRoom(profile = RoomProfile(name = "B", baseAffection = 88))
        val group = createGroupChatRoom("A, B", listOf(first, second), UUID.randomUUID(), 123L)

        assertEquals("A, B", group.title)
        assertNotSame(first.profile, group.profile)
        assertEquals(listOf(first.id, second.id), group.groupChat!!.participantRoomIds)
        assertEquals(listOf(21, 88), group.groupChat!!.activeWorldline().participantHearts.map { it.value })
        assertEquals("대화를 시작해보세요.", group.lastMessageText)
        assertNull(group.profile.avatarImageFileName)
        assertEquals(ChatMode.COMPANION, group.resolvedMode)
        assertEquals(AIModel.GEMINI_37_FLASH, group.resolvedModel(AIModel.GPT_56_LUNA))
    }

    @Test(expected = IllegalArgumentException::class)
    fun requiresAtLeastTwoUniquePersonalParticipants() {
        val room = ChatRoom()
        createGroupChatRoom("only", listOf(room, room), UUID.randomUUID(), 123L)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsExistingGroupAsParticipant() {
        val personal = ChatRoom()
        val group = createGroupChatRoom("group", listOf(ChatRoom(), ChatRoom()), UUID.randomUUID(), 123L)
        createGroupChatRoom("nested", listOf(personal, group), UUID.randomUUID(), 123L)
    }
}
