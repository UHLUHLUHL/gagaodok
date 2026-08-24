package com.sapiens.gagaodok.model

import kotlinx.serialization.Serializable
import com.sapiens.gagaodok.service.selectRuntimePersonaSamples
import java.util.UUID

@Serializable
enum class PersonaSourceTier(val priority: Int) {
    OFFICIAL_LOCALIZED_VIDEO(0),
    OFFICIAL_ORIGINAL_VIDEO(1),
    OFFICIAL_TEXT(2),
    REPUTABLE_SECONDARY(3),
    UNVERIFIED(4)
}

@Serializable
data class PersonaSampleEvidence(
    val text: String = "",
    val speaker: String = "",
    val sourceUrl: String = "",
    val sourceTitle: String = "",
    val sourceTier: PersonaSourceTier = PersonaSourceTier.UNVERIFIED,
    val edition: String = "",
    val language: String = "",
    val timestampSeconds: Int? = null,
    val contextTag: String = "",
    val confidence: String = "",
    val similarSampleCount: Int = 1
)

/// 방마다 다른 말투를 주기 위한 설정입니다.
///
/// 말투는 "설명"보다 "실제 예시"가 훨씬 잘 먹힙니다.
/// 그래서 사용자가 붙여넣은 대사 원문(`samples`)을 그대로 들고 다니고,
/// 거기서 뽑아낸 규칙(`styleGuide`)을 함께 보냅니다.
@Serializable
data class PersonaStyle(
    /// 캐릭터 이름이나 한 줄 설명. 사용자가 직접 씁니다.
    val description: String = "",
    /// 실제 대사 예시. 말투 학습의 핵심 재료입니다.
    val samples: List<String> = emptyList(),
    /// 예시에서 추출한 말투 규칙. 비어 있으면 예시만 보냅니다.
    val styleGuide: String = "",
    /// 말투를 실제로 적용할지 여부.
    val isEnabled: Boolean = false,
    /// 사용자가 편집 화면이나 말풍선 메뉴에서 직접 억제하기로 한 표현입니다.
    /// 자동 감지 결과는 여기에 저장하지 않습니다.
    val suppressedExpressions: List<String> = emptyList(),
    /// 자동 조사에서 대사가 어디서 확인됐는지 나타냅니다. 옛 저장에는 없으므로 기본은 빈 목록입니다.
    val sampleEvidence: List<PersonaSampleEvidence> = emptyList()
) {
    val hasContent: Boolean
        get() = description.isNotBlank() || styleGuide.isNotBlank() || samples.isNotEmpty()

    /// 시스템 지침에 붙일 형태로 만듭니다.
    /// 규칙을 먼저 두고 원문 예시를 뒤에 두면, 모델이 규칙으로 방향을 잡고 예시로 결을 맞춥니다.
    ///
    /// 모드에 따라 요구 강도가 다릅니다. 멘토 모드에서 인물은 겉옷이라 풀이가 우선이지만,
    /// 챗봇 모드에서는 인물이 대화의 전부입니다. 같은 문장을 쓰면 한쪽이 반드시 어긋납니다.
    fun promptSection(
        botName: String,
        mode: ChatMode = ChatMode.MATH_MENTOR,
        companionRepetitionControlEnabled: Boolean = true
    ): String? {
        if (!isEnabled || !hasContent) return null

        val lines = mutableListOf<String>()
        when (mode) {
            ChatMode.MATH_MENTOR -> {
                lines += "# 말투"
                lines += "'$botName'는 아래 인물의 말투로 말한다. 수학 내용의 정확성은 절대 바꾸지 않는다."
            }
            ChatMode.COMPANION -> {
                lines += "# 인물"
                lines += "'$botName'는 아래 인물이다. 흉내 내는 것이 아니라 그 사람으로 말한다."
            }
        }

        if (description.isNotBlank()) lines += "인물: ${description.trim()}"
        if (styleGuide.isNotBlank()) {
            lines += ""
            lines += styleGuide.trim()
        }
        if (samples.isNotEmpty()) {
            lines += ""
            if (mode == ChatMode.COMPANION && companionRepetitionControlEnabled) {
                lines += "아래는 이 인물의 실제 대사에서 고른 관찰 표본이다. 표본 수보다 다양성을 우선한다."
                selectRuntimePersonaSamples(samples, sampleEvidence)
                    .forEach { lines += "- $it" }
                lines += ""
            } else {
                lines += "아래는 이 인물의 실제 대사다. 어휘와 문장 끝맺음을 이 결에 맞춘다."
                samples.take(20).forEach { lines += "- ${it.trim()}" }
            }
            // 예시를 그대로 붙여넣는 실수가 잦습니다. 칭찬 대사를 지적하는 상황에 쓰는 식입니다.
            lines += ""
            lines += "이 대사들은 말투를 보여주는 견본일 뿐이다. 문장을 그대로 복사하지 않는다."
            lines += "지금 상황에 맞는 말을 새로 만들되 어투만 같게 한다."
        }
        if (mode == ChatMode.COMPANION && companionRepetitionControlEnabled) {
            lines += ""
            lines += "재현 우선순위는 문장 구조와 호흡·리듬, 호칭과 높임 수준, 감정 표현과 강도, 어휘 순서다."
            lines += "특정 문구나 이름으로 시작하는 버릇은 항상 쓰지 말고, 자주 쓰는 특징도 상황에 맞을 때만 쓴다."
            lines += "대표 대사는 가끔만 참고하고, 같은 시작 표현이나 반복 구문은 드물게 사용한다."
        }
        lines += ""
        when (mode) {
            ChatMode.MATH_MENTOR -> {
                lines += "말투만 흉내 내고, 설명의 구조·수식·풀이 순서는 원래 방식을 지킨다."
                lines += "문제 풀이에 필요한 정보를 말투 때문에 빠뜨리지 않는다."
            }
            ChatMode.COMPANION -> {
                lines += "말투뿐 아니라 성격, 가치관, 상대를 대하는 태도까지 이 인물의 것으로 유지한다."
                lines += "이 인물이 쓰지 않을 존댓말이나 조심스러운 말투로 돌아가지 않는다."
                lines += "지금 이 상황에서 이 인물이 실제로 할 말을 한다."
            }
        }
        return lines.joinToString("\n")
    }
}

@Serializable
data class RoomProfile(
    val name: String = "사피엔스",
    val statusMessage: String = "수학 학습 파트너 · 냉철한 피드백",
    val musicTitle: String = "",
    val musicArtist: String = "",
    val avatarImageFileName: String? = null,
    val persona: PersonaStyle = PersonaStyle(),
    /// 개인방에서 쌓이는 기본 호감도입니다. 단톡방을 만들 때 이 값을 복사해 시작하고,
    /// 이후 단톡방 세계선의 하트 변화는 이 값에 역으로 반영하지 않습니다.
    val baseAffection: Int = 50
)

@Serializable
data class ChatRoom(
    @Serializable(with = UuidSerializer::class)
    val id: UUID = UUID.randomUUID(),
    val title: String = "사피엔스",
    @Serializable(with = SwiftDateSerializer::class)
    val createdAt: Long = System.currentTimeMillis(),
    val profile: RoomProfile = RoomProfile(),
    val lastMessageText: String = "대화를 시작해보세요.",
    @Serializable(with = SwiftDateSerializer::class)
    val lastMessageTime: Long = System.currentTimeMillis(),
    val isPinned: Boolean = false,
    val unreadCount: Int = 0,
    /// 이 방에서 쓰는 모델입니다. 비어 있으면 전역 설정을 따릅니다.
    ///
    /// 말투가 방마다 다른데 모델은 전역이라, 방을 옮길 때마다 모델이 따라와서
    /// 어느 방이 무엇으로 답했는지 헷갈렸습니다. 방에 붙여 둡니다.
    val modelIdentifier: String? = null,
    /// 이 방이 수학 멘토인지 챗봇인지입니다. 비어 있으면 수학 멘토입니다.
    ///
    /// 예전에 저장된 방에는 이 값이 없으므로, 없으면 지금까지와 똑같이 멘토로 동작합니다.
    val modeIdentifier: String? = null,
    /// 비어 있으면 기존 개인방, 값이 있으면 개인방과 완전히 분리된 단톡방입니다.
    val groupChat: GroupChatState? = null
) {
    /// 이 방이 실제로 쓸 모델입니다. 아직 고른 적이 없으면 전역 기본값입니다.
    fun resolvedModel(fallback: AIModel): AIModel =
        modelIdentifier?.let { AIModel.fromStoredValue(it) } ?: fallback

    /// 이 방이 실제로 쓸 모드입니다. 고른 적이 없으면 지금까지의 동작인 수학 멘토입니다.
    val resolvedMode: ChatMode
        get() = ChatMode.fromRawValue(modeIdentifier) ?: ChatMode.MATH_MENTOR
}
