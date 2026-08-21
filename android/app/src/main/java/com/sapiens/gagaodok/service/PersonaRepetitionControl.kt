package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageSender
import java.util.Locale

/// 이번 요청에서 반복을 피할 표현을 담는 값입니다.
///
/// 이 값은 저장하지 않고 요청 직전에만 만들어 캐시 접두사에 섞이지 않게 합니다.
internal data class RepetitionAdvice(
    val phrases: List<String> = emptyList()
) {
    val isEmpty: Boolean get() = phrases.isEmpty()

    fun promptSection(): String? {
        if (isEmpty) return null
        return buildString {
            appendLine("# 이번 답변의 변주 지침")
            appendLine("최근 답변에서 반복된 다음 표현은 이번 답변의 시작이나 핵심 구문으로 사용하지 않는다:")
            appendLine(phrases.joinToString(", ") { "‘$it’" })
            append("말투의 구조·리듬·호칭·감정은 유지하되, 이 지침이나 반복을 언급하지 말고 상황에 맞는 새 문장으로 답한다.")
        }
    }
}

private const val RECENT_BOT_ANSWER_LIMIT = 8

/// 최근 챗봇 답변에서 반복 위험이 있는 시작 표현과 구문을 가볍게 찾습니다.
internal fun repetitionAdvice(
    recentBotAnswers: List<String>,
    explicitSuppressedExpressions: List<String> = emptyList()
): RepetitionAdvice {
    val answers = recentBotAnswers.takeLast(RECENT_BOT_ANSWER_LIMIT)
    val explicit = linkedMapOf<String, String>()
    explicitSuppressedExpressions
        .map(String::trim)
        .filter(String::isNotEmpty)
        .forEach { phrase -> explicit.putIfAbsent(normalize(phrase), phrase) }

    val repeated = linkedMapOf<String, String>()
    val openingOccurrences = mutableMapOf<String, MutableSet<Int>>()
    answers.forEachIndexed { index, answer ->
        val opening = extractOpeningPhrase(answer) ?: return@forEachIndexed
        val key = normalize(opening)
        if (key.isNotEmpty()) {
            openingOccurrences.getOrPut(key) { mutableSetOf() } += index
            repeated.putIfAbsent(key, opening)
        }
    }
    val repeatedOpenings = openingOccurrences
        .filterValues { it.size >= 2 }
        .keys
        .mapNotNull(repeated::get)

    val ngramOccurrences = mutableMapOf<String, MutableSet<Int>>()
    answers.forEachIndexed { index, answer ->
        val words = normalize(answer).split(' ').filter(String::isNotEmpty)
        for (size in 2..minOf(5, words.size)) {
            for (start in 0..words.size - size) {
                val phrase = words.subList(start, start + size).joinToString(" ")
                if (phrase.length < 5) continue
                ngramOccurrences.getOrPut(phrase) { mutableSetOf() } += index
            }
        }
    }
    val repeatedNgrams = ngramOccurrences
        .filterValues { it.size >= 2 }
        .keys
        .sortedByDescending(String::length)

    val generated = (repeatedOpenings + repeatedNgrams)
        .distinctBy(::normalize)
        .sortedWith(compareByDescending<String> { normalize(it).length })
        .take(5)

    return RepetitionAdvice((explicit.values + generated).distinctBy(::normalize).take(8))
}

/// 메시지로부터 합쳐진 논리 AI 턴만 골라 반복을 계산합니다.
internal fun repetitionAdviceFromConversation(
    conversation: List<ConversationTurn>,
    explicitSuppressedExpressions: List<String> = emptyList()
): RepetitionAdvice = repetitionAdvice(
    recentBotAnswers = conversation
        .asReversed()
        .asSequence()
        .filter { it.sender == MessageSender.SAPIENS && it.text.isNotBlank() }
        .map { it.text }
        .take(RECENT_BOT_ANSWER_LIMIT)
        .toList()
        .asReversed(),
    explicitSuppressedExpressions = explicitSuppressedExpressions
)

/// 사용자가 명시적으로 고른 표현과 자동 감지 결과를 현재 요청에만 붙입니다.
/// 원래 대화와 저장 파일은 바꾸지 않으며, 캐시를 만들 때는 이 복사본을 사용하지 않습니다.
internal fun List<ConversationTurn>.withRepetitionGuidance(advice: RepetitionAdvice?): List<ConversationTurn> {
    val guidance = advice?.promptSection() ?: return this
    val index = indexOfLast { it.sender == MessageSender.USER }
    if (index < 0) return this
    return toMutableList().also { turns ->
        val original = turns[index]
        turns[index] = original.copy(
            // 실제 사용자 메시지를 먼저 두고, 보정은 최신 턴의 가변 suffix로 둡니다.
            // 이전 턴까지의 캐시 가능한 접두사와 저장 원문은 그대로 유지됩니다.
            text = "${original.text}\n\n$guidance"
        )
    }
}

/// 말풍선 메뉴에서 사용자가 억제할 시작 표현을 고를 때도 같은 규칙을 씁니다.
internal fun extractOpeningPhrase(text: String): String? {
    val firstLine = text.lineSequence().map(String::trim).firstOrNull(String::isNotEmpty) ?: return null
    val clause = firstLine.split(Regex("[,，:：.!?。！？;；]"), limit = 2).first().trim()
    val normalized = normalize(clause)
    return clause.takeIf { normalized.isNotEmpty() }
}

private fun normalize(value: String): String = value
    .lowercase(Locale.ROOT)
    .replace(Regex("[\\p{Punct}‘’“”\"…·~〜、]+"), " ")
    .replace(Regex("\\s+"), " ")
    .trim()
