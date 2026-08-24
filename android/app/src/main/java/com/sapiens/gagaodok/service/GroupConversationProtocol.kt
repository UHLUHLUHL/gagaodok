package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.MessageKind
import com.sapiens.gagaodok.model.PersonaStyle
import java.util.UUID

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
        append("모든 대사 문단은 완전히 따옴표로 감싸고, 따옴표 안의 첫 글자부터 [[speaker:<ROOM_UUID>]]로 시작한다. ")
        append("나레이션은 빈 줄로 분리한 강조 문단이며 speaker 표식이 없다. ")
        append("선택적으로 [[heart:<ROOM_UUID>:+N|-N]]를 대사 문단 안에 둔다. ")
        append("목록에 있는 참여자 UUID만 사용한다. 표식은 설명할 텍스트가 아닌 전송 메타데이터다.")
    }

    data class ParsedBubble(val visibleText: String, val speakerRoomId: UUID?)

    fun parseBubble(text: String, kind: MessageKind, previousSpeakerId: UUID?): ParsedBubble {
        val visibleText = markerRegex.replace(text, "").trim()
        if (kind == MessageKind.NARRATION) return ParsedBubble(visibleText, null)

        val markedSpeaker = speakerRegex.findAll(text)
            .mapNotNull { match -> match.groupValues[1].toUuidOrNull() }
            .firstOrNull { it in allowedIds }
        return ParsedBubble(visibleText, markedSpeaker ?: previousSpeakerId?.takeIf { it in allowedIds } ?: participants.first().id)
    }

    fun heartDeltas(rawText: String): Map<UUID, Int> = buildMap {
        heartRegex.findAll(rawText).forEach { match ->
            val id = match.groupValues[1].toUuidOrNull() ?: return@forEach
            val delta = match.groupValues[2].toIntOrNull() ?: return@forEach
            if (id in allowedIds) merge(id, delta, ::saturatedAdd)
        }
    }

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
                append("선택적으로 [[heart:<ROOM_UUID>:+N|-N]]를 대사 문단 안에 둔다. ")
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
        private val markerRegex = Regex("\\[\\[(?:speaker|heart):[^]]+]]")
        private val speakerRegex = Regex("\\[\\[speaker:([0-9a-fA-F-]{36})]]")
        private val heartRegex = Regex("\\[\\[heart:([0-9a-fA-F-]{36}):([+-]\\d+)]]")

        fun personaFor(participants: List<ChatRoom>): PersonaStyle = GroupConversationProtocol(participants).persona

        private fun String.toUuidOrNull(): UUID? = runCatching(UUID::fromString).getOrNull()

        private fun saturatedAdd(left: Int, right: Int): Int =
            (left.toLong() + right.toLong()).coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt()
    }
}
