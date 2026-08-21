package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.model.PersonaSampleEvidence
import com.sapiens.gagaodok.model.PersonaSourceTier
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.max

internal const val PERSONA_COLLECTION_TARGET = 40
internal const val PERSONA_COLLECTION_LIMIT = 48
internal const val PERSONA_ANALYSIS_LIMIT = 40
internal const val PERSONA_RUNTIME_LIMIT = 8
internal const val PERSONA_RUNTIME_TOKEN_BUDGET = 900

data class PersonaSourceCandidate(
    val tier: PersonaSourceTier,
    val url: String,
    val publisher: String,
    val title: String,
    val language: String,
    val edition: String,
    val officialityReason: String,
    val durationSeconds: Int? = null
) {
    val isYouTube: Boolean
        get() = url.contains("youtube.com/", ignoreCase = true) ||
            url.contains("youtu.be/", ignoreCase = true)
}

data class PersonaVideoInput(val url: String, val analysisSeconds: Int, val isClipped: Boolean)

internal fun parsePersonaSources(text: String): List<PersonaSourceCandidate> = text.lines()
    .dropWhile { !it.trim().startsWith("[출처]") }
    .drop(1)
    .takeWhile { !it.trim().startsWith("[") }
    .mapNotNull { raw ->
        val fields = raw.trim().trim('-', '•', ' ').replace("\\t", "\t").split('\t')
        if (fields.size < 3) return@mapNotNull null
        val tier = runCatching { PersonaSourceTier.valueOf(fields[0].trim()) }.getOrNull()
            ?: return@mapNotNull null
        val url = fields[1].trim()
        if (!url.startsWith("https://") && !url.startsWith("http://")) return@mapNotNull null
        PersonaSourceCandidate(
            tier = tier,
            url = url,
            publisher = fields.getOrElse(2) { "" }.trim(),
            title = fields.getOrElse(3) { "" }.trim(),
            language = fields.getOrElse(4) { "" }.trim(),
            edition = fields.getOrElse(5) { "" }.trim(),
            officialityReason = fields.getOrElse(6) { "" }.trim(),
            durationSeconds = fields.getOrNull(7)?.trim()?.toIntOrNull()
        )
    }
    .distinctBy { canonicalSourceUrl(it.url) }
    .sortedWith(compareBy<PersonaSourceCandidate> { it.tier.priority }.thenBy { it.url })
    .take(8)

internal fun parsePersonaEvidence(
    text: String,
    allowedSourceUrls: Set<String> = emptySet(),
    sourceCandidates: List<PersonaSourceCandidate> = emptyList()
): List<PersonaSampleEvidence> = text.lines()
    .dropWhile { !it.trim().startsWith("[대사]") }
    .drop(1)
    .takeWhile { !it.trim().startsWith("[") }
    .mapNotNull { raw ->
        val fields = raw.trim().trim('-', '•', ' ').replace("\\t", "\t").split('\t')
        if (fields.size < 4) return@mapNotNull null
        val quote = fields[3].trim().trim('"', '“', '”', '「', '」')
        val sourceUrl = fields.getOrElse(4) { "" }.trim()
        if (quote.isEmpty() || quote == "대사 원문") return@mapNotNull null
        val source = sourceCandidates.firstOrNull {
            canonicalSourceUrl(it.url) == canonicalSourceUrl(sourceUrl)
        }
        val allowedCanonical = allowedSourceUrls.map(::canonicalSourceUrl).toSet()
        if (allowedCanonical.isNotEmpty() && canonicalSourceUrl(sourceUrl) !in allowedCanonical) return@mapNotNull null
        if (sourceCandidates.isNotEmpty() && source == null) return@mapNotNull null
        PersonaSampleEvidence(
            timestampSeconds = parseTimestampSeconds(fields[0]),
            contextTag = fields.getOrElse(1) { "" }.trim(),
            speaker = fields.getOrElse(2) { "" }.trim(),
            text = quote,
            sourceUrl = sourceUrl,
            sourceTitle = source?.title ?: fields.getOrElse(5) { "" }.trim(),
            sourceTier = source?.tier ?: runCatching {
                PersonaSourceTier.valueOf(fields.getOrElse(6) { "" }.trim())
            }.getOrDefault(PersonaSourceTier.UNVERIFIED),
            edition = source?.edition ?: fields.getOrElse(7) { "" }.trim(),
            language = source?.language ?: fields.getOrElse(8) { "" }.trim(),
            confidence = fields.getOrElse(9) { "" }.trim()
        )
    }

private fun parseTimestampSeconds(value: String): Int? {
    val pieces = value.trim().split(':').mapNotNull { it.toIntOrNull() }
    return when (pieces.size) {
        2 -> pieces[0] * 60 + pieces[1]
        3 -> pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
        else -> null
    }
}

internal fun buildPersonaExtractionParts(
    sources: List<PersonaSourceCandidate>,
    query: String
): JSONArray = JSONArray().apply {
    val videoInputs = personaVideoInputs(sources)
    val videoUrls = videoInputs.map { it.url }
    videoInputs.forEach { video ->
        put(
            JSONObject()
                .put("fileData", JSONObject().put("fileUri", video.url))
                .apply {
                    if (video.isClipped) {
                        put("videoMetadata", JSONObject().put("endOffset", "${video.analysisSeconds}s"))
                    }
                }
        )
    }
    val sourceLedger = sources.filter { !it.isYouTube || it.url in videoUrls }.joinToString("\n") {
        "${it.tier}\t${it.url}\t${it.publisher}\t${it.title}\t${it.language}\t${it.edition}"
    }
    put(
        JSONObject().put(
            "text",
            "인물: ${query.trim()}\n\n검증할 출처:\n$sourceLedger\n\n" +
                "공식 한국 영상에서는 음성을 임의 번역하지 말고 화면의 공식 한국어 자막을 우선한다."
        )
    )
}

internal fun personaVideoInputs(sources: List<PersonaSourceCandidate>): List<PersonaVideoInput> = buildList {
    var remainingSeconds = 15 * 60
    sources.filter { it.isYouTube && it.tier.priority <= PersonaSourceTier.OFFICIAL_TEXT.priority }
        .sortedBy { it.tier.priority }
        .distinctBy { canonicalSourceUrl(it.url) }
        .forEach { source ->
            if (size >= 5 || remainingSeconds <= 0) return@forEach
            val duration = source.durationSeconds?.takeIf { it > 0 }
            val analysisSeconds = minOf(duration ?: remainingSeconds, remainingSeconds)
            add(PersonaVideoInput(source.url, analysisSeconds, duration == null || duration > analysisSeconds))
            remainingSeconds -= analysisSeconds
        }
}

internal fun personaVideoUrls(sources: List<PersonaSourceCandidate>): List<String> =
    personaVideoInputs(sources).map { it.url }

internal fun selectPersonaEvidence(
    evidence: List<PersonaSampleEvidence>,
    limit: Int = PERSONA_COLLECTION_LIMIT
): List<PersonaSampleEvidence> {
    val cleaned = evidence.filter { it.text.isNotBlank() }
    val bestOfficialTier = cleaned.minOfOrNull { it.sourceTier.priority }?.takeIf { it <= 2 }
    val eligible = if (bestOfficialTier != null) cleaned.filter { it.sourceTier.priority == bestOfficialTier } else cleaned
    val selected = mutableListOf<PersonaSampleEvidence>()
    eligible.sortedWith(
        compareBy<PersonaSampleEvidence> { it.sourceTier.priority }
            .thenByDescending { confidenceRank(it.confidence) }
            .thenBy { it.sourceUrl }
            .thenBy { it.timestampSeconds ?: Int.MAX_VALUE }
    ).forEach { candidate ->
        if (selected.size >= limit) return@forEach
        val duplicateIndex = selected.indexOfFirst { isDuplicatePersonaLine(it, candidate) }
        if (duplicateIndex < 0) {
            selected += candidate
        } else {
            val existing = selected[duplicateIndex]
            selected[duplicateIndex] = existing.copy(
                similarSampleCount = existing.similarSampleCount + max(1, candidate.similarSampleCount)
            )
        }
    }
    return diversifyEvidence(selected, limit)
}

internal fun selectAnalysisEvidence(evidence: List<PersonaSampleEvidence>): List<PersonaSampleEvidence> =
    diversifyEvidence(selectPersonaEvidence(evidence), PERSONA_ANALYSIS_LIMIT)

internal fun selectRuntimePersonaSamples(
    samples: List<String>,
    evidence: List<PersonaSampleEvidence> = emptyList()
): List<String> {
    val reconciled = reconcilePersonaEvidence(samples, evidence)
    val ordered = if (reconciled.isNotEmpty()) {
        diversifyEvidence(reconciled, PERSONA_COLLECTION_LIMIT).map { it.text } +
            samples.filter { sample -> reconciled.none { normalizePersonaLine(it.text) == normalizePersonaLine(sample) } }
    } else {
        diversifyTexts(samples)
    }
    var estimatedTokens = 0
    return buildList {
        ordered.forEach { raw ->
            val sample = raw.trim()
            if (sample.isEmpty() || size >= PERSONA_RUNTIME_LIMIT) return@forEach
            val tokens = TokenEstimator.textTokens(sample)
            if (estimatedTokens + tokens > PERSONA_RUNTIME_TOKEN_BUDGET) return@forEach
            if (none { normalizePersonaLine(it) == normalizePersonaLine(sample) }) {
                add(sample)
                estimatedTokens += tokens
            }
        }
    }
}

internal fun reconcilePersonaEvidence(
    samples: List<String>,
    evidence: List<PersonaSampleEvidence>
): List<PersonaSampleEvidence> {
    val current = samples.map { it.trim() }.toSet()
    return evidence.filter { it.text.trim() in current }
}

private fun diversifyEvidence(
    evidence: List<PersonaSampleEvidence>,
    limit: Int
): List<PersonaSampleEvidence> {
    if (evidence.size <= 1) return evidence.take(limit)
    val remaining = evidence.toMutableList()
    val selected = mutableListOf<PersonaSampleEvidence>()
    while (remaining.isNotEmpty() && selected.size < limit) {
        val next = remaining.maxBy { candidate -> diversityScore(candidate, selected) }
        selected += next
        remaining -= next
    }
    return selected
}

private fun diversityScore(candidate: PersonaSampleEvidence, selected: List<PersonaSampleEvidence>): Int {
    if (selected.isEmpty()) return 100 - candidate.sourceTier.priority
    val sourceNovelty = if (selected.none { it.sourceUrl == candidate.sourceUrl }) 12 else 0
    val contextNovelty = if (candidate.contextTag.isNotBlank() && selected.none { it.contextTag == candidate.contextTag }) 10 else 0
    val ending = normalizePersonaLine(candidate.text).takeLast(4)
    val endingNovelty = if (selected.none { normalizePersonaLine(it.text).takeLast(4) == ending }) 6 else 0
    val lengthBucket = candidate.text.length / 20
    val lengthNovelty = if (selected.none { it.text.length / 20 == lengthBucket }) 4 else 0
    val start = normalizePersonaLine(candidate.text).take(8)
    val startNovelty = if (selected.none { normalizePersonaLine(it.text).take(8) == start }) 8 else 0
    return sourceNovelty + contextNovelty + endingNovelty + lengthNovelty + startNovelty - candidate.sourceTier.priority
}

private fun diversifyTexts(samples: List<String>): List<String> {
    val unique = samples.map { it.trim() }.filter { it.isNotEmpty() }
        .distinctBy(::normalizePersonaLine)
    return unique.sortedWith(compareBy<String> { normalizePersonaLine(it).take(8) }.thenBy { it.length })
        .groupBy { normalizePersonaLine(it).take(8) }
        .values
        .flatMapIndexed { index, group -> group.mapIndexed { inner, value -> Triple(inner, index, value) } }
        .sortedWith(compareBy<Triple<Int, Int, String>> { it.first }.thenBy { it.second })
        .map { it.third }
}

private fun isDuplicatePersonaLine(a: PersonaSampleEvidence, b: PersonaSampleEvidence): Boolean {
    val left = normalizePersonaLine(a.text)
    val right = normalizePersonaLine(b.text)
    if (left == right) return true
    if (a.edition.isNotBlank() && b.edition.isNotBlank() && a.edition != b.edition) return false
    if (max(left.length, right.length) < 14 || left.take(8) != right.take(8)) return false
    return ngramJaccard(left, right) >= 0.62
}

private fun ngramJaccard(left: String, right: String): Double {
    val a = left.windowed(2).toSet()
    val b = right.windowed(2).toSet()
    if (a.isEmpty() || b.isEmpty()) return 0.0
    return a.intersect(b).size.toDouble() / a.union(b).size
}

private fun normalizePersonaLine(value: String): String = value.lowercase()
    .replace(Regex("[\\s\\p{Punct}·…‘’“”「」『』]+"), "")

private fun canonicalSourceUrl(value: String): String {
    val lower = value.trim().lowercase()
    val youtubeId = when {
        "youtu.be/" in lower -> lower.substringAfter("youtu.be/").substringBefore('?').substringBefore('/')
        "youtube.com/watch" in lower -> lower.substringAfter("v=", "").substringBefore('&')
        else -> ""
    }
    if (youtubeId.isNotEmpty()) return "youtube:$youtubeId"
    return lower.substringBefore('#').substringBefore('?').trimEnd('/')
}

private fun confidenceRank(confidence: String): Int = when (confidence) {
    "높음" -> 2
    "보통" -> 1
    else -> 0
}
