package com.sapiens.gagaodok

import com.sapiens.gagaodok.service.GEMINI_MAX_OUTPUT_TOKENS
import com.sapiens.gagaodok.service.chatGenerationConfig
import com.sapiens.gagaodok.service.nextRequestSeed
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// 같은 대화를 다시 보냈을 때 답이 갈리게 합니다.
///
/// **왜 필요한가.** 사용자가 답이 마음에 안 들면 자기 메시지를 눌러 고치고 다시
/// 보냅니다. 글을 안 바꾸고 그냥 보내는 일도 많은데, 그러면 요청이 바이트 단위로
/// 이전과 같아집니다. 실측으로 확인했습니다 — 같은 요청을 두 번 보내면 답이
/// **완전히 동일**했습니다.
///
/// Gemini 3.x는 `temperature`·`topK`·`topP`를 무시하고 `frequencyPenalty`·
/// `presencePenalty`·`candidateCount`는 400으로 거부합니다. 남은 손잡이는
/// `seed`뿐이고, 실측에서 씨앗만 바꾸자 답이 갈렸습니다.
///
/// 프롬프트에 글자를 붙이지 않으므로 **저장 원문도, 캐시도 건드리지 않습니다.**
/// `generationConfig`는 `cachedContents`에 담기지 않습니다.
class ChatSeedTest {

    @Test
    fun `요청마다 다른 씨앗을 낸다`() {
        val seeds = (1..200).map { nextRequestSeed() }.toSet()
        // 32비트 범위에서 200개를 뽑으면 겹칠 일이 사실상 없습니다. 몇 개는
        // 겹쳐도 되지만, 같은 값만 나온다면 그건 고장입니다.
        assertTrue("씨앗이 거의 다 같다: ${seeds.size}/200", seeds.size >= 195)
    }

    @Test
    fun `씨앗은 양수다`() {
        // 음수를 거부하는 구현이 있어 굳이 걸지 않습니다.
        repeat(500) { assertTrue(nextRequestSeed() > 0) }
    }

    @Test
    fun `설정에 씨앗이 실린다`() {
        val config = chatGenerationConfig(thinkingLevel = "low", seed = 12345)
        assertEquals(12345, config.getInt("seed"))
    }

    @Test
    fun `씨앗을 넣어도 나머지 설정은 그대로다`() {
        val config = chatGenerationConfig(thinkingLevel = "medium", seed = 7)
        assertEquals(GEMINI_MAX_OUTPUT_TOKENS, config.getInt("maxOutputTokens"))
        assertEquals("medium", config.getJSONObject("thinkingConfig").getString("thinkingLevel"))
    }

    @Test
    fun `Gemini 3 x가 무시하거나 거부하는 값은 넣지 않는다`() {
        // temperature·topK·topP는 무시되고, penalty 계열과 candidateCount는
        // gemini-3.7-flash부터 400입니다. 넣어 두면 나중에 누가 "효과가 없네"
        // 하고 값만 만지게 됩니다.
        val config = chatGenerationConfig(thinkingLevel = "low", seed = 1)
        listOf(
            "temperature", "topK", "topP",
            "frequencyPenalty", "presencePenalty", "candidateCount"
        ).forEach {
            assertTrue("$it 가 들어 있다", !config.has(it))
        }
    }
}
