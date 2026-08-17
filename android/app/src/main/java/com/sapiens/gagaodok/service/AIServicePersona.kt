package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.data.SecureStore
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.PersonaStyle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

// 말투를 찾고, 뽑고, 다듬고, 미리 들어 보는 길입니다.
// 대화와 달리 캐시를 쓰지 않습니다. 방마다 한 번씩만 일어나는 일이라서입니다.
data class PersonaLookup(
    val confidence: String,   // 높음 / 보통 / 낮음
    val note: String,
    val samples: List<String>,
    val styleGuide: String,
    val sources: List<String>
) {
    val isUsable: Boolean get() = samples.isNotEmpty() || styleGuide.isNotEmpty()
}

internal val LOOKUP_INSTRUCTION = """
너는 말투 조사관이다. 사용자가 지정한 인물의 말투를 조사해 정리한다.

먼저 검색이나 주어진 링크·이미지에서 그 인물의 실제 대사를 찾는다. 그 다음 아래 형식으로만 출력한다.

[확신도] 높음/보통/낮음 중 하나와 한 줄 근거.
- 실제 대사를 여러 개 찾았으면 '높음'
- 인물 설명은 찾았지만 대사가 적으면 '보통'
- 인물을 특정하지 못했으면 '낮음'이라고 솔직히 적고 아래 두 절을 비운다

[대사]
찾은 실제 대사를 한 줄에 하나씩, 최대 20줄. 앞에 기호를 붙이지 않는다.
지어내지 말고 실제로 찾은 것만 적는다. 찾지 못했으면 이 절을 비운다.

[말투]
- 문장 끝맺음:
- 높임 수준:
- 1인칭과 호칭:
- 자주 쓰는 표현:
- 문장 길이와 리듬:
- 감정 표현:
- 피해야 할 것:
- 한 줄 요약:

없는 사실을 지어내지 않는다. 확실하지 않으면 확신도를 낮춘다.
""".trimIndent()

internal val ANALYZE_INSTRUCTION = """
너는 말투 분석가다. 아래 대사를 읽고, 다른 사람이 이 인물의 말투를 그대로 재현할 수 있도록
관찰된 특징만 한국어로 정리한다. 대사에 없는 특징은 지어내지 않는다.

다음 항목을 각각 한 줄씩, '- 항목: 내용' 형태로 쓴다. 해당 없으면 그 줄은 생략한다.
- 문장 끝맺음: 자주 쓰는 어미와 종결 형태를 실제 예와 함께
- 높임 수준: 반말/존댓말/혼용 중 무엇이며 어떤 상황에서 바뀌는지
- 1인칭과 호칭: 자기를 뭐라 부르고 상대를 뭐라 부르는지
- 자주 쓰는 표현: 반복되는 단어·감탄사·말버릇을 원문 그대로
- 문장 길이와 리듬: 짧게 끊는지 길게 이어붙이는지
- 감정 표현: 이모지·물결·느낌표 사용 습관
- 피해야 할 것: 이 인물이 절대 쓰지 않을 법한 말투

마지막에 '- 한 줄 요약:'으로 전체를 한 문장으로 압축한다.
설명이나 인사말 없이 목록만 출력한다.
""".trimIndent()

internal val REFINE_INSTRUCTION = """
너는 말투 규칙 편집자다. 주어진 말투 규칙을 사용자의 요청대로 고친다.

규칙:
- 요청과 관련된 항목만 고치고 나머지는 원래 문장을 그대로 둔다.
- 원래와 같은 '- 항목: 내용' 목록 형식을 유지한다. 항목 이름을 바꾸지 않는다.
- 요청이 기존 관찰과 충돌하면 요청을 따른다. 사용자가 원하는 방향이 우선이다.
- 요청에 없는 내용을 새로 지어내지 않는다.
- 마지막 '- 한 줄 요약:' 항목도 바뀐 내용에 맞게 갱신한다.

설명이나 인사말 없이 고친 목록만 출력한다.
""".trimIndent()

fun parsePersonaLookup(text: String, sources: List<String>): PersonaLookup {
    var confidence = "보통"
    var note = ""
    val samples = mutableListOf<String>()
    val guideLines = mutableListOf<String>()

    var section = 0  // 0: 없음, 1: 대사, 2: 말투

    for (rawLine in text.lines()) {
        val line = rawLine.trim()
        if (line.startsWith("[확신도]")) {
            val body = line.removePrefix("[확신도]").trim()
            for (level in listOf("높음", "보통", "낮음")) {
                if (body.startsWith(level)) {
                    confidence = level
                    note = body.drop(level.length).trim(' ', '-', '–', '—', '(', ')', '·', ',')
                    break
                }
            }
            if (note.isEmpty()) note = body
            section = 0
            continue
        }
        if (line.startsWith("[대사]")) { section = 1; continue }
        if (line.startsWith("[말투]")) { section = 2; continue }
        if (line.isEmpty()) continue

        when (section) {
            1 -> line.trim('-', '•', '*', ' ').trim().takeIf { it.isNotEmpty() }?.let { samples += it }
            2 -> guideLines += line
        }
    }

    return PersonaLookup(
        confidence = confidence,
        note = note,
        samples = samples,
        styleGuide = guideLines.joinToString("\n"),
        sources = sources.distinct().sorted()
    )
}

/// 대사를 외우고 있지 않아도 되도록, 이름이나 링크만으로 말투를 조사합니다.
///
/// 검색 그라운딩과 URL 읽기를 함께 켜므로 이름이든 링크든 같은 입구로 처리됩니다.
/// 모르는 인물이면 지어내지 않고 확신도를 '낮음'으로 돌려줍니다.
/// @param onProgress 지금 무엇이 도착했는지를 알려 줍니다.
///
/// **진행률을 흉내 내지 않습니다.** 이 요청은 오래 걸리는데(검색 → 읽기 → 정리)
/// 예전에는 화면에 "처리 중입니다…" 한 줄만 떠서, 멈춘 것인지 되고 있는 것인지
/// 알 수 없었습니다. 그래서 한 번에 받지 않고 흘려 받으면서, 답변에 실제로
/// 도착한 절([확신도] → [대사] → [말투])을 그대로 알려 줍니다. 시간을 재서
/// 지어낸 단계가 아니라 방금 받은 글자가 근거입니다.
suspend fun AIService.lookupPersona(
    query: String,
    roomId: UUID,
    imageBase64: String? = null,
    imageMimeType: String? = null,
    onProgress: (String) -> Unit = {}
): PersonaLookup = withContext(Dispatchers.IO) {
    val apiKey = SecureStore.apiKey(appContext, SecureStore.Credential.GEMINI)
        ?: throw AIServiceException("설정에서 Gemini API 키를 먼저 등록해주세요.")
    val trimmed = query.trim()
    if (trimmed.isEmpty() && imageBase64 == null) {
        throw AIServiceException("캐릭터 이름이나 참고 링크를 입력해주세요.")
    }

    val parts = JSONArray()
    if (trimmed.isNotEmpty()) parts.put(JSONObject().put("text", "인물 또는 참고 자료: $trimmed"))
    if (imageBase64 != null && imageMimeType != null) {
        parts.put(JSONObject().put("text", "아래 이미지에 이 인물의 대사가 있다. 읽어서 활용한다."))
        parts.put(
            JSONObject().put(
                "inlineData",
                JSONObject().put("mimeType", imageMimeType).put("data", imageBase64)
            )
        )
    }

    val body = JSONObject()
        .put("systemInstruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", LOOKUP_INSTRUCTION))))
        .put("contents", JSONArray().put(JSONObject().put("role", "user").put("parts", parts)))
        // 이름이면 검색이, 링크가 섞여 있으면 URL 읽기가 각각 동작합니다.
        .put("tools", JSONArray().put(JSONObject().put("google_search", JSONObject()))
            .put(JSONObject().put("url_context", JSONObject())))
        .put(
            "generationConfig",
            JSONObject().put("maxOutputTokens", 4096)
                .put("thinkingConfig", JSONObject().put("thinkingLevel", "medium"))
        )

    onProgress("자료를 찾고 있습니다…")
    val result = streamGeminiText(body, apiKey, roomId) { soFar ->
        onProgress(AIService.lookupProgressLabel(soFar))
    }
    if (result.text.isEmpty()) {
        throw AIServiceException(emptyResponseMessage(result.finishReason))
    }
    parsePersonaLookup(result.text, result.sources)
}

/// 저장하기 전에 이 말투가 실제 그 캐릭터 같은지 확인할 수 있도록 짧은 답변을 만듭니다.
/// 실제 대화와 똑같은 시스템 지침을 쓰므로, 여기서 보이는 결이 채팅방에서도 그대로 나옵니다.
suspend fun AIService.previewPersona(
    roomId: UUID,
    persona: PersonaStyle,
    botName: String,
    message: String,
    mode: ChatMode
): String = withContext(Dispatchers.IO) {
    val apiKey = SecureStore.apiKey(appContext, SecureStore.Credential.GEMINI)
        ?: throw AIServiceException("설정에서 Gemini API 키를 먼저 등록해주세요.")
    val system = systemPrompt(botName, persona.copy(isEnabled = true), mode)

    val body = JSONObject()
        .put("systemInstruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", system))))
        .put(
            "contents",
            JSONArray().put(
                JSONObject().put("role", "user")
                    .put("parts", JSONArray().put(JSONObject().put("text", message)))
            )
        )
        .put(
            "generationConfig",
            JSONObject().put("maxOutputTokens", 2048)
                .put("thinkingConfig", JSONObject().put("thinkingLevel", "low"))
        )
        .apply {
            // 미리보기도 실제 대화와 같은 조건이어야 결을 판단할 수 있습니다.
            mode.geminiSafetyCategories?.let { categories ->
                put("safetySettings", JSONArray().apply {
                    categories.forEach {
                        put(JSONObject().put("category", it).put("threshold", "BLOCK_NONE"))
                    }
                })
            }
        }

    val json = postGemini(body, apiKey, roomId)
    val candidate = json.optJSONArray("candidates")?.optJSONObject(0)
        ?: throw AIServiceException("미리보기를 읽을 수 없습니다.")
    val text = joinParts(candidate).trim()
    if (text.isEmpty()) {
        throw AIServiceException(emptyResponseMessage(candidate.optString("finishReason")))
    }
    text
}

/// 붙여넣은 대사에서 말투 규칙을 뽑아냅니다.
///
/// 모델에게 "이 캐릭터처럼 말해"라고만 하면 흉내가 흐려집니다.
/// 관찰 가능한 항목(문장 끝맺음, 호칭, 자주 쓰는 어휘, 문장 길이 등)을 짚어서 적게 하면
/// 이후 대화에서 재현이 훨씬 안정적입니다.
suspend fun AIService.analyzePersonaStyle(roomId: UUID, description: String, samples: List<String>): String =
    withContext(Dispatchers.IO) {
        val apiKey = SecureStore.apiKey(appContext, SecureStore.Credential.GEMINI)
            ?: throw AIServiceException("설정에서 Gemini API 키를 먼저 등록해주세요.")
        val joined = samples.map { it.trim() }.filter { it.isNotEmpty() }.joinToString("\n")
        if (joined.isEmpty()) throw AIServiceException("말투를 분석할 대사를 먼저 입력해주세요.")

        var userText = ""
        if (description.isNotBlank()) userText += "인물 설명: ${description.trim()}\n\n"
        userText += "대사:\n$joined"

        val body = JSONObject()
            .put("systemInstruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", ANALYZE_INSTRUCTION))))
            .put(
                "contents",
                JSONArray().put(
                    JSONObject().put("role", "user")
                        .put("parts", JSONArray().put(JSONObject().put("text", userText)))
                )
            )
            .put(
                "generationConfig",
                JSONObject().put("maxOutputTokens", 2048)
                    .put("thinkingConfig", JSONObject().put("thinkingLevel", "low"))
            )

        val candidate = postGemini(body, apiKey, roomId).optJSONArray("candidates")?.optJSONObject(0)
            ?: throw AIServiceException("말투 분석 결과를 읽을 수 없습니다.")
        joinParts(candidate).trim().ifEmpty {
            throw AIServiceException(emptyResponseMessage(candidate.optString("finishReason")))
        }
    }

/// 뽑아낸 말투 규칙을 사용자의 요청대로 손봅니다.
///
/// 자동 추출은 관찰된 사실만 담기 때문에, 실제로 쓰다 보면
/// "좀 더 딱딱하게", "이모지 빼줘" 같은 조정이 필요합니다.
/// 원래 규칙을 통째로 다시 쓰지 않고 요청한 부분만 반영합니다.
suspend fun AIService.refinePersonaStyle(
    roomId: UUID,
    currentGuide: String,
    instruction: String,
    description: String,
    samples: List<String>
): String = withContext(Dispatchers.IO) {
    val apiKey = SecureStore.apiKey(appContext, SecureStore.Credential.GEMINI)
        ?: throw AIServiceException("설정에서 Gemini API 키를 먼저 등록해주세요.")
    if (instruction.isBlank()) throw AIServiceException("어떻게 고칠지 입력해주세요.")
    if (currentGuide.isBlank()) throw AIServiceException("먼저 말투 규칙을 만들어주세요.")

    var userText = "현재 말투 규칙:\n${currentGuide.trim()}\n\n"
    if (description.isNotBlank()) userText += "인물: ${description.trim()}\n\n"
    if (samples.isNotEmpty()) {
        userText += "참고용 실제 대사:\n" + samples.take(20).joinToString("\n") + "\n\n"
    }
    userText += "고쳐줬으면 하는 방향:\n${instruction.trim()}"

    val body = JSONObject()
        .put("systemInstruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", REFINE_INSTRUCTION))))
        .put(
            "contents",
            JSONArray().put(
                JSONObject().put("role", "user")
                    .put("parts", JSONArray().put(JSONObject().put("text", userText)))
            )
        )
        .put(
            "generationConfig",
            JSONObject().put("maxOutputTokens", 2560)
                .put("thinkingConfig", JSONObject().put("thinkingLevel", "low"))
        )

    val candidate = postGemini(body, apiKey, roomId).optJSONArray("candidates")?.optJSONObject(0)
        ?: throw AIServiceException("교정 결과를 읽을 수 없습니다.")
    joinParts(candidate).trim().ifEmpty {
        throw AIServiceException(emptyResponseMessage(candidate.optString("finishReason")))
    }
}

// MARK: - OpenAI
