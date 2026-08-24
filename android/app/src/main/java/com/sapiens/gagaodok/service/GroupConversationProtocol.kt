package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.MessageKind
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.model.PersonaStyle
import java.util.UUID

data class PlannedReaction(val participantRoomId: UUID, val emoji: String)

/** Converts group-only transport metadata into display-safe bubbles. */
class GroupConversationProtocol(participants: List<ChatRoom>) {
    private val participants = participants.distinctBy { it.id }
    private val allowedIds = this.participants.map { it.id }.toSet()

    init {
        require(this.participants.isNotEmpty()) { "A group conversation needs a participant." }
    }

    val persona: PersonaStyle = compositePersona(this.participants)

    fun systemPrompt(roomTitle: String): String = buildString {
        append(ChatMode.COMPANION.stableSystemPrompt)
        append("\n\n# 단톡방 참여자\n")
        append("이 대화는 '").append(roomTitle).append("' 단톡방이다. 당신은 한 사람이 아니라 아래 참여자들의 대사를 각각 만든다.\n")
        participants.forEach { room ->
            val style = room.profile.persona
            append("- ").append(room.profile.name).append(" (").append(room.id).append(")")
            if (style.isEnabled && style.description.isNotBlank()) append(": ").append(style.description.trim())
            append('\n')
            if (style.isEnabled && style.styleGuide.isNotBlank()) append(style.styleGuide.trim()).append('\n')
            selectedSamples(room).forEach { append("  - ").append(it).append('\n') }
        }
        append("위 대사들은 말투를 보여주는 견본일 뿐이다. 문장을 그대로 복사하지 않고 지금 상황에 맞는 말을 새로 만든다.\n")
        append("\n# 단톡방 출력 규약\n")
        append("모든 참여자는 매 턴 대사 또는 반응으로 참여한다. 보통은 모두 한 번씩 말하되, 말이 부자연스러운 참여자는 반응만 남길 수 있다. ")
        append("각 참여자는 앞서 보낸 말에 답하거나 반응해 서로 대화한다. 사용자에게 독립적인 독백을 나란히 하지 않는다. ")
        append("참여자마다 기본 한 문단, 자연스러운 짧은 후속 말이 꼭 필요할 때만 한 문단을 더 쓴다. 적어도 한 명은 말한다.\n")
        append("모든 대사 문단은 완전히 따옴표로 감싸고, 따옴표 안의 첫 글자부터 [[speaker:<ROOM_UUID>]]로 시작한다. ")
        append("나레이션은 빈 줄로 분리한 강조 문단이며 speaker 표식이 없다. ")
        append("말하지 않는 참여자의 반응은 대상 대사 문단 안에 [[react:<ROOM_UUID>:<EMOJI>]]로 한 번 둔다. ")
        append("선택적으로 [[heart:<ROOM_UUID>:+N|-N]]를 대사 문단 안에 두며 한 턴 변화는 -3부터 +3까지다. ")
        append("목록에 있는 참여자 UUID만 사용한다. 표식은 설명할 텍스트가 아닌 전송 메타데이터다.")
    }

    /// 첫 말풍선이 도착하기 전에 누가 입력 중일지를 고릅니다.
    ///
    /// 응답이 오기 전에는 화자를 알 수 없습니다. 그렇다고 "대화를 준비하고 있어요" 같은
    /// 앱 사정을 화면에 띄울 수는 없습니다. 사용자는 캐릭터와 단톡을 하는 중이지 스케줄러를
    /// 구경하는 중이 아닙니다.
    ///
    /// 틀려도 괜찮습니다. 실제 단톡방에서도 "A님이 입력 중"이 떴다가 B가 먼저 말하는 일은
    /// 늘 있어서, 틀린 추측이 오히려 진짜 단톡방처럼 읽힙니다. 첫 말풍선이 도착하면
    /// 조용히 바뀝니다.
    fun guessFirstSpeaker(history: List<ChatMessage>, userText: String): UUID {
        // 사용자가 이름을 부른 사람이 있으면 그 사람이 답할 차례입니다.
        participants.firstOrNull { it.profile.name.isNotBlank() && userText.contains(it.profile.name) }
            ?.let { return it.id }
        // 없으면 직전에 말한 사람이 이어서 말한다고 봅니다.
        history.lastOrNull { it.sender == MessageSender.SAPIENS && it.speakerRoomId != null }
            ?.speakerRoomId
            ?.takeIf { it in allowedIds }
            ?.let { return it }
        return participants.first().id
    }

    data class ParsedBubble(
        val visibleText: String,
        val speakerRoomId: UUID?,
        val reactions: List<PlannedReaction> = emptyList()
    )

    fun parseBubble(text: String, kind: MessageKind, previousSpeakerId: UUID?): ParsedBubble {
        val visibleText = markerRegex.replace(text, "").trim()
        if (kind == MessageKind.NARRATION) return ParsedBubble(visibleText, null)

        val markedSpeaker = speakerRegex.findAll(text)
            .mapNotNull { match -> match.groupValues[1].toUuidOrNull() }
            .firstOrNull { it in allowedIds }
        val reactions = reactionRegex.findAll(text).mapNotNull { match ->
            val id = match.groupValues[1].toUuidOrNull()?.takeIf { it in allowedIds } ?: return@mapNotNull null
            val emoji = match.groupValues[2].trim().takeIf { it.isNotEmpty() && it.codePointCount(0, it.length) <= 8 }
                ?: return@mapNotNull null
            PlannedReaction(id, emoji)
        }.distinct().toList()
        return ParsedBubble(
            visibleText,
            markedSpeaker ?: previousSpeakerId?.takeIf { it in allowedIds } ?: participants.first().id,
            reactions
        )
    }

    fun heartDeltas(rawText: String): Map<UUID, Int> = buildMap {
        heartRegex.findAll(rawText).forEach { match ->
            val id = match.groupValues[1].toUuidOrNull() ?: return@forEach
            val delta = match.groupValues[2].toIntOrNull() ?: return@forEach
            if (id in allowedIds) merge(id, delta, ::saturatedAdd)
        }
    }.mapValues { (_, delta) -> delta.coerceIn(-3, 3) }

    private fun compositePersona(rooms: List<ChatRoom>): PersonaStyle {
        val descriptions = rooms.joinToString("\n") { room ->
            val description = room.profile.persona.description.trim()
                .takeIf { room.profile.persona.isEnabled && it.isNotEmpty() }
            "- ${room.profile.name} (${room.id})" + (description?.let { ": $it" }.orEmpty())
        }
        val enabledRooms = rooms.filter { it.profile.persona.isEnabled }
        val styleGuides = enabledRooms.mapNotNull { room ->
            room.profile.persona.styleGuide.trim().takeIf { it.isNotEmpty() }?.let { "${room.profile.name} (${room.id}): $it" }
        }
        val samples = enabledRooms.flatMap(::selectedSamples)
        return PersonaStyle(
            description = "단톡방 참여자:\n$descriptions",
            styleGuide = buildString {
                append("각 참여자의 이름, UUID, 성격과 말투를 유지한다.\n")
                if (styleGuides.isNotEmpty()) append(styleGuides.joinToString("\n")).append('\n')
                append("모든 대사 문단은 완전히 따옴표로 감싸고, 따옴표 안의 첫 글자부터 [[speaker:<ROOM_UUID>]]로 시작한다. ")
                append("나레이션은 빈 줄로 분리한 강조 문단이며 speaker 표식이 없다. ")
                append("모든 참여자는 대사 또는 [[react:<ROOM_UUID>:<EMOJI>]] 반응으로 참여하고 앞서 보낸 말에 이어서 답한다. ")
                append("선택적으로 [[heart:<ROOM_UUID>:+N|-N]]를 대사 문단 안에 두며 한 턴 변화는 -3부터 +3까지다. ")
                append("목록에 있는 참여자 UUID만 사용한다. 표식은 설명할 텍스트가 아닌 전송 메타데이터다.")
            },
            samples = samples,
            isEnabled = true,
            suppressedExpressions = rooms.flatMap { it.profile.persona.suppressedExpressions }.distinct()
        )
    }

    private fun selectedSamples(room: ChatRoom): List<String> {
        val style = room.profile.persona
        if (!style.isEnabled) return emptyList()
        return selectRuntimePersonaSamples(style.samples, style.sampleEvidence)
            .map { "${room.profile.name} (${room.id}): $it" }
    }

    companion object {
        private val markerRegex = Regex("\\[\\[(?:speaker|heart|react):[^]]+]]")
        private val speakerRegex = Regex("\\[\\[speaker:([0-9a-fA-F-]{36})]]")
        private val heartRegex = Regex("\\[\\[heart:([0-9a-fA-F-]{36}):([+-]\\d+)]]")
        private val reactionRegex = Regex("\\[\\[react:([0-9a-fA-F-]{36}):([^]]+)]]")

        fun personaFor(participants: List<ChatRoom>): PersonaStyle = GroupConversationProtocol(participants).persona

        private fun String.toUuidOrNull(): UUID? = runCatching(UUID::fromString).getOrNull()

        private fun saturatedAdd(left: Int, right: Int): Int =
            (left.toLong() + right.toLong()).coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt()
    }
}
