package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.BuildConfig
import com.sapiens.gagaodok.data.SecureStore
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.PersonaSampleEvidence
import com.sapiens.gagaodok.model.PersonaSourceTier
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
    val sources: List<String>,
    val evidence: List<PersonaSampleEvidence> = emptyList()
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

private val COMPANION_LOOKUP_SUFFIX = """
챗봇 말투를 위한 분석에서는 대표 문구를 암기시키지 않는다. 문장 구조와 리듬, 호칭, 감정 표현을 우선한다.
표현마다 항상/자주/가끔/드물게의 빈도를 구분하고, 한 번만 나온 표현이나 중복 표본을 말버릇으로 단정하지 않는다.
같은 시작 표현을 여러 대사에 반복해서 싣지 말고, 실제로 확인된 서로 다른 표본을 충분히 수집한다.
""".trimIndent()

internal val PERSONA_SOURCE_DISCOVERY_INSTRUCTION = """
너는 애니메이션 캐릭터 말투 조사의 원출처 탐색기다. 특정 작품이나 캐릭터를 우대하지 않는다.
Google 검색 결과를 거꾸로 원출처까지 추적해 최대 8개만 고른다.

우선순위:
1. OFFICIAL_LOCALIZED_VIDEO: 한국 공식 배급사·제작사·방송사 영상과 공식 한국어 자막
2. OFFICIAL_ORIGINAL_VIDEO: 원 제작사·공식 작품 채널의 원어 영상
3. OFFICIAL_TEXT: 공식 사이트·출판물·대본·인터뷰
4. REPUTABLE_SECONDARY: 신뢰 가능한 언론·데이터베이스의 직접 인용
5. UNVERIFIED: 위키·커뮤니티·밈·원출처 불명 문구

채널명에 '공식'이 있다는 이유만으로 공식 등급을 주지 말고 소유자·배급권 근거를 확인한다.
동명이인, 작품·시즌·극장판/TV판, 더빙·자막 판본을 구분한다.
공식 자료가 있으면 위키나 밈을 대사 증거로 채우지 않는다.

아래 형식만 출력한다. 각 필드는 실제 탭 문자로 나눈다.
[확신도] 높음/보통/낮음 - 한 줄 근거
[출처]
등급<TAB>전체 URL<TAB>게시자<TAB>제목<TAB>언어<TAB>판본<TAB>공식성 근거<TAB>영상 길이(초, 아니거나 모르면 빈칸)
""".trimIndent()

internal val PERSONA_EVIDENCE_EXTRACTION_INSTRUCTION = """
너는 공식 자료에서 캐릭터의 실제 발화만 옮기는 증거 추출기다.
목표는 서로 다른 대사 40개, 최대 48개이며 공식 자료가 부족하면 개수를 지어내지 않는다.

- 영상에서는 지정된 인물이 실제로 말한 문장만 고르고 화자가 불명확하면 제외한다.
- 한국 공식 영상은 음성을 새로 번역하지 말고 화면의 공식 한국어 자막을 최우선으로 읽는다.
- 자막과 음성이 충돌하면 화면 자막을 보존한다.
- 밈, 댓글, 요약문, 팬 번역, 다른 인물의 말은 실제 대사로 넣지 않는다.
- 같은 자막 조각은 논리적인 한 발화로 합치고, 공백·문장부호만 다른 중복은 하나만 둔다.
- 평상시·질문·동의·거절·장난·친밀함·분노·당황 등 서로 다른 상황을 넓게 고른다.

아래 형식만 출력한다. 각 필드는 실제 탭 문자로 나누고 대사 안의 탭과 줄바꿈은 공백으로 바꾼다.
[확신도] 높음/보통/낮음 - 한 줄 근거
[대사]
MM:SS<TAB>상황 태그<TAB>화자<TAB>대사 원문<TAB>출처 전체 URL<TAB>출처 제목<TAB>출처 등급<TAB>판본<TAB>언어<TAB>추출 확신도
""".trimIndent()

internal val ANALYZE_INSTRUCTION = """
너는 말투 분석가다. 아래 대사를 읽고, 다른 사람이 이 인물의 말투를 그대로 재현할 수 있도록
관찰된 특징만 한국어로 정리한다. 대사에 없는 특징은 지어내지 않는다.

다음 항목을 각각 한 줄씩, '- 항목: 내용' 형태로 쓴다. 해당 없으면 그 줄은 생략한다.
- 문장 끝맺음: 항상/자주/가끔/드물게 중 빈도와 함께, 어미와 종결 형태를 실제 예와 함께
- 높임 수준: 반말/존댓말/혼용 중 무엇이며 어떤 상황에서 바뀌는지
- 1인칭과 호칭: 자기를 뭐라 부르고 상대를 뭐라 부르는지
- 표현 빈도: 항상/자주/가끔/드물게로 구분하고, 표본에 한 번만 나온 것을 말버릇으로 단정하지 않기
- 표본 중복: 같은 내용이 반복된 표본은 하나로 보고, 중복이 특징의 빈도를 부풀리지 않기
- 문장 구조와 리듬: 절과 문장 길이, 끊는 위치, 반복되는 구조를 우선해 설명하기
- 감정 표현: 이모지·물결·느낌표 사용 습관과 강도
- 피해야 할 것: 이 인물이 절대 쓰지 않을 법한 말투

마지막에 '- 한 줄 요약:'으로 전체를 한 문장으로 압축한다.
빈도 판정은 관찰 횟수/관련 표본 수와 서로 다른 상황 수를 함께 쓴다. '항상'은 관련 표본 전부와 3개 이상 상황에서
일관될 때만, '자주'는 절반 이상이면서 3개 이상 상황일 때만 쓴다. 한 상황에서만 보이면 '드물게'로 적는다.
대표 문구 자체보다 문장 구조·호흡·리듬, 호칭·높임 전환, 감정별 표현 강도를 앞에 둔다.
설명이나 인사말 없이 목록만 출력한다.
""".trimIndent()

private val MENTOR_ANALYZE_INSTRUCTION = """
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

fun parsePersonaLookup(text: String, sources: List<String>, sampleLimit: Int = 20): PersonaLookup {
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
        samples = samples
            .distinctBy { it.lowercase().replace(Regex("\\s+"), " ") }
            .take(sampleLimit),
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
    mode: ChatMode = ChatMode.MATH_MENTOR,
    onProgress: (String) -> Unit = {}
): PersonaLookup = withContext(Dispatchers.IO) {
    val apiKey = SecureStore.apiKey(appContext, SecureStore.Credential.GEMINI)
        ?: throw AIServiceException("설정에서 Gemini API 키를 먼저 등록해주세요.")
    val trimmed = query.trim()
    if (trimmed.isEmpty() && imageBase64 == null) {
        throw AIServiceException("캐릭터 이름이나 참고 링크를 입력해주세요.")
    }

    val companionControls = !BuildConfig.TABLET_MENTOR && mode == ChatMode.COMPANION
    if (companionControls && imageBase64 == null) {
        return@withContext lookupCompanionPersona(trimmed, roomId, apiKey, onProgress)
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
            .put(
                "systemInstruction",
                JSONObject().put(
                    "parts",
                    JSONArray().put(
                        JSONObject().put(
                            "text",
                            if (!BuildConfig.TABLET_MENTOR && mode == ChatMode.COMPANION) {
                                "$LOOKUP_INSTRUCTION\n\n$COMPANION_LOOKUP_SUFFIX"
                            } else {
                                LOOKUP_INSTRUCTION
                            }
                        )
                    )
                )
            )
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

private suspend fun AIService.lookupCompanionPersona(
    query: String,
    roomId: UUID,
    apiKey: String,
    onProgress: (String) -> Unit
): PersonaLookup {
    onProgress("공식 출처를 찾고 있습니다…")
    val discoveryBody = JSONObject()
        .put(
            "systemInstruction",
            JSONObject().put("parts", JSONArray().put(JSONObject().put("text", PERSONA_SOURCE_DISCOVERY_INSTRUCTION)))
        )
        .put(
            "contents",
            JSONArray().put(
                JSONObject().put("role", "user").put(
                    "parts", JSONArray().put(JSONObject().put("text", "조사할 인물 또는 참고 자료: $query"))
                )
            )
        )
        .put(
            "tools",
            JSONArray().put(JSONObject().put("google_search", JSONObject()))
                .put(JSONObject().put("url_context", JSONObject()))
        )
        .put(
            "generationConfig",
            JSONObject().put("maxOutputTokens", 3072)
                .put("thinkingConfig", JSONObject().put("thinkingLevel", "medium"))
        )
    val discoveryCandidate = postGemini(discoveryBody, apiKey, roomId)
        .optJSONArray("candidates")?.optJSONObject(0)
    val discoveryText = discoveryCandidate?.let { joinParts(it) }.orEmpty()
    val sources = parsePersonaSources(discoveryText)

    if (sources.isEmpty()) {
        return PersonaLookup(
            confidence = "낮음",
            note = "검증 가능한 원출처를 찾지 못했습니다. 기존 말투는 바꾸지 않습니다.",
            samples = emptyList(),
            styleGuide = "",
            sources = emptyList()
        )
    }

    val bestOfficial = sources.minOfOrNull { it.tier.priority }?.takeIf { it <= 2 }
    val extractionSources = (if (bestOfficial != null) {
        sources.filter { it.tier.priority == bestOfficial }
    } else {
        sources.filter { it.tier != PersonaSourceTier.UNVERIFIED }.ifEmpty { sources }
    }).take(8)

    onProgress(
        if (personaVideoUrls(extractionSources).isNotEmpty()) "공식 영상 자막을 읽고 있습니다…"
        else "공식 문서에서 대사를 확인하고 있습니다…"
    )
    fun extractionBody(forSources: List<PersonaSourceCandidate>): JSONObject = JSONObject()
            .put(
                "systemInstruction",
                JSONObject().put("parts", JSONArray().put(JSONObject().put("text", PERSONA_EVIDENCE_EXTRACTION_INSTRUCTION)))
            )
            .put(
                "contents",
                JSONArray().put(
                    JSONObject().put("role", "user")
                        .put("parts", buildPersonaExtractionParts(forSources, query))
                )
            )
            .apply {
                if (forSources.any { !it.isYouTube }) {
                    put("tools", JSONArray().put(JSONObject().put("url_context", JSONObject())))
                }
            }
            .put(
                "generationConfig",
                JSONObject().put("maxOutputTokens", GEMINI_MAX_OUTPUT_TOKENS)
                    .put("thinkingConfig", JSONObject().put("thinkingLevel", "medium"))
            )

    suspend fun extract(forSources: List<PersonaSourceCandidate>): TextStreamResult = streamGeminiText(
        extractionBody(forSources), apiKey, roomId
    ) { soFar -> onProgress(AIService.lookupProgressLabel(soFar)) }

    val textSources = extractionSources.filter { !it.isYouTube }.ifEmpty {
        sources.filter { !it.isYouTube && it.tier.priority <= PersonaSourceTier.OFFICIAL_TEXT.priority }
            .take(8)
    }
    var usedSources = extractionSources
    var extraction = runCatching { extract(usedSources) }.getOrElse { error ->
        if (textSources.isEmpty()) throw error
        onProgress("영상 대신 공식 문서를 확인하고 있습니다…")
        usedSources = textSources
        extract(usedSources)
    }
    fun parsedEvidence(): List<PersonaSampleEvidence> {
        val accessibleSourceUrls = personaVideoUrls(usedSources).toSet() +
            usedSources.filter { !it.isYouTube }.map { it.url }
        return selectPersonaEvidence(
            parsePersonaEvidence(
                extraction.text,
                allowedSourceUrls = accessibleSourceUrls,
                sourceCandidates = usedSources
            )
        )
    }
    var evidence = parsedEvidence()
    if (evidence.isEmpty() && usedSources.any { it.isYouTube } && textSources.isNotEmpty()) {
        onProgress("영상에서 대사를 확인하지 못해 공식 문서를 확인하고 있습니다…")
        usedSources = textSources
        extraction = extract(usedSources)
        evidence = parsedEvidence()
    }
    if (evidence.isEmpty()) {
        return PersonaLookup(
            confidence = "낮음",
            note = "원출처에서 해당 인물의 대사를 확인하지 못했습니다. 기존 말투는 바꾸지 않습니다.",
            samples = emptyList(),
            styleGuide = "",
            sources = usedSources.map { it.url }.distinct()
        )
    }

    onProgress("확인한 ${evidence.size}줄로 말투 규칙을 만들고 있습니다…")
    val guide = analyzePersonaStyle(roomId, query, evidence.map { it.text }, ChatMode.COMPANION, evidence)
    val confidenceLine = extraction.text.lineSequence()
        .firstOrNull { it.trim().startsWith("[확신도]") }.orEmpty()
    val confidence = listOf("높음", "보통", "낮음")
        .firstOrNull { confidenceLine.substringAfter("[확신도]").trim().startsWith(it) } ?: "보통"
    val note = confidenceLine.substringAfter(confidence, "").trim(' ', '-', '–', '—', '·')
    return PersonaLookup(
        confidence = confidence,
        note = note.ifBlank { "원출처가 연결된 대사 ${evidence.size}줄을 확인했습니다." },
        samples = evidence.map { it.text },
        styleGuide = guide,
        sources = evidence.map { it.sourceUrl }.filter { it.isNotBlank() }.distinct(),
        evidence = evidence
    )
}

/// 저장하기 전에 이 말투가 실제 그 캐릭터 같은지 확인할 수 있도록 짧은 답변을 만듭니다.
/// 실제 대화와 똑같은 시스템 지침을 쓰므로, 여기서 보이는 결이 채팅방에서도 그대로 나옵니다.
internal suspend fun AIService.previewPersona(
    roomId: UUID,
    persona: PersonaStyle,
    botName: String,
    message: String,
    mode: ChatMode,
    repetitionAdvice: RepetitionAdvice? = null
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
                    .put(
                        "parts",
                        JSONArray().put(
                            JSONObject().put(
                                "text",
                                repetitionAdvice?.promptSection()?.let { "$message\n\n$it" } ?: message
                            )
                        )
                    )
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
suspend fun AIService.analyzePersonaStyle(
    roomId: UUID,
    description: String,
    samples: List<String>,
    mode: ChatMode = ChatMode.MATH_MENTOR,
    evidence: List<PersonaSampleEvidence> = emptyList()
): String =
    withContext(Dispatchers.IO) {
        val apiKey = SecureStore.apiKey(appContext, SecureStore.Credential.GEMINI)
            ?: throw AIServiceException("설정에서 Gemini API 키를 먼저 등록해주세요.")
        val companionControls = !BuildConfig.TABLET_MENTOR && mode == ChatMode.COMPANION
        val cleanedSamples = if (companionControls) {
            val linked = reconcilePersonaEvidence(samples, evidence)
            if (linked.isNotEmpty()) selectAnalysisEvidence(linked).map { it.text }
            else selectPersonaEvidence(samples.map { PersonaSampleEvidence(text = it) }, PERSONA_ANALYSIS_LIMIT)
                .map { it.text }
        } else {
            samples.map { it.trim() }.filter { it.isNotEmpty() }
        }
        val joined = cleanedSamples.joinToString("\n")
        if (joined.isEmpty()) throw AIServiceException("말투를 분석할 대사를 먼저 입력해주세요.")

        var userText = ""
        if (description.isNotBlank()) userText += "인물 설명: ${description.trim()}\n\n"
        userText += "대사:\n$joined"
        if (companionControls && evidence.isNotEmpty()) {
            val selectedEvidence = selectAnalysisEvidence(reconcilePersonaEvidence(cleanedSamples, evidence))
            userText += "\n\n표본 근거(등급 / 상황 / 유사표본 수 / 판본 / 출처):\n" + selectedEvidence.joinToString("\n") {
                "${it.sourceTier} / ${it.contextTag.ifBlank { "미상" }} / ${it.similarSampleCount} / " +
                    "${it.edition.ifBlank { "미상" }} / ${it.sourceUrl}"
            }
        }

        val body = JSONObject()
            .put(
                "systemInstruction",
                JSONObject().put(
                    "parts",
                    JSONArray().put(
                        JSONObject().put(
                            "text",
                            if (companionControls) ANALYZE_INSTRUCTION else MENTOR_ANALYZE_INSTRUCTION
                        )
                    )
                )
            )
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
