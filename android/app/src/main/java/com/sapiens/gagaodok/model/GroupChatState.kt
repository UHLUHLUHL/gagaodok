package com.sapiens.gagaodok.model

import kotlinx.serialization.Serializable
import java.util.UUID

data class GroupParticipantSeed(
    val roomId: UUID,
    val baseAffection: Int
)

@Serializable
data class ParticipantHeart(
    @Serializable(with = UuidSerializer::class)
    val participantRoomId: UUID,
    val value: Int
)

@Serializable
data class GroupParticipant(
    @Serializable(with = UuidSerializer::class)
    val roomId: UUID
)

@Serializable
data class WorldlineState(
    @Serializable(with = UuidSerializer::class)
    val id: UUID,
    val name: String,
    @Serializable(with = SwiftDateSerializer::class)
    val createdAt: Long,
    val participantHearts: List<ParticipantHeart>
)

@Serializable
data class GroupChatState(
    val participants: List<GroupParticipant>,
    val worldlines: List<WorldlineState>,
    @Serializable(with = UuidSerializer::class)
    val activeWorldlineId: UUID
) {
    val participantRoomIds: List<UUID>
        get() = participants.map { it.roomId }

    fun activeWorldline(): WorldlineState =
        worldlines.first { it.id == activeWorldlineId }

    fun branchActiveWorldline(
        newWorldlineId: UUID,
        name: String,
        createdAt: Long
    ): GroupChatState {
        val branch = WorldlineState(
            id = newWorldlineId,
            name = name,
            createdAt = createdAt,
            participantHearts = activeWorldline().participantHearts
        )
        return copy(
            worldlines = worldlines + branch,
            activeWorldlineId = branch.id
        )
    }

    fun adjustActiveHeart(participantRoomId: UUID, delta: Int): GroupChatState {
        return adjustHeart(activeWorldlineId, participantRoomId, delta)
    }

    fun adjustHeart(worldlineId: UUID, participantRoomId: UUID, delta: Int): GroupChatState {
        val activeIndex = worldlines.indexOfFirst { it.id == worldlineId }
        if (activeIndex < 0) return this
        val active = worldlines[activeIndex]
        val heartIndex = active.participantHearts.indexOfFirst {
            it.participantRoomId == participantRoomId
        }
        if (heartIndex < 0) return this

        val updatedHearts = active.participantHearts.toMutableList().also { hearts ->
            val heart = hearts[heartIndex]
            val adjustedValue = (heart.value.toLong() + delta.toLong()).coerceIn(0L, 100L).toInt()
            hearts[heartIndex] = heart.copy(value = adjustedValue)
        }
        val updatedWorldlines = worldlines.toMutableList().also { lines ->
            lines[activeIndex] = active.copy(participantHearts = updatedHearts)
        }
        return copy(worldlines = updatedWorldlines)
    }

    fun switchWorldline(worldlineId: UUID): GroupChatState =
        if (worldlines.any { it.id == worldlineId }) copy(activeWorldlineId = worldlineId)
        else this

    companion object {
        fun create(
            participants: List<GroupParticipantSeed>,
            initialWorldlineId: UUID,
            createdAt: Long
        ): GroupChatState {
            val distinctParticipants = participants.distinctBy { it.roomId }
            val initial = WorldlineState(
                id = initialWorldlineId,
                name = "기본 세계선",
                createdAt = createdAt,
                participantHearts = distinctParticipants.map { seed ->
                    ParticipantHeart(seed.roomId, seed.baseAffection.coerceIn(0, 100))
                }
            )
            return GroupChatState(
                participants = distinctParticipants.map { GroupParticipant(it.roomId) },
                worldlines = listOf(initial),
                activeWorldlineId = initial.id
            )
        }
    }
}
