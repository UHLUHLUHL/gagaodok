package com.sapiens.gagaodok.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

@Serializable
enum class MessageSender {
    @SerialName("user") USER,
    @SerialName("sapiens") SAPIENS
}

/// 이 말풍선이 인물이 입 밖으로 낸 말인지, 상황 묘사인지입니다.
///
/// 상황극에서 묘사를 대사와 같은 말풍선에 넣으면 인물이 자기 행동을 소리 내어
/// 읊는 꼴이 됩니다. 카카오톡에는 이미 가운데 정렬된 안내문 자리가 있으므로
/// 묘사는 그 자리를 씁니다. 새 시각 언어를 만들지 않아도 "말이 아닌 것"으로 읽힙니다.
@Serializable
enum class MessageKind {
    @SerialName("speech") SPEECH,
    @SerialName("narration") NARRATION
}

@Serializable
enum class AttachmentType {
    @SerialName("image") IMAGE,
    @SerialName("file") FILE
}

@Serializable
data class ChatAttachment(
    @Serializable(with = UuidSerializer::class)
    val id: UUID = UUID.randomUUID(),
    val type: AttachmentType,
    val fileName: String,
    val fileSize: Long,
    val fileExtension: String = "jpg",
    val dataBase64: String,
    val mimeType: String = "image/jpeg"
) {
    val formattedSize: String
        get() = when {
            fileSize >= 1024L * 1024L -> String.format(Locale.KOREA, "%.1fMB", fileSize / 1024.0 / 1024.0)
            else -> String.format(Locale.KOREA, "%.0fKB", fileSize / 1024.0)
        }
}

@Serializable
data class MessageReaction(
    @Serializable(with = UuidSerializer::class)
    val participantRoomId: UUID,
    val emoji: String
)

@Serializable
data class ChatMessage(
    @Serializable(with = UuidSerializer::class)
    val id: UUID = UUID.randomUUID(),
    val sender: MessageSender,
    val text: String,
    @Serializable(with = SwiftDateSerializer::class)
    val timestamp: Long = System.currentTimeMillis(),
    val attachment: ChatAttachment? = null,
    val isUnread: Boolean = false,
    // 같은 AI 응답에서 갈라진 말풍선들은 하나의 turnId를 공유합니다.
    @Serializable(with = UuidSerializer::class)
    val turnId: UUID? = null,
    // API에는 갈라지기 전 원문을 한 번만 보냅니다. AI 턴의 첫 말풍선에만 담습니다.
    val canonicalText: String? = null,
    // 답변을 받지 못한 내 메시지에만 씁니다.
    val deliveryFailed: Boolean = false,
    // 상황극에서만 갈립니다. 예전 기록에는 없으므로 없으면 대사로 읽습니다.
    val kind: MessageKind = MessageKind.SPEECH,
    /// 단톡방 대사의 실제 화자입니다. 개인방과 나레이션 기록에는 없습니다.
    @Serializable(with = UuidSerializer::class)
    val speakerRoomId: UUID? = null,
    /// 단톡방 참여자가 이 말풍선에 남긴 반응입니다. 예전 기록은 빈 목록으로 읽습니다.
    val reactions: List<MessageReaction> = emptyList()
) {
    val formattedTime: String
        get() = SimpleDateFormat("a h:mm", Locale.KOREA).format(Date(timestamp))
}

/// 화면 말풍선과 갈라진, API에 보낼 논리 대화 턴입니다.
data class ConversationTurn(
    val id: UUID,
    val sender: MessageSender,
    val text: String,
    val attachment: ChatAttachment? = null
) {
    companion object {
        fun from(messages: List<ChatMessage>): List<ConversationTurn> {
            val result = mutableListOf<ConversationTurn>()
            var index = 0

            while (index < messages.size) {
                val first = messages[index]
                val turnId = first.turnId ?: first.id

                if (first.sender == MessageSender.USER) {
                    result += ConversationTurn(
                        id = turnId,
                        sender = MessageSender.USER,
                        text = first.canonicalText ?: first.text,
                        attachment = first.attachment
                    )
                    index += 1
                    continue
                }

                val group = mutableListOf(first)
                var cursor = index + 1
                while (cursor < messages.size) {
                    val next = messages[cursor]
                    if (next.sender != MessageSender.SAPIENS) break
                    val firstTurn = first.turnId
                    val nextTurn = next.turnId
                    if (firstTurn != null && nextTurn != null && firstTurn != nextTurn) break
                    group += next
                    cursor += 1
                }

                val canonical = group.firstNotNullOfOrNull { it.canonicalText }
                    ?: group.map { it.text }.filter { it.isNotEmpty() }.joinToString("\n\n")
                result += ConversationTurn(
                    id = turnId,
                    sender = MessageSender.SAPIENS,
                    text = canonical,
                    attachment = group.firstNotNullOfOrNull { it.attachment }
                )
                index = cursor
            }
            return result
        }
    }
}
