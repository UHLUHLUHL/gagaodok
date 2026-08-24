package com.sapiens.gagaodok.data

import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.GroupChatState
import com.sapiens.gagaodok.model.GroupParticipantSeed
import com.sapiens.gagaodok.model.RoomProfile
import java.util.UUID

fun createGroupChatRoom(
    title: String,
    participants: List<ChatRoom>,
    initialWorldlineId: UUID,
    createdAt: Long
): ChatRoom {
    require(participants.all { it.groupChat == null }) { "Only personal rooms can join a group" }
    val distinct = participants.distinctBy { it.id }
    require(distinct.size >= 2) { "A group needs at least two unique participants" }

    return ChatRoom(
        title = title,
        createdAt = createdAt,
        profile = RoomProfile(name = title, statusMessage = "단체 대화"),
        lastMessageText = "대화를 시작해보세요.",
        lastMessageTime = createdAt,
        modelIdentifier = AIModel.GEMINI_37_FLASH.rawValue,
        modeIdentifier = ChatMode.COMPANION.rawValue,
        groupChat = GroupChatState.create(
            participants = distinct.map { GroupParticipantSeed(it.id, it.profile.baseAffection) },
            initialWorldlineId = initialWorldlineId,
            createdAt = createdAt
        )
    )
}
