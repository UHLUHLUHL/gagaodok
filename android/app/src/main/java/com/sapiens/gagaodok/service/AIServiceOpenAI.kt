package com.sapiens.gagaodok.service

import com.sapiens.gagaodok.data.SecureStore
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.AttachmentType
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.model.PersonaStyle
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

// Luna(OpenAI) 쪽 길입니다. Gemini와 겹치는 것이 없어 통째로 갈라 뒀습니다.
internal fun AIService.sendOpenAIRequest(
    conversation: List<ConversationTurn>,
    botName: String,
    roomId: UUID,
    persona: PersonaStyle?,
    mode: ChatMode
): String {
    val apiKey = SecureStore.apiKey(appContext, SecureStore.Credential.OPENAI)
        ?: throw AIServiceException("설정에서 OpenAI API 키를 먼저 등록해주세요.")

    val body = JSONObject()
        .put("model", AIModel.GPT_56_LUNA.rawValue)
        .put("instructions", systemPrompt(botName, persona, mode))
        .put("input", buildOpenAIInput(conversation))
        .put("prompt_cache_key", "gagaodok-room-$roomId")
        // 대화가 뒤에 계속 추가되는 메신저에는 implicit 경계가 가장 잘 맞습니다.
        .put("prompt_cache_options", JSONObject().put("mode", "implicit").put("ttl", "30m"))
        .put("reasoning", JSONObject().put("effort", "medium").put("context", "all_turns"))
        .put("text", JSONObject().put("verbosity", "medium"))
        .put("max_output_tokens", 4096)
        .put("safety_identifier", "gagaodok-local-user")
        .put("store", false)

    val request = Request.Builder()
        .url("https://api.openai.com/v1/responses")
        .addHeader("Content-Type", "application/json")
        .addHeader("Authorization", "Bearer $apiKey")
        .post(body.toString().toRequestBody(JSON_MEDIA))
        .build()

    val json = client.newCall(request).execute().use {
        val raw = it.body?.string().orEmpty()
        if (!it.isSuccessful) throw AIServiceException(errorMessage(raw, it.code, "OpenAI"))
        JSONObject(raw)
    }

    json.optJSONObject("usage")?.let { u ->
        val details = u.optJSONObject("input_tokens_details")
        usage.recordUsage(
            roomId, AIModel.GPT_56_LUNA,
            inputTokens = u.optInt("input_tokens"),
            outputTokens = u.optInt("output_tokens"),
            cachedInputTokens = details?.optInt("cached_tokens") ?: 0,
            cacheWriteTokens = details?.optInt("cache_write_tokens") ?: 0
        )
    }

    json.optString("output_text").takeIf { it.isNotEmpty() }?.let { return it }
    val output = json.optJSONArray("output")
    if (output != null) {
        val text = buildString {
            for (i in 0 until output.length()) {
                val content = output.optJSONObject(i)?.optJSONArray("content") ?: continue
                for (j in 0 until content.length()) {
                    val item = content.optJSONObject(j) ?: continue
                    if (item.optString("type") == "output_text") {
                        if (isNotEmpty()) append("\n")
                        append(item.optString("text"))
                    }
                }
            }
        }
        if (text.isNotEmpty()) return text
    }
    throw AIServiceException("OpenAI 응답 형식을 읽을 수 없습니다.")
}

internal fun AIService.buildOpenAIInput(conversation: List<ConversationTurn>): JSONArray {
    val array = JSONArray()
    for (turn in conversation) {
        if (turn.sender == MessageSender.SAPIENS) {
            // 화면에 남아 있는 과거 전송 오류는 대화 맥락에 포함하지 않습니다.
            if (turn.text.isEmpty() || turn.text.startsWith(ERROR_PREFIX)) continue
            array.put(JSONObject().put("role", "assistant").put("content", turn.text))
            continue
        }
        var text = turn.text
        val attachment = turn.attachment
        if (attachment != null && attachment.type != AttachmentType.IMAGE) {
            decodeText(attachment)?.let {
                if (text.isNotEmpty()) text += "\n\n"
                text += "첨부파일 ${attachment.fileName}:\n$it"
            }
        }
        val content = JSONArray()
        if (text.isNotEmpty()) content.put(JSONObject().put("type", "input_text").put("text", text))
        if (attachment != null && attachment.type == AttachmentType.IMAGE) {
            content.put(
                JSONObject().put("type", "input_image")
                    .put("image_url", "data:${attachment.mimeType};base64,${attachment.dataBase64}")
                    .put("detail", "auto")
            )
        }
        if (content.length() == 0) continue
        array.put(JSONObject().put("role", "user").put("content", content))
    }
    return array
}

// MARK: - 요청 조립과 응답 해석
