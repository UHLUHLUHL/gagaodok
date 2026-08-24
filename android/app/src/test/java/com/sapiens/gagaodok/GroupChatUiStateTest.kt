package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.model.ParticipantHeart
import com.sapiens.gagaodok.model.RoomProfile
import com.sapiens.gagaodok.model.WorldlineState
import com.sapiens.gagaodok.data.ChatStore
import com.sapiens.gagaodok.data.createGroupChatRoom
import com.sapiens.gagaodok.ui.screens.GroupChatUiState
import com.sapiens.gagaodok.ui.screens.activeHeartAverage
import com.sapiens.gagaodok.ui.screens.defaultGroupTitle
import com.sapiens.gagaodok.ui.screens.sameBubbleAuthor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class GroupChatUiStateTest {
    private val firstId = UUID.fromString("00000000-0000-0000-0000-000000000001")
    private val secondId = UUID.fromString("00000000-0000-0000-0000-000000000002")
    private val thirdId = UUID.fromString("00000000-0000-0000-0000-000000000003")

    @Test
    fun groupCreationRequiresTwoDistinctPersonalRooms() {
        val one = GroupChatUiState().toggleParticipant(firstId)
        val two = one.toggleParticipant(secondId)
        val duplicateToggle = two.toggleParticipant(firstId)

        assertFalse(one.canCreate)
        assertTrue(two.canCreate)
        assertFalse(duplicateToggle.canCreate)
        assertEquals(listOf(secondId), duplicateToggle.selectedParticipantIds)
    }

    @Test
    fun defaultTitleFollowsSelectionOrderAndIgnoresGroupRooms() {
        val first = ChatRoom(id = firstId, profile = RoomProfile(name = "현우진"))
        val second = ChatRoom(id = secondId, profile = RoomProfile(name = "유키"))
        val nestedGroup = ChatRoom(id = thirdId, profile = RoomProfile(name = "기존 단톡방"), groupChat =
            com.sapiens.gagaodok.model.GroupChatState.create(
                participants = listOf(
                    com.sapiens.gagaodok.model.GroupParticipantSeed(firstId, 50),
                    com.sapiens.gagaodok.model.GroupParticipantSeed(secondId, 50)
                ),
                initialWorldlineId = UUID.randomUUID(),
                createdAt = 1L
            )
        )

        assertEquals("유키, 현우진", defaultGroupTitle(listOf(secondId, thirdId, firstId), listOf(first, second, nestedGroup)))
    }

    @Test
    fun activeWorldlineHeartAverageUsesOnlyThatWorldlineValues() {
        val worldline = WorldlineState(
            id = UUID.randomUUID(),
            name = "비 오는 밤",
            createdAt = 1L,
            participantHearts = listOf(ParticipantHeart(firstId, 72), ParticipantHeart(secondId, 64))
        )

        assertEquals(68, activeHeartAverage(worldline))
    }

    @Test
    fun heartExpansionAndWorldlinePickerAreIndependentUiState() {
        val expanded = GroupChatUiState().toggleHeart()
        val picker = expanded.showWorldlines()

        assertTrue(picker.heartExpanded)
        assertTrue(picker.worldlinePickerVisible)
        assertFalse(picker.hideWorldlines().worldlinePickerVisible)
        assertTrue(picker.hideWorldlines().heartExpanded)
    }

    @Test
    fun adjacentGroupBubblesWithDifferentSpeakersDoNotMerge() {
        val first = ChatMessage(sender = MessageSender.SAPIENS, text = "첫 말", speakerRoomId = firstId)
        val second = ChatMessage(sender = MessageSender.SAPIENS, text = "둘째 말", speakerRoomId = secondId)

        assertFalse(sameBubbleAuthor(first, second))
        assertTrue(sameBubbleAuthor(first, first.copy(text = "이어 말")))
    }

    @Test
    fun quietGroupRemainsVisibleBeforeItsFirstMessage() {
        val first = ChatRoom(id = firstId, profile = RoomProfile(name = "현우진"))
        val second = ChatRoom(id = secondId, profile = RoomProfile(name = "유키"))
        val quietGroup = createGroupChatRoom("현우진, 유키", listOf(first, second), UUID.randomUUID(), 1L)

        assertEquals(
            listOf(quietGroup.id),
            ChatStore.conversationRoomsForDisplay(listOf(first, quietGroup), emptySet()).map { it.id }
        )
    }
}
