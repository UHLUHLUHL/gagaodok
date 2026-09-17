package com.sapiens.gagaodok

import com.sapiens.gagaodok.data.ModelTokenUsage
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.service.DeepSeekSentExtras
import com.sapiens.gagaodok.service.MemoryDraft
import com.sapiens.gagaodok.service.ThreeLayerMemory
import com.sapiens.gagaodok.service.deepSeekMemoryJson
import kotlinx.serialization.decodeFromString
import com.sapiens.gagaodok.service.DeepSeekSentExtrasStore
import com.sapiens.gagaodok.service.PersonalAffectionProtocol
import com.sapiens.gagaodok.service.RepetitionAdvice
import com.sapiens.gagaodok.service.deepSeekChatThinkingDisabled
import com.sapiens.gagaodok.service.deepSeekEmptyResponseMessage
import com.sapiens.gagaodok.service.deepSeekRetryDelayMillis
import com.sapiens.gagaodok.service.isDeepSeekRetryableFinish
import com.sapiens.gagaodok.service.deepSeekReplayTurns
import com.sapiens.gagaodok.service.deepSeekResponseToGemini
import com.sapiens.gagaodok.service.deepSeekUsageToGemini
import com.sapiens.gagaodok.service.geminiBodyToDeepSeek
import com.sapiens.gagaodok.service.withRepetitionGuidance
import java.io.File
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

/// DeepSeek(실험)를 Gemini 길에 태우는 변환과 요금입니다.
///
/// 대화 압축·기억·측정은 Gemini 모양의 JSON을 읽습니다. 변환이 틀리면 요청은 가도
/// 기억이 안 쌓이거나 장부가 비는 식으로 **조용히** 틀립니다.
class DeepSeekExperimentTest {

    private fun text(t: String) = JSONObject().put("text", t)
    private fun turn(role: String, vararg parts: JSONObject) =
        JSONObject().put("role", role).put("parts", JSONArray().apply { parts.forEach { put(it) } })

    private fun geminiBody(thinking: String? = "low") = JSONObject()
        .put("systemInstruction", JSONObject().put("parts", JSONArray().put(text("지침"))))
        .put("contents", JSONArray()
            .put(turn("user", text("요약")))
            .put(turn("model", text("확인")))
            .put(turn("user", text("안녕"), text("첨부파일 a.txt:\n내용"))))
        .put("generationConfig", JSONObject().put("maxOutputTokens", 8192).apply {
            thinking?.let { put("thinkingConfig", JSONObject().put("thinkingLevel", it)) }
        })
        .put("safetySettings", JSONArray().put(JSONObject().put("category", "X")))

    @Test
    fun `대화 본문을 Chat Completions로 옮긴다`() {
        val out = geminiBodyToDeepSeek(geminiBody(), stream = true)
        assertEquals("deepseek-flash", out.getString("model"))
        val messages = out.getJSONArray("messages")
        assertEquals(listOf("system", "user", "assistant", "user"),
            (0 until messages.length()).map { messages.getJSONObject(it).getString("role") })
        assertEquals("지침", messages.getJSONObject(0).getString("content"))
        assertEquals("안녕\n\n첨부파일 a.txt:\n내용", messages.getJSONObject(3).getString("content"))
        assertEquals(8192, out.getInt("max_tokens"))
        assertTrue(out.getBoolean("stream"))
        assertTrue("스트림 끝에 사용량을 받아야 장부가 찬다",
            out.getJSONObject("stream_options").getBoolean("include_usage"))
        assertFalse("DeepSeek에는 대응 항목이 없다", out.has("safetySettings"))
    }

    @Test
    fun `스트림이 아니면 stream 칸을 두지 않는다`() {
        val out = geminiBodyToDeepSeek(geminiBody(), stream = false)
        assertFalse(out.has("stream"))
        assertFalse(out.has("stream_options"))
    }

    @Test
    fun `사고 수준을 옮긴다`() {
        fun mapped(level: String?) = geminiBodyToDeepSeek(geminiBody(level), stream = false)
        assertEquals("enabled", mapped("low").getJSONObject("thinking").getString("type"))
        assertEquals("low", mapped("low").getString("reasoning_effort"))
        assertEquals("high", mapped("medium").getString("reasoning_effort"))
        assertEquals("disabled", mapped("minimal").getJSONObject("thinking").getString("type"))
        assertFalse("minimal은 끄므로 강도를 보내지 않는다", mapped("minimal").has("reasoning_effort"))
        assertFalse("지정이 없으면 서버 기본값", mapped(null).has("thinking"))
    }

    @Test
    fun `JSON 스키마 요청은 json_object와 지침 속 스키마로 바뀐다`() {
        val body = geminiBody()
        body.getJSONObject("generationConfig")
            .put("responseMimeType", "application/json")
            .put("responseSchema", JSONObject().put("type", "OBJECT"))
        val out = geminiBodyToDeepSeek(body, stream = false)
        assertEquals("json_object", out.getJSONObject("response_format").getString("type"))
        val system = out.getJSONArray("messages").getJSONObject(0).getString("content")
        assertTrue("문서가 요구하는 낱말", system.contains("json"))
        assertTrue(system.contains("\"type\":\"OBJECT\""))
    }

    @Test
    fun `이미지는 블록으로, 읽을 수 없는 첨부는 빠졌다고 알린다`() {
        val body = geminiBody()
        body.put("contents", JSONArray().put(turn(
            "user",
            text("이거 봐"),
            JSONObject().put("inlineData", JSONObject().put("mimeType", "image/png").put("data", "QUJD")),
            JSONObject().put("inlineData", JSONObject().put("mimeType", "application/pdf").put("data", "QUJD"))
        )))
        val content = geminiBodyToDeepSeek(body, stream = false)
            .getJSONArray("messages").getJSONObject(1).getJSONArray("content")
        assertEquals("text", content.getJSONObject(0).getString("type"))
        assertEquals("data:image/png;base64,QUJD",
            content.getJSONObject(1).getJSONObject("image_url").getString("url"))
        assertTrue(content.getJSONObject(2).getString("text").contains("application/pdf"))
    }

    @Test
    fun `Google 전용 입력은 조용히 빼지 않고 거부한다`() {
        val tools = geminiBody().put("tools", JSONArray().put(JSONObject().put("google_search", JSONObject())))
        assertThrows(IllegalArgumentException::class.java) { geminiBodyToDeepSeek(tools, stream = false) }
        val video = geminiBody().put("contents", JSONArray().put(turn(
            "user", JSONObject().put("fileData", JSONObject().put("fileUri", "https://example.invalid/v"))
        )))
        assertThrows(IllegalArgumentException::class.java) { geminiBodyToDeepSeek(video, stream = false) }
        val cached = geminiBody().put("cachedContent", "cachedContents/fake")
        assertThrows(IllegalArgumentException::class.java) { geminiBodyToDeepSeek(cached, stream = false) }
    }

    @Test
    fun `한 번에 받은 응답을 Gemini 모양으로 바꾼다`() {
        val raw = JSONObject("""
            {"choices":[{"finish_reason":"stop","index":0,
              "message":{"role":"assistant","content":"안녕하세요","reasoning_content":"생각"}}],
             "usage":{"prompt_tokens":1000,"prompt_cache_hit_tokens":900,"prompt_cache_miss_tokens":100,
                      "completion_tokens":50,"completion_tokens_details":{"reasoning_tokens":20}}}
        """.trimIndent())
        val gemini = deepSeekResponseToGemini(raw)
        val candidate = gemini.getJSONArray("candidates").getJSONObject(0)
        assertEquals("STOP", candidate.getString("finishReason"))
        val parts = candidate.getJSONObject("content").getJSONArray("parts")
        assertEquals("사고 내용은 옮기지 않는다", 1, parts.length())
        assertEquals("안녕하세요", parts.getJSONObject(0).getString("text"))
        val usage = gemini.getJSONObject("usageMetadata")
        assertEquals(1000, usage.getInt("promptTokenCount"))
        assertEquals(900, usage.getInt("cachedContentTokenCount"))
        assertEquals(30, usage.getInt("candidatesTokenCount"))
        assertEquals(20, usage.getInt("thoughtsTokenCount"))
    }

    @Test
    fun `스트림 조각과 마지막 사용량 조각을 읽는다`() {
        val piece = deepSeekResponseToGemini(JSONObject(
            """{"choices":[{"index":0,"delta":{"content":"첫"},"finish_reason":null}]}"""
        ))
        val candidate = piece.getJSONArray("candidates").getJSONObject(0)
        assertFalse("아직 안 끝났다", candidate.has("finishReason"))
        assertEquals("첫", candidate.getJSONObject("content").getJSONArray("parts").getJSONObject(0).getString("text"))

        val thinking = deepSeekResponseToGemini(JSONObject(
            """{"choices":[{"index":0,"delta":{"content":null,"reasoning_content":"음"}}]}"""
        ))
        assertEquals("null을 글자로 옮기지 않는다", 0, thinking.getJSONArray("candidates").getJSONObject(0)
            .getJSONObject("content").getJSONArray("parts").length())

        val last = deepSeekResponseToGemini(JSONObject(
            """{"choices":[],"usage":{"prompt_tokens":10,"prompt_cache_hit_tokens":0,"completion_tokens":5}}"""
        ))
        assertFalse(last.has("candidates"))
        assertEquals(5, last.getJSONObject("usageMetadata").getInt("candidatesTokenCount"))
        assertFalse("오지 않은 사고 토큰을 0으로 지어내지 않는다", last.getJSONObject("usageMetadata").has("thoughtsTokenCount"))
    }

    @Test
    fun `멈춘 이유를 Gemini 이름으로 바꾼다`() {
        fun reason(r: String) = deepSeekResponseToGemini(JSONObject()
            .put("choices", JSONArray().put(JSONObject().put("finish_reason", r).put("message", JSONObject().put("content", "")))))
            .getJSONArray("candidates").getJSONObject(0).getString("finishReason")
        assertEquals("MAX_TOKENS", reason("length"))
        assertEquals("안전 필터(SAFETY)와 섞지 않는다", "DEEPSEEK_CONTENT_FILTER", reason("content_filter"))
    }

    @Test
    fun `캐시 적중 칸이 없으면 OpenAI식 칸을 읽는다`() {
        val usage = deepSeekUsageToGemini(JSONObject(
            """{"prompt_tokens":10,"prompt_tokens_details":{"cached_tokens":7},"completion_tokens":1}"""
        ))
        assertEquals(7, usage.getInt("cachedContentTokenCount"))
    }

    @Test
    fun `단가는 공식 요금표의 비피크 값이다`() {
        val m = AIModel.DEEPSEEK_FLASH
        assertEquals(0.15, m.inputPricePerMillion, 0.0)
        assertEquals(0.003, m.cachedInputPricePerMillion, 0.0)
        assertEquals(0.6, m.outputPricePerMillion, 0.0)
        assertEquals(0.0, m.cacheStoragePricePerMillionPerHour, 0.0)
        assertEquals(1.0, m.cacheWriteMultiplier, 0.0)
        assertFalse("Gemini 캐시 규칙을 받지 않는다", m.isGeminiConversationModel)
        assertTrue(m.usesSharedConversationPath)
        assertFalse(AIModel.GPT_56_LUNA.usesSharedConversationPath)
        assertEquals(0.0, AIModel.GEMINI_38_FLASH.peakSurchargeRate, 0.0)
    }

    @Test
    fun `피크 몫은 두 배로 매긴다`() {
        val offPeak = ModelTokenUsage(inputTokens = 1_000_000, cachedInputTokens = 0, outputTokens = 1_000_000)
        assertEquals(0.75, offPeak.costUSD(AIModel.DEEPSEEK_FLASH), 1e-9)
        val peak = offPeak.copy(peakInputTokens = 1_000_000, peakOutputTokens = 1_000_000)
        assertEquals(1.5, peak.costUSD(AIModel.DEEPSEEK_FLASH), 1e-9)
        // 캐시 적중분도 피크면 두 배입니다(0.003 → 0.006).
        val cached = ModelTokenUsage(inputTokens = 1_000_000, cachedInputTokens = 1_000_000,
            peakInputTokens = 1_000_000, peakCachedInputTokens = 1_000_000)
        assertEquals(0.006, cached.costUSD(AIModel.DEEPSEEK_FLASH), 1e-9)
        // 할증이 없는 모델은 피크 칸이 있어도 값이 같습니다.
        assertEquals(offPeak.costUSD(AIModel.GEMINI_38_FLASH), peak.costUSD(AIModel.GEMINI_38_FLASH), 1e-9)
        assertEquals(offPeak.adding(peak).peakInputTokens, 1_000_000)
    }

    @Test
    fun `피크 시간대는 평일 UTC 1~4시와 6~10시다`() {
        fun at(dayOfWeek: Int, hour: Int, minute: Int = 0): Long =
            Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
                clear()
                set(2026, Calendar.SEPTEMBER, 14, hour, minute) // 2026-09-14는 월요일
                add(Calendar.DAY_OF_MONTH, dayOfWeek - Calendar.MONDAY)
            }.timeInMillis
        assertFalse(AIModel.isDeepSeekPeak(at(Calendar.MONDAY, 0, 59)))
        assertTrue(AIModel.isDeepSeekPeak(at(Calendar.MONDAY, 1, 0)))
        assertTrue(AIModel.isDeepSeekPeak(at(Calendar.MONDAY, 3, 59)))
        assertFalse(AIModel.isDeepSeekPeak(at(Calendar.MONDAY, 4, 0)))
        assertFalse(AIModel.isDeepSeekPeak(at(Calendar.MONDAY, 5, 59)))
        assertTrue(AIModel.isDeepSeekPeak(at(Calendar.FRIDAY, 6, 0)))
        assertTrue(AIModel.isDeepSeekPeak(at(Calendar.FRIDAY, 9, 59)))
        assertFalse(AIModel.isDeepSeekPeak(at(Calendar.FRIDAY, 10, 0)))
        assertFalse("주말은 비피크", AIModel.isDeepSeekPeak(at(Calendar.SATURDAY, 7, 0)))
        assertFalse("주말은 비피크", AIModel.isDeepSeekPeak(at(Calendar.SUNDAY + 7, 2, 0)))
    }

    @Test
    fun `챗봇 답변은 사고를 끄고 temperature를 적는다`() {
        val out = geminiBodyToDeepSeek(geminiBody("medium"), stream = true, chatReply = true)
        assertEquals("disabled", out.getJSONObject("thinking").getString("type"))
        assertFalse(out.has("reasoning_effort"))
        assertEquals(1.05, out.getDouble("temperature"), 0.0)
        assertFalse("top_p는 비사고 모드에서 1.0 고정이라 보내지 않는다", out.has("top_p"))
        assertTrue(deepSeekChatThinkingDisabled(ChatMode.COMPANION))
        // 보조 호출은 요청에 적힌 사고 수준을 따르고 temperature를 보내지 않는다.
        val aux = geminiBodyToDeepSeek(geminiBody("low"), stream = false)
        assertEquals("enabled", aux.getJSONObject("thinking").getString("type"))
        assertFalse(aux.has("temperature"))
    }

    // MARK: - 캐시 접두사 되살리기

    private val user1 = ConversationTurn(UUID.fromString("00000000-0000-0000-0000-000000000001"), MessageSender.USER, "첫 질문")
    private val bot1 = ConversationTurn(UUID.fromString("00000000-0000-0000-0000-000000000002"), MessageSender.SAPIENS, "첫 답")
    private val user2 = ConversationTurn(UUID.fromString("00000000-0000-0000-0000-000000000003"), MessageSender.USER, "둘째 질문")
    private val roomId = UUID.fromString("00000000-0000-0000-0000-0000000000aa")

    private fun extrasStore(file: File = File.createTempFile("deepseek-extras", ".json").also { it.delete() }) =
        DeepSeekSentExtrasStore(file)

    @Test
    fun `다음 요청의 앞부분이 지난 요청과 답을 글자 그대로 담는다`() {
        val store = extrasStore()
        // 요청 N: 마지막 사용자 턴에 지침 G1을 붙여 보낸다.
        val turnsN = listOf(user1, bot1, user2)
        val sentN = deepSeekReplayTurns(turnsN, store.load(roomId), "G1")
        store.recordRequest(roomId, turnsN, user2.id, "G1", setOf(roomId))
        // 답에는 호감도 표식이 있고, 저장본은 표식을 뺀 글이다.
        val raw = "좋아. [[affection:+1:솔직해서]]"
        store.recordReply(roomId, user2.id, raw)
        val bot2 = ConversationTurn(UUID.randomUUID(), MessageSender.SAPIENS, PersonalAffectionProtocol.visibleText(raw))
        val user3 = ConversationTurn(UUID.randomUUID(), MessageSender.USER, "셋째 질문")

        // 요청 N+1: 새 지침 G2. 지난 요청은 G1을 그대로 되살려야 한다.
        val sentNext = deepSeekReplayTurns(turnsN + bot2 + user3, store.load(roomId), "G2")

        assertEquals("입력 끝 단위가 그대로 앞부분이 된다", sentN, sentNext.take(sentN.size))
        assertEquals("둘째 질문\n\nG1", sentNext[2].text)
        assertEquals("출력 끝 단위도 맞도록 원문을 싣는다", raw, sentNext[3].text)
        assertEquals("셋째 질문\n\nG2", sentNext[4].text)
    }

    @Test
    fun `세 번 이어 보내도 매번 직전 요청 전체가 앞부분이다`() {
        // 표식이 없는 답과 지침이 없는 턴이 섞여도 끊기지 않아야 한다.
        val store = extrasStore()
        var turns = listOf(user1)
        var previousSent: List<ConversationTurn>? = null
        val guidances = listOf("G1", null, "G3")
        val replies = listOf("평범한 답", "표식 답 [[affection:+2:전환점]]", "끝 공백 있는 답\n")
        guidances.forEachIndexed { index, guidance ->
            val lastUser = turns.last { it.sender == MessageSender.USER }.id
            val sent = deepSeekReplayTurns(turns, store.load(roomId), guidance)
            previousSent?.let { assertEquals("요청 ${index + 1}", it, sent.take(it.size)) }
            store.recordRequest(roomId, turns, lastUser, guidance, setOf(roomId))
            store.recordReply(roomId, lastUser, replies[index])
            val bot = ConversationTurn(UUID.randomUUID(), MessageSender.SAPIENS,
                PersonalAffectionProtocol.visibleText(replies[index]))
            // 다음 요청에서 "직전 요청 + 그 답"이 통째로 앞부분이어야 한다.
            previousSent = sent + bot.copy(text = replies[index])
            turns = turns + bot + ConversationTurn(UUID.randomUUID(), MessageSender.USER, "질문 ${index + 2}")
        }
        val last = deepSeekReplayTurns(turns, store.load(roomId), null)
        assertEquals(previousSent, last.take(previousSent!!.size))
    }

    @Test
    fun `DeepSeek 기억 초안은 모르는 칸만 무시하고 Gemini는 엄격하다`() {
        val withExtra = """{"segments":[{"firstTurn":1,"lastTurn":2,"text":"사건","note":"x"}],"updates":[],"comment":"y"}"""
        val draft = deepSeekMemoryJson.decodeFromString<MemoryDraft>(withExtra)
        assertEquals(1, draft.segments.size)
        assertTrue(runCatching { ThreeLayerMemory.json.decodeFromString<MemoryDraft>(withExtra) }.isFailure)
        // 필요한 칸이 빠지면 DeepSeek도 실패한다.
        assertTrue(runCatching { deepSeekMemoryJson.decodeFromString<MemoryDraft>("""{"segments":[]}""") }.isFailure)
    }

    @Test
    fun `지침 모양은 Gemini 쪽 withRepetitionGuidance와 같다`() {
        // 두 길이 같은 글을 보내야 모델을 바꿔도 대화가 같은 모양으로 이어진다.
        val advice = RepetitionAdvice(listOf("그러니까"))
        val gemini = listOf(user1, bot1, user2).withRepetitionGuidance(advice)
        val deepSeek = deepSeekReplayTurns(listOf(user1, bot1, user2), DeepSeekSentExtras(), advice.promptSection())
        assertEquals(gemini, deepSeek)
    }

    @Test
    fun `고쳐진 답은 원문으로 바꾸지 않는다`() {
        val extras = DeepSeekSentExtras(rawReplyByUserTurn = mapOf(user1.id.toString() to "원래 답 [[affection:+1:이유]]"))
        val edited = bot1.copy(text = "사용자가 고친 답")
        assertEquals(listOf(user1, edited), deepSeekReplayTurns(listOf(user1, edited), extras, null))
    }

    @Test
    fun `표식이 없는 답은 기록하지 않고 옛 기록을 지운다`() {
        val store = extrasStore()
        store.recordReply(roomId, user1.id, "표식 [[affection:-1:무례]]")
        assertEquals(1, store.load(roomId).rawReplyByUserTurn.size)
        store.recordReply(roomId, user1.id, "다시 받은 답")
        assertTrue(store.load(roomId).rawReplyByUserTurn.isEmpty())
    }

    @Test
    fun `지침 없이 다시 보내면 그 턴의 옛 지침을 지운다`() {
        val store = extrasStore()
        store.recordRequest(roomId, listOf(user1), user1.id, "G1", setOf(roomId))
        store.recordRequest(roomId, listOf(user1), user1.id, null, setOf(roomId))
        assertTrue(store.load(roomId).guidanceByUserTurn.isEmpty())
    }

    @Test
    fun `이번 요청에 없는 턴과 지운 방의 기록은 버린다`() {
        val store = extrasStore()
        val otherRoom = UUID.randomUUID()
        store.recordRequest(otherRoom, listOf(user1), user1.id, "G0", setOf(otherRoom, roomId))
        store.recordRequest(roomId, listOf(user1, bot1, user2), user2.id, "G1", setOf(otherRoom, roomId))
        store.recordRequest(roomId, listOf(user1, bot1, user2), user2.id, "G1", setOf(otherRoom, roomId))
        // 압축으로 앞 턴이 빠지고, 다른 방은 지워졌다.
        store.recordRequest(roomId, listOf(user2), user2.id, "G2", setOf(roomId))
        assertEquals(mapOf(user2.id.toString() to "G2"), store.load(roomId).guidanceByUserTurn)
        assertEquals(DeepSeekSentExtras(), store.load(otherRoom))
    }

    @Test
    fun `앱을 다시 켜도 기록이 이어진다`() {
        val file = File.createTempFile("deepseek-extras-reload", ".json").also { it.delete() }
        extrasStore(file).recordRequest(roomId, listOf(user1), user1.id, "G1", setOf(roomId))
        assertEquals("G1", extrasStore(file).load(roomId).guidanceByUserTurn[user1.id.toString()])
    }

    @Test
    fun `다시 보내기 전 대기는 1초 다음 3초다`() {
        assertEquals(1_000L, deepSeekRetryDelayMillis(1))
        assertEquals(3_000L, deepSeekRetryDelayMillis(2))
    }

    @Test
    fun `서버 자원 부족으로 빈 답만 다시 보낸다`() {
        assertTrue(isDeepSeekRetryableFinish("DEEPSEEK_INSUFFICIENT_SYSTEM_RESOURCE"))
        assertFalse("필터는 다시 보내도 같다", isDeepSeekRetryableFinish("DEEPSEEK_CONTENT_FILTER"))
        assertFalse(isDeepSeekRetryableFinish("MAX_TOKENS"))
        assertFalse(isDeepSeekRetryableFinish(null))
        // 변환이 실제로 이 이름을 만든다.
        val gemini = deepSeekResponseToGemini(JSONObject(
            """{"choices":[{"index":0,"delta":{"content":""},"finish_reason":"insufficient_system_resource"}]}"""
        ))
        assertTrue(isDeepSeekRetryableFinish(
            gemini.getJSONArray("candidates").getJSONObject(0).getString("finishReason")
        ))
    }

    @Test
    fun `빈 응답 문구는 DeepSeek 이름으로 알린다`() {
        listOf(null, "", "DEEPSEEK_CONTENT_FILTER", "DEEPSEEK_INSUFFICIENT_SYSTEM_RESOURCE", "DEEPSEEK_ABORTED")
            .forEach { reason ->
                val message = deepSeekEmptyResponseMessage(reason)
                assertTrue(message, message.contains("DeepSeek"))
                assertFalse(message, message.contains("Gemini"))
            }
        assertFalse(deepSeekEmptyResponseMessage("MAX_TOKENS").contains("Gemini"))
    }

    @Test
    fun `옛 식별자 표는 DeepSeek를 건드리지 않는다`() {
        assertEquals(AIModel.DEEPSEEK_FLASH, AIModel.fromStoredValue("deepseek-flash"))
    }
}
