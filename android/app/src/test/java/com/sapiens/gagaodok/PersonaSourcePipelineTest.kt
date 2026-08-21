package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.Codec
import com.sapiens.gagaodok.model.PersonaSampleEvidence
import com.sapiens.gagaodok.model.PersonaSourceTier
import com.sapiens.gagaodok.model.PersonaStyle
import com.sapiens.gagaodok.service.PersonaSourceCandidate
import com.sapiens.gagaodok.service.parsePersonaEvidence
import com.sapiens.gagaodok.service.parsePersonaSources
import com.sapiens.gagaodok.service.personaVideoUrls
import com.sapiens.gagaodok.service.personaVideoInputs
import com.sapiens.gagaodok.service.reconcilePersonaEvidence
import com.sapiens.gagaodok.service.selectAnalysisEvidence
import com.sapiens.gagaodok.service.selectPersonaEvidence
import com.sapiens.gagaodok.service.selectRuntimePersonaSamples
import kotlinx.serialization.decodeFromString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PersonaSourcePipelineTest {
    private fun evidence(
        text: String,
        tier: PersonaSourceTier = PersonaSourceTier.OFFICIAL_LOCALIZED_VIDEO,
        source: String = "https://youtube.com/watch?v=official",
        edition: String = "한국 공식 자막",
        context: String = "평상시"
    ) = PersonaSampleEvidence(
        text = text,
        speaker = "인물",
        sourceUrl = source,
        sourceTitle = "공식 영상",
        sourceTier = tier,
        edition = edition,
        language = "ko",
        timestampSeconds = 12,
        contextTag = context,
        confidence = "높음"
    )

    @Test
    fun `공식 한국 영상과 공식 원어 영상이 비공식 자료보다 먼저 온다`() {
        val candidates = parsePersonaSources(
            """
            [출처]
            UNVERIFIED\thttps://wiki.example/a\t팬 위키\t위키\tko\t\t출처 불명
            OFFICIAL_ORIGINAL_VIDEO\thttps://youtube.com/watch?v=jp\t제작사\t공식 PV\tja\t원어\t공식 채널
            OFFICIAL_LOCALIZED_VIDEO\thttps://youtube.com/watch?v=kr\t배급사\t한국 공식 예고편\tko\t한국 자막\t공식 채널
            """.trimIndent()
        )

        assertEquals(PersonaSourceTier.OFFICIAL_LOCALIZED_VIDEO, candidates[0].tier)
        assertEquals(PersonaSourceTier.OFFICIAL_ORIGINAL_VIDEO, candidates[1].tier)
        assertEquals(PersonaSourceTier.UNVERIFIED, candidates[2].tier)
    }

    @Test
    fun `공식 자료가 있으면 검증되지 않은 표본을 섞지 않고 최대 48개만 둔다`() {
        val official = (1..55).map { evidence("공식 대사 $it") }
        val unverified = evidence("밈 대사", PersonaSourceTier.UNVERIFIED, "https://wiki.example/a")

        val selected = selectPersonaEvidence(official + unverified)

        assertEquals(48, selected.size)
        assertFalse(selected.any { it.text == "밈 대사" })
    }

    @Test
    fun `한국 공식 영상이 있으면 낮은 공식 등급도 섞지 않는다`() {
        val selected = selectPersonaEvidence(
            listOf(
                evidence("한국 공식 자막 대사"),
                evidence("원어 영상 대사", PersonaSourceTier.OFFICIAL_ORIGINAL_VIDEO),
                evidence("공식 문서 대사", PersonaSourceTier.OFFICIAL_TEXT)
            )
        )

        assertEquals(listOf("한국 공식 자막 대사"), selected.map { it.text })
    }

    @Test
    fun `공백 문장부호와 같은 시작절의 유사 표본은 빈도를 부풀리지 않는다`() {
        val selected = selectPersonaEvidence(
            listOf(
                evidence("덴지 군은 말이야, 오늘은 괜찮아."),
                evidence("덴지 군은 말이야 오늘은 괜찮아!"),
                evidence("덴지 군은 말이야, 오늘은 정말 괜찮아."),
                evidence("오늘은 네가 먼저 말해 줘.", context = "부탁")
            )
        )

        assertTrue(selected.size <= 3)
        assertTrue(selected.any { it.text == "오늘은 네가 먼저 말해 줘." })
    }

    @Test
    fun `다른 공식 판본의 번역 차이는 별도 표본으로 보존한다`() {
        val selected = selectPersonaEvidence(
            listOf(
                evidence("같이 학교에 가자.", edition = "극장판 한국 자막"),
                evidence("우리 학교에 같이 가자.", edition = "TV판 한국 자막")
            )
        )

        assertEquals(2, selected.size)
    }

    @Test
    fun `판본이 달라도 문장이 완전히 같으면 한 표본으로 센다`() {
        val selected = selectPersonaEvidence(
            listOf(
                evidence("완전히 같은 대사.", edition = "극장판"),
                evidence("완전히 같은 대사!", edition = "TV판")
            )
        )

        assertEquals(1, selected.size)
    }

    @Test
    fun `분석은 최대 40개 런타임은 최대 8개와 900토큰을 지킨다`() {
        val all = (1..48).map { index ->
            evidence(
                text = "${index}번째 상황에서 서로 다른 길이와 종결을 가진 대사 ${"가".repeat(index * 2)}",
                source = "https://youtube.com/watch?v=$index",
                context = listOf("평상시", "질문", "거절", "장난", "분노")[index % 5]
            )
        }

        assertEquals(40, selectAnalysisEvidence(all).size)
        val runtime = selectRuntimePersonaSamples(all.map { it.text }, all)
        assertTrue(runtime.size <= 8)
        assertTrue(runtime.sumOf { (it.length * 0.82).toInt() } <= 900)
    }

    @Test
    fun `공식 유튜브는 URL context가 아니라 영상 fileData로 만든다`() {
        val urls = personaVideoUrls(
            listOf(
                PersonaSourceCandidate(
                    PersonaSourceTier.OFFICIAL_LOCALIZED_VIDEO,
                    "https://www.youtube.com/watch?v=abc",
                    "공식 채널", "공식 영상", "ko", "한국 자막", "공식 채널"
                )
            ),
        )

        assertEquals(listOf("https://www.youtube.com/watch?v=abc"), urls)
    }

    @Test
    fun `공식 영상은 최대 5개와 합계 15분을 넘지 않는다`() {
        val candidates = (1..6).map { index ->
            PersonaSourceCandidate(
                PersonaSourceTier.OFFICIAL_LOCALIZED_VIDEO,
                "https://youtube.com/watch?v=$index",
                "공식 채널", "영상 $index", "ko", "한국 자막", "공식 채널",
                durationSeconds = 240
            )
        }

        val urls = personaVideoUrls(candidates)

        val inputs = personaVideoInputs(candidates)
        assertTrue(urls.size <= 5)
        assertTrue(inputs.sumOf { it.analysisSeconds } <= 900)
    }

    @Test
    fun `길이를 모르는 영상도 15분 클립으로 제한한다`() {
        val candidate = PersonaSourceCandidate(
            PersonaSourceTier.OFFICIAL_LOCALIZED_VIDEO,
            "https://youtu.be/unknown", "공식", "영상", "ko", "한국 자막", "공식"
        )

        assertEquals(900, personaVideoInputs(listOf(candidate)).single().analysisSeconds)
    }

    @Test
    fun `유사 중복은 한 표본으로 두되 관찰 횟수는 보존한다`() {
        val selected = selectPersonaEvidence(
            listOf(
                evidence("덴지 군은 말이야, 오늘은 괜찮아."),
                evidence("덴지 군은 말이야 오늘은 괜찮아!"),
                evidence("다른 방식으로 대답할게.")
            )
        )

        assertEquals(2, selected.first { it.text.startsWith("덴지") }.similarSampleCount)
    }

    @Test
    fun `증거 파서는 URL과 타임스탬프를 보존한다`() {
        val parsed = parsePersonaEvidence(
            """
            [확신도] 높음 - 공식 자막 확인
            [대사]
            00:12\t평상시\t인물\t안녕, 오늘은 어때?\thttps://youtube.com/watch?v=a\t공식 영상\tOFFICIAL_LOCALIZED_VIDEO\t한국 자막\tko\t높음
            """.trimIndent()
        )

        assertEquals(12, parsed.single().timestampSeconds)
        assertEquals("https://youtube.com/watch?v=a", parsed.single().sourceUrl)
    }

    @Test
    fun `탐색에서 확인하지 않은 URL의 대사는 증거로 받지 않는다`() {
        val parsed = parsePersonaEvidence(
            """
            [대사]
            00:12\t평상시\t인물\t확인되지 않은 문장\thttps://unknown.example/a\t미상\tUNVERIFIED\t\tko\t낮음
            """.trimIndent(),
            allowedSourceUrls = setOf("https://youtube.com/watch?v=official")
        )

        assertTrue(parsed.isEmpty())
    }

    @Test
    fun `증거의 출처 등급과 제목은 탐색 단계의 검증값으로 덮어쓴다`() {
        val source = PersonaSourceCandidate(
            PersonaSourceTier.OFFICIAL_TEXT,
            "https://official.example/script", "제작사", "공식 대본", "ko", "공식판", "공식 사이트"
        )
        val parsed = parsePersonaEvidence(
            """
            [대사]
            \t평상시\t인물\t확인된 문장\thttps://official.example/script\t가짜 제목\tOFFICIAL_LOCALIZED_VIDEO\t가짜판\tja\t높음
            """.trimIndent(),
            sourceCandidates = listOf(source)
        )

        assertEquals(PersonaSourceTier.OFFICIAL_TEXT, parsed.single().sourceTier)
        assertEquals("공식 대본", parsed.single().sourceTitle)
        assertEquals("공식판", parsed.single().edition)
    }

    @Test
    fun `같은 유튜브 영상 URL 변형은 한 출처로 합친다`() {
        val parsed = parsePersonaSources(
            """
            [출처]
            OFFICIAL_LOCALIZED_VIDEO\thttps://youtu.be/abc123?t=3\t공식\t영상\tko\t자막\t공식\t30
            OFFICIAL_LOCALIZED_VIDEO\thttps://www.youtube.com/watch?v=abc123&utm_source=x\t공식\t영상\tko\t자막\t공식\t30
            """.trimIndent()
        )

        assertEquals(1, parsed.size)
    }

    @Test
    fun `기존 저장 데이터는 증거 목록 없이도 읽힌다`() {
        val old = Codec.json.decodeFromString<PersonaStyle>(
            """{"description":"인물","samples":["안녕"],"styleGuide":"규칙","isEnabled":true}"""
        )
        assertTrue(old.sampleEvidence.isEmpty())
    }

    @Test
    fun `사용자가 대사를 고치면 원문과 불일치한 증거 연결을 없앤다`() {
        val kept = evidence("그대로인 대사")
        val edited = evidence("수정 전 대사")

        val reconciled = reconcilePersonaEvidence(listOf("그대로인 대사", "수정된 대사"), listOf(kept, edited))

        assertEquals(listOf(kept), reconciled)
    }

    @Test
    fun `문장부호만 고쳐도 공식 원문 증거 연결을 없앤다`() {
        val original = evidence("공식 원문이야.")

        assertTrue(reconcilePersonaEvidence(listOf("공식 원문이야!"), listOf(original)).isEmpty())
    }
}
