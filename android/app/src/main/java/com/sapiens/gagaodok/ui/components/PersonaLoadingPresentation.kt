package com.sapiens.gagaodok.ui.components

import com.sapiens.gagaodok.model.ChatMode

internal enum class PersonaLoadingStage {
    SOURCE,
    VERIFY,
    COLLECT,
    SYNTHESIZE
}

internal data class PersonaLoadingPresentation(
    val stage: PersonaLoadingStage,
    val title: String,
    val detail: String
)

internal data class PersonaSignalFrame(
    val centerX: Float,
    val centerY: Float,
    val scale: Float,
    val isResting: Boolean = false
)

private val sourcePresentation = PersonaLoadingPresentation(
    stage = PersonaLoadingStage.SOURCE,
    title = "공식 자료를 찾는 중",
    detail = "영상과 자막의 출처를 먼저 확인합니다"
)

private val verifyPresentation = PersonaLoadingPresentation(
    stage = PersonaLoadingStage.VERIFY,
    title = "찾은 자료를 살펴보는 중",
    detail = "공식 출처와 대사의 맥락을 확인합니다"
)

private val synthesizePresentation = PersonaLoadingPresentation(
    stage = PersonaLoadingStage.SYNTHESIZE,
    title = "말투 규칙을 만드는 중",
    detail = "구조·리듬·호칭의 빈도를 정리합니다"
)

internal fun personaLoadingPresentation(
    busy: String,
    progress: String?
): PersonaLoadingPresentation? = when (busy) {
    "analyze" -> synthesizePresentation
    "lookup" -> lookupPresentation(progress.orEmpty())
    else -> null
}

private fun lookupPresentation(progress: String): PersonaLoadingPresentation = when {
    progress.startsWith("말투 규칙") -> synthesizePresentation
    progress.startsWith("대사를 모으고") -> {
        val count = Regex("(\\d+)줄").find(progress)?.groupValues?.get(1)
        PersonaLoadingPresentation(
            stage = PersonaLoadingStage.COLLECT,
            title = "자막에서 대사를 모으는 중",
            detail = if (count == null) {
                "확인한 대사를 말투 표본으로 정리합니다"
            } else {
                "확인한 대사 ${count}줄 · 말투 표본을 정리합니다"
            }
        )
    }
    progress.startsWith("찾은 자료") -> verifyPresentation
    else -> sourcePresentation
}

internal fun personaSignalFrame(fraction: Float): PersonaSignalFrame {
    val clamped = fraction.coerceIn(0f, 1f)
    return when {
        clamped < .25f -> PersonaSignalFrame(
            centerX = interpolate(13f, 38f, clamped * 4f),
            centerY = interpolate(17.5f, 16f, clamped * 4f),
            scale = 1f
        )
        clamped < .50f -> PersonaSignalFrame(
            centerX = interpolate(38f, 61f, (clamped - .25f) * 4f),
            centerY = interpolate(16f, 18f, (clamped - .25f) * 4f),
            scale = 1f
        )
        clamped < .75f -> {
            val progress = (clamped - .50f) * 4f
            PersonaSignalFrame(
                centerX = interpolate(61f, 38f, progress),
                centerY = 18f,
                scale = interpolate(1f, .25f, progress)
            )
        }
        else -> PersonaSignalFrame(
            centerX = 38f,
            centerY = 18f,
            scale = .25f,
            isResting = true
        )
    }
}

private fun interpolate(start: Float, end: Float, fraction: Float): Float =
    start + (end - start) * fraction

internal fun shouldUsePersonaLoadingSignal(
    isTabletMentor: Boolean,
    mode: ChatMode
): Boolean = !isTabletMentor && mode == ChatMode.COMPANION
