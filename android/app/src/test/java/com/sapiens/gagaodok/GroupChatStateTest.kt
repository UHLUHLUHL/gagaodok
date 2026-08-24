package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.GroupChatState
import com.sapiens.gagaodok.model.GroupParticipantSeed
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.Codec
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.UUID

class GroupChatStateTest {
    @Test
    fun `new group snapshots each personal room affection into the initial worldline`() {
        val firstId = UUID.fromString("00000000-0000-0000-0000-000000000001")
        val secondId = UUID.fromString("00000000-0000-0000-0000-000000000002")
        val worldlineId = UUID.fromString("10000000-0000-0000-0000-000000000001")

        val state = GroupChatState.create(
            participants = listOf(
                GroupParticipantSeed(firstId, baseAffection = 68),
                GroupParticipantSeed(secondId, baseAffection = 41)
            ),
            initialWorldlineId = worldlineId,
            createdAt = 1_700_000_000_000L
        )

        assertEquals(listOf(firstId, secondId), state.participantRoomIds)
        assertEquals(worldlineId, state.activeWorldlineId)
        assertEquals(
            mapOf(firstId to 68, secondId to 41),
            state.activeWorldline().participantHearts.associate { it.participantRoomId to it.value }
        )
    }

    @Test
    fun `new group keeps only the first seed for each participant room`() {
        val firstId = UUID.fromString("00000000-0000-0000-0000-000000000001")
        val secondId = UUID.fromString("00000000-0000-0000-0000-000000000002")
        val worldlineId = UUID.fromString("10000000-0000-0000-0000-000000000001")

        val state = GroupChatState.create(
            participants = listOf(
                GroupParticipantSeed(firstId, baseAffection = 68),
                GroupParticipantSeed(secondId, baseAffection = 41),
                GroupParticipantSeed(firstId, baseAffection = 12)
            ),
            initialWorldlineId = worldlineId,
            createdAt = 1_700_000_000_000L
        )

        assertEquals(listOf(firstId, secondId), state.participantRoomIds)
        assertEquals(
            mapOf(firstId to 68, secondId to 41),
            state.activeWorldline().participantHearts.associate { it.participantRoomId to it.value }
        )
    }

    @Test
    fun `new group clamps snapshot affection to zero through one hundred`() {
        val lowId = UUID.fromString("00000000-0000-0000-0000-000000000001")
        val highId = UUID.fromString("00000000-0000-0000-0000-000000000002")
        val worldlineId = UUID.fromString("10000000-0000-0000-0000-000000000001")

        val state = GroupChatState.create(
            participants = listOf(
                GroupParticipantSeed(lowId, baseAffection = -8),
                GroupParticipantSeed(highId, baseAffection = 123)
            ),
            initialWorldlineId = worldlineId,
            createdAt = 1_700_000_000_000L
        )

        assertEquals(
            mapOf(lowId to 0, highId to 100),
            state.activeWorldline().participantHearts.associate { it.participantRoomId to it.value }
        )
    }

    @Test
    fun `group state JSON round trip preserves active worldline and heart values`() {
        val firstId = UUID.fromString("00000000-0000-0000-0000-000000000001")
        val secondId = UUID.fromString("00000000-0000-0000-0000-000000000002")
        val initialId = UUID.fromString("10000000-0000-0000-0000-000000000001")
        val branchId = UUID.fromString("10000000-0000-0000-0000-000000000002")
        val original = GroupChatState.create(
            participants = listOf(
                GroupParticipantSeed(firstId, baseAffection = 68),
                GroupParticipantSeed(secondId, baseAffection = 41)
            ),
            initialWorldlineId = initialId,
            createdAt = 1_700_000_000_000L
        ).branchActiveWorldline(
            newWorldlineId = branchId,
            name = "비 오는 밤",
            createdAt = 1_700_000_000_100L
        ).adjustActiveHeart(firstId, delta = 9)

        val restored = Codec.json.decodeFromString<GroupChatState>(
            Codec.json.encodeToString(original)
        )

        assertEquals(branchId, restored.activeWorldlineId)
        assertEquals(
            mapOf(firstId to 77, secondId to 41),
            restored.activeWorldline().participantHearts.associate { it.participantRoomId to it.value }
        )
    }

    @Test
    fun `branching copies the active worldline heart values`() {
        val firstId = UUID.fromString("00000000-0000-0000-0000-000000000001")
        val secondId = UUID.fromString("00000000-0000-0000-0000-000000000002")
        val initialId = UUID.fromString("10000000-0000-0000-0000-000000000001")
        val branchId = UUID.fromString("10000000-0000-0000-0000-000000000002")
        val initial = GroupChatState.create(
            participants = listOf(
                GroupParticipantSeed(firstId, baseAffection = 68),
                GroupParticipantSeed(secondId, baseAffection = 41)
            ),
            initialWorldlineId = initialId,
            createdAt = 1_700_000_000_000L
        )

        val branched = initial.branchActiveWorldline(
            newWorldlineId = branchId,
            name = "비 오는 밤",
            createdAt = 1_700_000_000_100L
        )

        assertEquals(branchId, branched.activeWorldlineId)
        assertEquals(2, branched.worldlines.size)
        assertEquals("비 오는 밤", branched.activeWorldline().name)
        assertEquals(
            mapOf(firstId to 68, secondId to 41),
            branched.activeWorldline().participantHearts.associate { it.participantRoomId to it.value }
        )
    }

    @Test
    fun `heart changes affect only the active worldline`() {
        val firstId = UUID.fromString("00000000-0000-0000-0000-000000000001")
        val secondId = UUID.fromString("00000000-0000-0000-0000-000000000002")
        val initialId = UUID.fromString("10000000-0000-0000-0000-000000000001")
        val branchId = UUID.fromString("10000000-0000-0000-0000-000000000002")
        val branched = GroupChatState.create(
            participants = listOf(
                GroupParticipantSeed(firstId, baseAffection = 68),
                GroupParticipantSeed(secondId, baseAffection = 41)
            ),
            initialWorldlineId = initialId,
            createdAt = 1_700_000_000_000L
        ).branchActiveWorldline(
            newWorldlineId = branchId,
            name = "비 오는 밤",
            createdAt = 1_700_000_000_100L
        )

        val changed = branched.adjustActiveHeart(firstId, delta = 9)

        assertEquals(68, changed.worldlines.first { it.id == initialId }
            .participantHearts.first { it.participantRoomId == firstId }.value)
        assertEquals(77, changed.worldlines.first { it.id == branchId }
            .participantHearts.first { it.participantRoomId == firstId }.value)
        assertEquals(41, changed.worldlines.first { it.id == branchId }
            .participantHearts.first { it.participantRoomId == secondId }.value)
    }

    @Test
    fun `heart changes stay within zero and one hundred`() {
        val participantId = UUID.fromString("00000000-0000-0000-0000-000000000001")
        val worldlineId = UUID.fromString("10000000-0000-0000-0000-000000000001")
        val initial = GroupChatState.create(
            participants = listOf(GroupParticipantSeed(participantId, baseAffection = 95)),
            initialWorldlineId = worldlineId,
            createdAt = 1_700_000_000_000L
        )

        val upper = initial.adjustActiveHeart(participantId, delta = 10)
        val lower = upper.adjustActiveHeart(participantId, delta = -200)

        assertEquals(100, upper.activeWorldline().participantHearts.single().value)
        assertEquals(0, lower.activeWorldline().participantHearts.single().value)
    }

    @Test
    fun `switching worldlines restores that worldline state`() {
        val participantId = UUID.fromString("00000000-0000-0000-0000-000000000001")
        val initialId = UUID.fromString("10000000-0000-0000-0000-000000000001")
        val branchId = UUID.fromString("10000000-0000-0000-0000-000000000002")
        val changedBranch = GroupChatState.create(
            participants = listOf(GroupParticipantSeed(participantId, baseAffection = 68)),
            initialWorldlineId = initialId,
            createdAt = 1_700_000_000_000L
        ).branchActiveWorldline(
            newWorldlineId = branchId,
            name = "비 오는 밤",
            createdAt = 1_700_000_000_100L
        ).adjustActiveHeart(participantId, delta = 9)

        val switched = changedBranch.switchWorldline(initialId)

        assertEquals(initialId, switched.activeWorldlineId)
        assertEquals(68, switched.activeWorldline().participantHearts.single().value)
    }

    @Test
    fun `legacy personal room JSON defaults newly added fields`() {
        val room = Codec.json.decodeFromString<ChatRoom>(
            """{
                "id": "00000000-0000-0000-0000-000000000001",
                "title": "오래된 개인방",
                "createdAt": 0.0,
                "profile": { "name": "사피엔스" },
                "lastMessageText": "기존 대화",
                "lastMessageTime": 0.0,
                "isPinned": true,
                "unreadCount": 3
            }"""
        )

        assertEquals(50, room.profile.baseAffection)
        assertEquals(null, room.groupChat)
    }
}
