package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.model.MessageKind
import java.util.UUID

data class GroupReplyBubble(
    val index: Int,
    val visibleText: String,
    val kind: MessageKind,
    val speakerRoomId: UUID?,
    val reactions: List<PlannedReaction> = emptyList()
)

sealed interface GroupReplyEvent {
    val atMillis: Long

    data class TypingStarted(
        override val atMillis: Long,
        val participantRoomId: UUID
    ) : GroupReplyEvent

    data class TypingStopped(
        override val atMillis: Long,
        val participantRoomId: UUID
    ) : GroupReplyEvent

    data class RevealBubble(
        override val atMillis: Long,
        val bubbleIndex: Int
    ) : GroupReplyEvent

    data class ApplyReaction(
        override val atMillis: Long,
        val bubbleIndex: Int,
        val reaction: PlannedReaction
    ) : GroupReplyEvent
}

object GroupReplyScheduler {
    fun plan(turnId: UUID, bubbles: List<GroupReplyBubble>): List<GroupReplyEvent> {
        if (bubbles.isEmpty()) return emptyList()
        val events = mutableListOf<GroupReplyEvent>()
        var previousReveal = 0L
        var previousTypingDuration = 0L
        var speechOrdinal = 0

        bubbles.forEach { bubble ->
            val revealAt = if (bubble.kind == MessageKind.SPEECH && bubble.speakerRoomId != null) {
                val jitter = deterministicJitter(turnId, bubble.index)
                val duration = (780L + bubble.visibleText.codePointCount(0, bubble.visibleText.length) * 72L + jitter)
                    .coerceIn(950L, 4_200L)
                val start = if (speechOrdinal == 0) {
                    420L + deterministicJitter(turnId, -1).coerceAtLeast(0L)
                } else if (speechOrdinal % 2 == 1) {
                    (previousReveal - minOf(760L, previousTypingDuration / 3)).coerceAtLeast(360L)
                } else {
                    previousReveal + 360L + jitter.coerceAtLeast(0L) / 2
                }
                val reveal = maxOf(start + duration, previousReveal + 320L)
                events += GroupReplyEvent.TypingStarted(start, bubble.speakerRoomId)
                events += GroupReplyEvent.TypingStopped(reveal, bubble.speakerRoomId)
                previousTypingDuration = duration
                speechOrdinal += 1
                reveal
            } else {
                previousReveal + if (previousReveal == 0L) 650L else 440L
            }

            events += GroupReplyEvent.RevealBubble(revealAt, bubble.index)
            bubble.reactions.forEachIndexed { reactionIndex, reaction ->
                events += GroupReplyEvent.ApplyReaction(
                    atMillis = revealAt + 560L + reactionIndex * 180L + deterministicJitter(turnId, bubble.index + reactionIndex + 50).coerceAtLeast(0L) / 2,
                    bubbleIndex = bubble.index,
                    reaction = reaction
                )
            }
            previousReveal = revealAt
        }

        return events.sortedWith(compareBy<GroupReplyEvent> { it.atMillis }.thenBy { eventOrder(it) })
    }

    private fun deterministicJitter(turnId: UUID, salt: Int): Long {
        val mixed = turnId.mostSignificantBits xor turnId.leastSignificantBits xor (salt.toLong() * 0x9E3779B9L)
        return ((mixed and Long.MAX_VALUE) % 321L) - 120L
    }

    private fun eventOrder(event: GroupReplyEvent): Int = when (event) {
        is GroupReplyEvent.TypingStarted -> 0
        is GroupReplyEvent.TypingStopped -> 1
        is GroupReplyEvent.RevealBubble -> 2
        is GroupReplyEvent.ApplyReaction -> 3
    }
}
