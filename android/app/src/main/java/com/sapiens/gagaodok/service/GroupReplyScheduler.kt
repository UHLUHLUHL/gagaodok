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

/// 말풍선 하나가 언제 뜰지입니다. 턴이 시작한 순간을 0으로 잡은 상대 시각입니다.
data class GroupReplyStep(
    /// 이 말풍선의 화자가 입력을 시작하는 시각입니다. 나레이션이면 없습니다.
    val typingStartAt: Long?,
    val revealAt: Long,
    /// [GroupReplyBubble.reactions]와 같은 순서입니다.
    val reactionAt: List<Long>
)

/// 말풍선이 **도착하는 대로** 시각을 정합니다.
///
/// 예전에는 응답을 끝까지 받아 놓고 한꺼번에 계획했습니다. 그러면 연출 시간이 API 시간
/// 뒤에 통째로 이어 붙어서, 사용자는 두 시간을 더한 만큼 기다렸습니다. 한 개씩 정하면
/// 모델이 쓰는 동안 이미 앞 말풍선을 보여줄 수 있습니다.
///
/// 각 말풍선의 시각은 자기 앞 말풍선에만 의존하므로, 뒤를 몰라도 정할 수 있습니다.
class GroupReplyTimeline(private val turnId: UUID) {
    private var previousReveal = 0L
    private var isFirstSpeech = true

    fun next(bubble: GroupReplyBubble): GroupReplyStep {
        val typingStartAt: Long?
        val revealAt: Long
        if (bubble.kind == MessageKind.SPEECH && bubble.speakerRoomId != null) {
            val jitter = GroupReplyScheduler.jitter(turnId, bubble.index)
            val duration = (GroupReplyScheduler.TYPING_BASE +
                bubble.visibleText.codePointCount(0, bubble.visibleText.length) * GroupReplyScheduler.TYPING_PER_CHAR +
                jitter).coerceIn(GroupReplyScheduler.TYPING_MIN, GroupReplyScheduler.TYPING_MAX)
            val start = if (isFirstSpeech) GroupReplyScheduler.OPENING_DELAY
            else (previousReveal - GroupReplyScheduler.HANDOFF_OVERLAP).coerceAtLeast(0L)
            typingStartAt = start
            revealAt = maxOf(start + duration, previousReveal + GroupReplyScheduler.MIN_REVEAL_GAP)
            isFirstSpeech = false
        } else {
            typingStartAt = null
            revealAt = previousReveal + GroupReplyScheduler.NARRATION_GAP
        }
        previousReveal = revealAt
        return GroupReplyStep(
            typingStartAt = typingStartAt,
            revealAt = revealAt,
            reactionAt = bubble.reactions.indices.map { reactionIndex ->
                revealAt + GroupReplyScheduler.REACTION_DELAY + reactionIndex * GroupReplyScheduler.REACTION_STEP +
                    GroupReplyScheduler.jitter(turnId, bubble.index + reactionIndex + 50).coerceAtLeast(0L) / 2
            }
        )
    }

    /// 모델이 계획보다 늦게 써서 말풍선이 예정보다 뒤에 떴다면, 그 실제 시각을 기준으로
    /// 옮깁니다. 이걸 안 하면 뒤따르는 말풍선들이 이미 지나간 시각을 기준으로 계산돼
    /// 한꺼번에 쏟아집니다.
    fun commitReveal(actualRevealAt: Long) {
        previousReveal = maxOf(previousReveal, actualRevealAt)
    }
}

/// 한 턴의 말풍선들이 언제 뜰지를 정합니다.
///
/// 지키는 규칙이 하나 있습니다. **턴이 끝나기 전에는 입력 표시가 끊기지 않습니다.**
/// 표시가 사라졌다는 것은 곧 이 턴이 끝났다는 뜻이어야 합니다. 그래야 사용자가 말풍선
/// 하나를 받고 "이게 끝인가, 더 오나"를 헷갈리지 않습니다.
///
/// 그래서 다음 화자는 앞 말풍선이 뜨기 [HANDOFF_OVERLAP]만큼 **전에** 입력을 시작합니다.
object GroupReplyScheduler {
    /// 첫 화자가 입력을 시작하기까지의 뜸입니다. (짐작)
    internal const val OPENING_DELAY = 220L

    /// 입력 표시가 떠 있는 시간입니다.
    ///
    /// 예전 값은 `780 + 글자수 × 72`(950~4200ms)였습니다. 실기기 녹화를 재 보니 40자 대사
    /// 하나에 3.7초가 나왔고, 그 시간이 API 응답 시간에 **그대로 더해져** 전송부터 첫 글자
    /// 까지 7.6초가 걸렸습니다(그중 4.0초가 이 값). 사람이 카톡에서 40자를 3.7초 동안 치지도
    /// 않고, 무엇보다 사용자에게는 "긴 답변일수록 앱이 느리다"로 읽힙니다.
    internal const val TYPING_BASE = 300L
    internal const val TYPING_PER_CHAR = 26L
    internal const val TYPING_MIN = 550L
    internal const val TYPING_MAX = 1_900L

    /// 다음 화자가 앞 말풍선보다 먼저 입력을 시작하는 정도입니다.
    ///
    /// 0이 아니라 양수여야 위의 "입력 표시가 끊기지 않는다"가 지켜집니다.
    internal const val HANDOFF_OVERLAP = 240L

    /// 대사가 아닌 말풍선(나레이션)이 앞 말풍선 뒤에 붙는 간격입니다.
    /// 나레이션은 사람이 친 말이 아니므로 입력 표시를 쓰지 않습니다.
    internal const val NARRATION_GAP = 320L

    /// 말풍선 사이 최소 간격입니다. 두 개가 같은 프레임에 겹쳐 붙는 것을 막습니다.
    const val MIN_REVEAL_GAP = 260L

    /// 반응 이모지가 말풍선 뒤에 붙는 간격입니다.
    internal const val REACTION_DELAY = 480L
    internal const val REACTION_STEP = 160L

    /// 말풍선을 한꺼번에 계획합니다. 실제 재생은 [GroupReplyTimeline]로 하나씩 정하지만,
    /// 규칙 전체를 한눈에 검사할 수 있도록 같은 계산을 이 모양으로도 내놓습니다.
    fun plan(turnId: UUID, bubbles: List<GroupReplyBubble>): List<GroupReplyEvent> {
        if (bubbles.isEmpty()) return emptyList()
        val timeline = GroupReplyTimeline(turnId)
        val events = mutableListOf<GroupReplyEvent>()

        bubbles.forEach { bubble ->
            val step = timeline.next(bubble)
            if (step.typingStartAt != null && bubble.speakerRoomId != null) {
                events += GroupReplyEvent.TypingStarted(step.typingStartAt, bubble.speakerRoomId)
                events += GroupReplyEvent.TypingStopped(step.revealAt, bubble.speakerRoomId)
            }
            events += GroupReplyEvent.RevealBubble(step.revealAt, bubble.index)
            bubble.reactions.forEachIndexed { reactionIndex, reaction ->
                events += GroupReplyEvent.ApplyReaction(
                    atMillis = step.reactionAt[reactionIndex],
                    bubbleIndex = bubble.index,
                    reaction = reaction
                )
            }
        }

        return events.sortedWith(compareBy<GroupReplyEvent> { it.atMillis }.thenBy { eventOrder(it) })
    }

    internal fun jitter(turnId: UUID, salt: Int): Long = deterministicJitter(turnId, salt)

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
