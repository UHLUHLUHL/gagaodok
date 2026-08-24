package com.sapiens.gagaodok.ui.screens

import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.WorldlineState
import java.util.UUID

data class GroupChatUiState(
    val selectedParticipantIds: List<UUID> = emptyList(),
    val heartExpanded: Boolean = false,
    val worldlinePickerVisible: Boolean = false
) {
    val canCreate: Boolean
        get() = selectedParticipantIds.distinct().size >= 2

    fun toggleParticipant(roomId: UUID): GroupChatUiState = copy(
        selectedParticipantIds = if (roomId in selectedParticipantIds) {
            selectedParticipantIds - roomId
        } else {
            selectedParticipantIds + roomId
        }
    )

    fun toggleHeart(): GroupChatUiState = copy(heartExpanded = !heartExpanded)

    fun showWorldlines(): GroupChatUiState = copy(worldlinePickerVisible = true)

    fun hideWorldlines(): GroupChatUiState = copy(worldlinePickerVisible = false)
}

internal fun defaultGroupTitle(selectedIds: List<UUID>, rooms: List<ChatRoom>): String {
    val personalById = rooms.filter { it.groupChat == null }.associateBy { it.id }
    return selectedIds.mapNotNull { personalById[it]?.profile?.name }.joinToString(", ")
}

internal fun activeHeartAverage(worldline: WorldlineState): Int {
    val hearts = worldline.participantHearts
    return if (hearts.isEmpty()) 0 else hearts.sumOf { it.value } / hearts.size
}

internal fun sameBubbleAuthor(first: ChatMessage, second: ChatMessage): Boolean =
    first.sender == second.sender &&
        (first.sender != MessageSender.SAPIENS || first.speakerRoomId == second.speakerRoomId)

internal fun shouldShowRelationshipGauge(room: ChatRoom, tabletLayout: Boolean): Boolean =
    !tabletLayout && room.resolvedMode == ChatMode.COMPANION
