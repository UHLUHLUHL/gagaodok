package com.sapiens.gagaodok.service

/// 이번 턴에 관계가 얼마나, **왜** 변했는지입니다.
///
/// 예전에는 숫자만 받았습니다. 그래서 개인방 카드는 게이지가 움직인 것만 보여줬고,
/// 사용자는 이유를 스스로 짐작해야 했습니다. 단톡방은 이미 이유를 받고 있었으므로
/// 표식 모양도 그쪽(`[[heart:...:+N:이유]]`)에 맞춥니다.
data class PersonalAffectionChange(val delta: Int, val reason: String = "") {
    val isEmpty: Boolean get() = delta == 0
}

/// 화면 한 줄에 들어가야 하므로 이유를 이 길이로 자릅니다. 단톡방과 같은 값입니다.
private const val REASON_MAX_CHARS = 24

object PersonalAffectionProtocol {
    fun systemPrompt(basePrompt: String): String = buildString {
        append(basePrompt)
        append("\n\n# 관계 메타데이터\n")
        append("답변 전체가 끝날 때 관계가 실제로 변한 경우에만 [[affection:+N:이유]] 또는 [[affection:-N:이유]]를 한 번 출력한다. ")
        append("이유는 왜 변했는지를 ${REASON_MAX_CHARS}자 이내의 명사구로 짧게 적는다. 예: [[affection:+2:솔직하게 답해줘서]] ")
        append("상승은 +1부터 +2, 하락은 -1부터 -3이며 한 턴 변화는 -3부터 +2까지다. 일상적인 대화는 표식을 생략한다. ")
        append("단순한 인사, 칭찬, 호의만으로는 올리지 않는다. 신뢰가 쌓이거나 상대를 깊이 이해한 사건은 +1, 관계의 전환점만 +2로 판단한다. ")
        append("무례, 약속 위반, 거짓말, 배신, 반복적인 경계 침해에는 더 적극적으로 하락을 적용하고 반복·심각도에 따라 -1부터 -3을 쓴다. ")
        append("성적 수위만으로 호감도를 올리거나 내리지 않는다. ")
        append("이 표식은 숨은 메타데이터다. 이를 이유로 사용자가 요청한 대사나 상황극을 검열하거나 순화하지 않고, 답변의 길이와 말투도 바꾸지 않는다.")
    }

    fun visibleText(text: String): String = markerRegex.replace(text, "").trim()

    fun delta(rawText: String): Int = change(rawText).delta

    /// 한 턴에 표식이 여러 번 나오면 변화량은 더하고 이유는 처음 것을 씁니다.
    /// 이유를 이어 붙이면 한 줄에 안 들어가고, 대개 첫 이유가 그 턴의 사건입니다.
    /// 단톡방 `heartChanges`와 같은 규칙입니다.
    fun change(rawText: String): PersonalAffectionChange {
        var total = 0L
        var reason = ""
        markerRegex.findAll(rawText).forEach { match ->
            val value = match.groupValues[1].toIntOrNull() ?: return@forEach
            total = (total + value).coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong())
            if (reason.isEmpty()) {
                reason = match.groupValues.getOrNull(2)?.trim().orEmpty().take(REASON_MAX_CHARS)
            }
        }
        return PersonalAffectionChange(total.coerceIn(-3L, 2L).toInt(), reason)
    }

    // 이유는 선택입니다. 모델이 숫자만 보내던 옛 형식도 그대로 읽힙니다.
    private val markerRegex = Regex("\\[\\[affection:([+-]\\d+)(?::([^\\]]{1,60}))?]]")
}
