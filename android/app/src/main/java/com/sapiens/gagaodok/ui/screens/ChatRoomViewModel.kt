package com.sapiens.gagaodok.ui.screens

import android.app.Application
import android.graphics.Bitmap
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.sapiens.gagaodok.GagaodokApp
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.ChatAttachment
import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.service.AIService
import com.sapiens.gagaodok.service.AIServiceException
import com.sapiens.gagaodok.service.RoleplayParser
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import java.util.UUID

/// 대화방 하나의 상태입니다.
///
/// 맥 판은 뷰 안의 `@State`로 들고 있었지만 안드로이드에서는 그러면 안 됩니다.
/// 화면을 돌리거나 앱이 잠시 뒤로 밀렸다 돌아올 때마다 뷰가 새로 만들어지는데,
/// 그때 받던 답변이 통째로 사라집니다. ViewModel은 그 사이에도 살아 있습니다.
class ChatRoomViewModel(app: Application) : AndroidViewModel(app) {

    private val appInstance = app as GagaodokApp
    private val store = appInstance.chatStore
    private val ai = AIService.get(app)

    private var roomId: UUID? = null

    private val _messages = MutableStateFlow<List<ChatMessage>>(emptyList())
    val messages: StateFlow<List<ChatMessage>> = _messages

    private val _isTyping = MutableStateFlow(false)
    val isTyping: StateFlow<Boolean> = _isTyping

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage

    private var responseJob: Job? = null

    fun bind(id: UUID) {
        if (roomId == id) return
        roomId = id
        viewModelScope.launch {
            _messages.value = withContext(Dispatchers.IO) { store.loadMessages(id) }
        }
    }

    fun clearError() { _errorMessage.value = null }

    private fun persist() {
        roomId?.let { store.saveMessages(it, _messages.value) }
    }

    // MARK: - 보내기

    fun send(text: String, attachment: ChatAttachment?, room: ChatRoom, model: AIModel) {
        if (_isTyping.value) return
        val trimmed = text.trim()
        if (trimmed.isEmpty() && attachment == null) return

        val turnId = UUID.randomUUID()
        val mine = ChatMessage(
            sender = MessageSender.USER,
            text = trimmed,
            attachment = attachment,
            turnId = turnId,
            canonicalText = trimmed
        )
        _messages.value = _messages.value + mine
        persist()
        _isTyping.value = true
        respond(_messages.value, room, model, failingMessageId = mine.id)
    }

    /// 실패한 메시지를 다시 보냅니다. 그 메시지까지의 이력으로 다시 요청하므로
    /// 뒤에 다른 대화가 있어도 순서를 지킵니다.
    fun resend(message: ChatMessage, room: ChatRoom, model: AIModel) {
        resendFromMessage(message, replacementText = null, room = room, model = model)
    }

    /// 내 메시지를 고쳐 다시 답변을 받습니다. 그 뒤의 대화는 지워집니다.
    fun editAndResend(message: ChatMessage, newText: String, room: ChatRoom, model: AIModel) {
        resendFromMessage(message, replacementText = newText, room = room, model = model)
    }

    /** 실패 재시도, 텍스트 수정, 첨부파일 전용 재전송이 공유하는 단일 경로입니다. */
    fun resendFromMessage(
        message: ChatMessage,
        replacementText: String?,
        room: ChatRoom,
        model: AIModel
    ) {
        if (_isTyping.value) return
        if (replacementText != null && replacementText.isBlank()) return
        val current = _messages.value
        val truncated = MessageResendLogic.truncateFrom(current, message.id, replacementText)
        if (truncated === current) return
        _messages.value = truncated
        persist()
        _isTyping.value = true
        respond(truncated, room, model, failingMessageId = message.id)
    }

    fun delete(message: ChatMessage) {
        _messages.value = _messages.value.filterNot { it.id == message.id }
        persist()
    }

    fun cancelResponse() {
        responseJob?.cancel()
        responseJob = null
        _isTyping.value = false
    }

    private fun respond(
        history: List<ChatMessage>,
        room: ChatRoom,
        model: AIModel,
        failingMessageId: UUID?
    ) {
        val id = roomId ?: return
        val conversation: List<ConversationTurn> = ConversationTurn.from(history)
        // 스트리밍은 문단이 완성되는 대로 화면에 붙으므로, 첫 문단을 붙이는 시점에는
        // 그 턴에 따옴표 대사가 나올지 아직 모릅니다. 앞 턴이 상황극이었다면 알려 줍니다.
        val wasRoleplaying = RoleplayParser.roleplayInProgress(history)
        val mode = room.resolvedMode

        responseJob?.cancel()
        responseJob = viewModelScope.launch {
            val responseTurnId = UUID.randomUUID()
            var attempt = 0
            while (true) {
                try {
                    val rawText = ai.streamResponse(
                        conversation = conversation,
                        botName = room.profile.name,
                        roomId = id,
                        model = model,
                        persona = room.profile.persona.takeIf { it.isEnabled },
                        mode = mode,
                        roleplayInProgress = wasRoleplaying
                    ) { bubble ->
                        // 첫 말풍선이 붙는 순간 타이핑 표시를 끕니다.
                        _isTyping.value = false
                        _messages.value = _messages.value + ChatMessage(
                            sender = MessageSender.SAPIENS,
                            text = bubble.text,
                            attachment = bubble.attachment,
                            turnId = responseTurnId,
                            kind = bubble.kind
                        )
                        persist()
                    }

                    _isTyping.value = false
                    // API에는 갈라지기 전 원문을 한 번만 보냅니다. 턴의 첫 말풍선에 담아 둡니다.
                    val firstIndex = _messages.value.indexOfFirst { it.turnId == responseTurnId }
                    if (firstIndex >= 0) {
                        _messages.value = _messages.value.toMutableList().also {
                            it[firstIndex] = it[firstIndex].copy(canonicalText = rawText)
                        }
                        persist()
                    }
                    return@launch
                } catch (e: CancellationException) {
                    // 사용자가 멈춘 것은 실패가 아닙니다. 표시를 남기지 않습니다.
                    _isTyping.value = false
                    throw e
                } catch (e: Exception) {
                    // 말풍선이 이미 하나라도 붙었으면 다시 보낼 수 없습니다.
                    // 처음부터 다시 받으면 앞부분이 두 번 나옵니다.
                    val alreadyShown = _messages.value.any { it.turnId == responseTurnId }
                    // **다시 보내도 소용없는 실패는 다시 보내지 않습니다.**
                    // 키가 틀렸거나 요청이 잘못됐으면 세 번을 보내도 똑같이 실패하고,
                    // 그 두 번은 화면에 아무것도 남기지 않은 채 요금만 냈습니다.
                    // 서비스가 아닌 곳에서 온 예외(주로 네트워크)는 다시 시도합니다.
                    val retryable = (e as? AIServiceException)?.retryable ?: true
                    if (!alreadyShown && retryable && attempt < SILENT_RETRIES) {
                        attempt += 1
                        continue
                    }
                    _isTyping.value = false
                    _errorMessage.value = e.message ?: "요청을 처리하지 못했습니다."
                    // 답변자 쪽에 오류 말풍선을 남기지 않습니다. 카카오톡처럼
                    // 내 말풍선에 표시를 달아 재전송하거나 지울 수 있게 합니다.
                    val failIndex = _messages.value.indexOfFirst { it.id == failingMessageId }
                    if (failIndex >= 0) {
                        _messages.value = _messages.value.toMutableList().also {
                            it[failIndex] = it[failIndex].copy(deliveryFailed = true)
                        }
                        persist()
                    }
                    return@launch
                }
            }
        }
    }

    override fun onCleared() {
        super.onCleared()
        store.flushPendingSaves()
    }

    companion object {
        /// 실패해도 사용자에게 알리기 전에 조용히 다시 시도하는 횟수입니다.
        private const val SILENT_RETRIES = 2
    }
}
