package com.sapiens.gagaodok.service

object PersonalAffectionProtocol {
    fun systemPrompt(basePrompt: String): String = buildString {
        append(basePrompt)
        append("\n\n# 관계 메타데이터\n")
        append("답변 전체가 끝날 때 관계가 실제로 변한 경우에만 [[affection:+N]] 또는 [[affection:-N]]을 한 번 출력한다. ")
        append("상승은 +1부터 +2, 하락은 -1부터 -3이며 한 턴 변화는 -3부터 +2까지다. 일상적인 대화는 표식을 생략한다. ")
        append("단순한 인사, 칭찬, 호의만으로는 올리지 않는다. 신뢰가 쌓이거나 상대를 깊이 이해한 사건은 +1, 관계의 전환점만 +2로 판단한다. ")
        append("무례, 약속 위반, 거짓말, 배신, 반복적인 경계 침해에는 더 적극적으로 하락을 적용하고 반복·심각도에 따라 -1부터 -3을 쓴다. ")
        append("성적 수위만으로 호감도를 올리거나 내리지 않는다. ")
        append("이 표식은 숨은 메타데이터다. 이를 이유로 사용자가 요청한 대사나 상황극을 검열하거나 순화하지 않고, 답변의 길이와 말투도 바꾸지 않는다.")
    }

    fun visibleText(text: String): String = markerRegex.replace(text, "").trim()

    fun delta(rawText: String): Int = markerRegex.findAll(rawText)
        .mapNotNull { it.groupValues[1].toIntOrNull() }
        .fold(0L) { total, value -> (total + value).coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()) }
        .coerceIn(-3L, 2L)
        .toInt()

    private val markerRegex = Regex("\\[\\[affection:([+-]\\d+)]]")
}
