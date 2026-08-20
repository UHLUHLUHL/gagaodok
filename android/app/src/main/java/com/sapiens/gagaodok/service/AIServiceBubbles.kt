package com.sapiens.gagaodok.service

import android.graphics.Bitmap
import android.util.Base64
import com.sapiens.gagaodok.model.AttachmentType
import com.sapiens.gagaodok.model.ChatAttachment
import com.sapiens.gagaodok.model.MessageKind
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.encodeToString
import java.io.ByteArrayOutputStream

// 답변 한 덩이를 카카오톡 말풍선 여러 개로 가릅니다.
// 네트워크를 모릅니다. 글자만 보고 판단하므로 따로 시험해 볼 수 있습니다.
data class GeneratedMessageBubble(
    val text: String,
    val attachment: ChatAttachment? = null,
    val kind: MessageKind = MessageKind.SPEECH
)

/// 스트림 조각을 받아 완성된 말풍선만 밖으로 내보냅니다.
///
/// 문단이 완성되면 기존 말풍선 분리기에 그대로 넘기므로, 그래프 태그 처리나
/// 이름 접두사 제거 같은 규칙이 스트리밍에서도 똑같이 적용됩니다.
class StreamBubbleSink(
    /// 이 턴이 상황극이라고 이미 아는지.
    ///
    /// 문단은 완성되는 대로 화면에 붙기 때문에, 첫 문단을 붙일 때는 뒤에 따옴표 대사가
    /// 나올지 알 수 없습니다. 그래서 지난 턴에서 얻은 값으로 시작합니다.
    /// 상황극을 처음 시작하는 턴에서만, 첫 대사가 나오기 전의 묘사가 대사 말풍선으로
    /// 나옵니다. 그 다음 턴부터는 앞 턴이 근거가 되어 첫 문단부터 제대로 갈립니다.
    internal var roleplayEstablished: Boolean,
    internal val makeBubbles: (String, Boolean) -> List<GeneratedMessageBubble>,
    internal val onBubble: suspend (GeneratedMessageBubble) -> Unit
) {
    internal val buffer = StreamingBubbleBuffer()
    internal val lock = Mutex()

    suspend fun consume(piece: String) = lock.withLock {
        buffer.append(piece).forEach { handle(it) }
    }

    suspend fun finish() = lock.withLock {
        val rest = buffer.flush()
        if (rest.isNotEmpty()) handle(rest)
    }

    internal suspend fun handle(paragraph: String) {
        if (RoleplayParser.establishesRoleplay(paragraph)) roleplayEstablished = true
        makeBubbles(paragraph, roleplayEstablished).forEach { onBubble(it) }
    }
}

/// @param roleplay 이 턴이 상황극임이 확인됐는지. 참일 때만 따옴표 없는
///   문단을 묘사로 봅니다. 잡담에서는 대사에 따옴표를 치지 않으므로, 이 조건이
///   없으면 평범한 대화가 통째로 묘사가 됩니다.
fun AIService.parseResponseIntoBubbles(
    rawText: String,
    botName: String,
    roleplay: Boolean = false
): List<GeneratedMessageBubble> {
    val clean = rawText.trim()
    var paragraphs = clean.split("\n\n")
    if (paragraphs.size == 1) {
        val lines = clean.split("\n")
        if (lines.any { it.startsWith("$botName:") || it.startsWith("사피엔스:") }) paragraphs = lines
    }

    // 한 번에 받는 경로에서는 답변 전체가 여기 들어오므로, 뒤쪽 문단의 따옴표를
    // 보고 앞쪽 문단까지 제대로 가를 수 있습니다. 스트리밍 경로는 문단이 하나씩
    // 들어오므로 호출하는 쪽이 지금까지 본 것을 `roleplay`로 알려 줍니다.
    val isRoleplay = roleplay || paragraphs.any { RoleplayParser.establishesRoleplay(it) }

    val chunks = paragraphs.flatMap { AIService.splitTextAndComplexMath(it) }
    val bubbles = mutableListOf<GeneratedMessageBubble>()
    for (item in chunks) {
        var text = item.trim()
        for (prefix in listOf("$botName:", "$botName :", "사피엔스:")) {
            if (text.startsWith(prefix)) {
                text = text.removePrefix(prefix).trim()
                break
            }
        }
        val classified = RoleplayParser.classify(text, isRoleplay)
        val (cleanedText, allSpecs) = MathGraphRenderer.extractGraphSpecs(classified.text)
        if (cleanedText.isNotEmpty()) {
            bubbles += GeneratedMessageBubble(cleanedText, kind = classified.kind)
        }
        // 해석하지 못하는 식은 그래프를 만들지 않습니다. 틀린 그림을 내보내는 것보다 낫습니다.
        for (spec in allSpecs.filter { MathGraphRenderer.canRender(it) }) {
            graphAttachment(spec)?.let { bubbles += GeneratedMessageBubble("", attachment = it) }
        }
    }
    if (bubbles.isEmpty() && clean.isNotEmpty()) bubbles += GeneratedMessageBubble(clean)
    return bubbles
}

internal fun AIService.graphAttachment(spec: MathGraphSpec): ChatAttachment? = runCatching {
    val bitmap = MathGraphRenderer.render(spec)
    val stream = ByteArrayOutputStream()
    bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
    val bytes = stream.toByteArray()
    ChatAttachment(
        type = AttachmentType.IMAGE,
        fileName = "${spec.title}.png",
        fileSize = bytes.size.toLong(),
        fileExtension = "png",
        dataBase64 = Base64.encodeToString(bytes, Base64.NO_WRAP),
        mimeType = "image/png"
    )
}.getOrNull()

internal fun splitTextAndComplexMath(paragraph: String): List<String> {
    val lines = paragraph.split("\n")
    if (lines.size <= 1) return listOf(paragraph)

    val result = mutableListOf<String>()
    val buffer = mutableListOf<String>()
    var mathMode: Boolean? = null
    var displayMathClosing: String? = null
    var inTable = false

    fun flush() {
        if (buffer.isEmpty()) return
        result += buffer.joinToString("\n")
        buffer.clear()
    }

    for (line in lines) {
        val trimmed = line.trim()
        if (trimmed.isEmpty()) continue

        val closing = displayMathClosing
        if (closing != null) {
            buffer += trimmed
            if (trimmed == closing) {
                flush()
                displayMathClosing = null
                mathMode = null
            }
            continue
        }

        if (trimmed == "$$" || trimmed == "\\[") {
            flush()
            mathMode = true
            displayMathClosing = if (trimmed == "$$") "$$" else "\\]"
            buffer += trimmed
            continue
        }

        // 표(Markdown Table) 처리: 마크다운 표 행들은 절대 수식 행으로 쪼개지 않고 표 전체를 온전히 유지합니다.
        val isTable = isMarkdownTableLine(trimmed)
        if (isTable) {
            if (!inTable) {
                flush()
                inTable = true
                mathMode = null
            }
            buffer += trimmed
            continue
        } else if (inTable) {
            flush()
            inTable = false
        }

        val isMath = isStandaloneMathLine(trimmed)
        if (mathMode != null && mathMode != isMath) flush()
        mathMode = isMath
        buffer += trimmed
    }
    flush()
    return result.ifEmpty { listOf(paragraph) }
}

internal fun isMarkdownTableLine(line: String): Boolean {
    val trimmed = line.trim()
    if (trimmed.isEmpty()) return false
    if (trimmed.startsWith("|")) return true
    val pipeCount = trimmed.count { it == '|' }
    if (pipeCount >= 2) return true
    if (trimmed.contains("---") && trimmed.contains("|")) return true
    return false
}

internal fun isStandaloneMathLine(line: String): Boolean {
    if (line.startsWith("$$") || line.startsWith("\\[")) return true
    if (line.startsWith("$") && line.endsWith("$") && line.contains("=")) return true
    if (line.contains("=") &&
        listOf("\\frac", "\\cos", "\\sin", "\\int", "\\lim").any { line.contains(it) }
    ) {
        val korean = line.count { it.code in 0xAC00..0xD7A3 }
        return korean <= 3
    }
    return false
}
