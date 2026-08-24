package com.sapiens.gagaodok.ui.screens

import android.app.Application
import android.graphics.Bitmap
import android.os.SystemClock
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.sapiens.gagaodok.BuildConfig
import com.sapiens.gagaodok.GagaodokApp
import com.sapiens.gagaodok.data.ConversationScope
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.ChatAttachment
import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageReaction
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.service.AIService
import com.sapiens.gagaodok.service.AIServiceException
import com.sapiens.gagaodok.service.GeneratedMessageBubble
import com.sapiens.gagaodok.service.GroupConversationProtocol
import com.sapiens.gagaodok.service.GroupReplyBubble
import com.sapiens.gagaodok.service.GroupReplyEvent
import com.sapiens.gagaodok.service.GroupReplyScheduler
import com.sapiens.gagaodok.service.PersonalAffectionProtocol
import com.sapiens.gagaodok.service.PlannedReaction
import com.sapiens.gagaodok.service.RoleplayParser
import com.sapiens.gagaodok.service.repetitionAdviceFromConversation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import java.util.UUID

internal data class ConversationBinding(val roomId: UUID, val worldlineId: UUID?) {
    fun matches(roomId: UUID?, worldlineId: UUID?): Boolean =
        this.roomId == roomId && this.worldlineId == worldlineId
}

internal class GroupResponseBuffer(history: List<ChatMessage>) {
    var messages: List<ChatMessage> = history.toList()
        private set

    fun append(message: ChatMessage) { messages = messages + message }

    fun replace(index: Int, message: ChatMessage) {
        messages = messages.toMutableList().also { it[index] = message }
    }

    fun preserveCanonical(turnId: UUID, rawText: String): Boolean {
        if (rawText.isBlank()) return false
        val firstIndex = messages.indexOfFirst { it.turnId == turnId }
        if (firstIndex < 0) return false
        replace(firstIndex, messages[firstIndex].copy(canonicalText = rawText))
        return true
    }
}

private data class PendingGroupBubble(
    val generated: GeneratedMessageBubble,
    val visibleText: String,
    val speakerRoomId: UUID?,
    val reactions: List<PlannedReaction>
)

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
    private var boundWorldlineId: UUID? = null

    private val _messages = MutableStateFlow<List<ChatMessage>>(emptyList())
    val messages: StateFlow<List<ChatMessage>> = _messages

    private val _loadedBinding = MutableStateFlow<ConversationBinding?>(null)
    internal val loadedBinding: StateFlow<ConversationBinding?> = _loadedBinding

    private val _isTyping = MutableStateFlow(false)
    val isTyping: StateFlow<Boolean> = _isTyping

    private val _typingParticipantIds = MutableStateFlow<Set<UUID>>(emptySet())
    val typingParticipantIds: StateFlow<Set<UUID>> = _typingParticipantIds

    private val _isResponding = MutableStateFlow(false)
    val isResponding: StateFlow<Boolean> = _isResponding

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage

    private var responseJob: Job? = null
    private var bindJob: Job? = null

    fun bind(id: UUID) {
        val worldlineId = store.room(id)?.groupChat?.activeWorldlineId
        if (roomId == id && boundWorldlineId == worldlineId) return
        roomId = id
        boundWorldlineId = worldlineId
        val binding = ConversationBinding(id, worldlineId)
        responseJob?.cancel()
        responseJob = null
        _isTyping.value = false
        _typingParticipantIds.value = emptySet()
        _isResponding.value = false
        bindJob?.cancel()
        bindJob = viewModelScope.launch {
            val loaded = store.loadMessagesFresh(ConversationScope(id, worldlineId))
            if (binding.matches(roomId, boundWorldlineId)) {
                _messages.value = loaded
                _loadedBinding.value = binding
            }
        }
    }

    fun clearError() { _errorMessage.value = null }

    private fun persist(worldlineId: UUID? = boundWorldlineId) {
        roomId?.let { persist(it, worldlineId, _messages.value) }
    }

    private fun persist(id: UUID, worldlineId: UUID?, messages: List<ChatMessage>) {
        if (worldlineId == null) store.saveMessages(id, messages)
        else store.saveMessages(id, worldlineId, messages)
    }

    private fun publishGroupResponse(binding: ConversationBinding, buffer: GroupResponseBuffer) {
        if (binding.matches(roomId, boundWorldlineId)) _messages.value = buffer.messages
    }

    // MARK: - 보내기

    fun send(text: String, attachment: ChatAttachment?, room: ChatRoom, model: AIModel): Boolean {
        if (_isResponding.value || !_loadedBinding.value.matchesCurrent()) return false
        val trimmed = text.trim()
        if (trimmed.isEmpty() && attachment == null) return false

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
        _isResponding.value = true
        respond(_messages.value, room, model, failingMessageId = mine.id)
        return true
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
        if (_isResponding.value || !_loadedBinding.value.matchesCurrent()) return
        if (replacementText != null && replacementText.isBlank()) return
        val current = _messages.value
        val truncated = MessageResendLogic.truncateFrom(current, message.id, replacementText)
        if (truncated === current) return
        _messages.value = truncated
        persist()
        _isTyping.value = true
        _isResponding.value = true
        respond(truncated, room, model, failingMessageId = message.id)
    }

    fun delete(message: ChatMessage) {
        if (_isResponding.value || !_loadedBinding.value.matchesCurrent()) return
        _messages.value = _messages.value.filterNot { it.id == message.id }
        persist()
    }

    private fun ConversationBinding?.matchesCurrent(): Boolean =
        this?.matches(roomId, boundWorldlineId) == true

    fun cancelResponse() {
        responseJob?.cancel()
        responseJob = null
        _isTyping.value = false
        _typingParticipantIds.value = emptySet()
        _isResponding.value = false
    }

    private fun respond(
        history: List<ChatMessage>,
        room: ChatRoom,
        model: AIModel,
        failingMessageId: UUID?
    ) {
        val id = roomId ?: run {
            _isResponding.value = false
            return
        }
        val conversation: List<ConversationTurn> = ConversationTurn.from(history)
        val group = room.groupChat
        val participantRooms = group?.participantRoomIds?.mapNotNull(store::room).orEmpty()
        if (group != null && participantRooms.size != group.participantRoomIds.size) {
            _isTyping.value = false
            _typingParticipantIds.value = emptySet()
            _isResponding.value = false
            _errorMessage.value = "참여자 정보를 찾을 수 없습니다."
            val failIndex = _messages.value.indexOfFirst { it.id == failingMessageId }
            if (failIndex >= 0) {
                _messages.value = _messages.value.toMutableList().also {
                    it[failIndex] = it[failIndex].copy(deliveryFailed = true)
                }
                persist()
            }
            return
        }
        val protocol = group?.let {
            GroupConversationProtocol(participantRooms)
        }
        val requestWorldlineId = group?.activeWorldlineId
        val requestBinding = ConversationBinding(id, requestWorldlineId)
        val requestConversationId = requestWorldlineId ?: id
        val requestMode = if (protocol == null) room.resolvedMode else ChatMode.COMPANION
        val requestModel = if (protocol == null) model else AIModel.GEMINI_37_FLASH
        val requestPersona = protocol?.persona ?: room.profile.persona.takeIf { it.isEnabled }
        val requestBotName = if (protocol == null) room.profile.name else room.title
        val suppressedExpressions = protocol?.persona?.suppressedExpressions
            ?: room.profile.persona.suppressedExpressions
        val personalAffectionEnabled = protocol == null && requestMode == ChatMode.COMPANION &&
            requestModel == AIModel.GEMINI_37_FLASH && !BuildConfig.TABLET_MENTOR
        val systemPromptOverride = protocol?.systemPrompt(room.title) ?: if (personalAffectionEnabled) {
            PersonalAffectionProtocol.systemPrompt(ai.systemPrompt(requestBotName, requestPersona, requestMode))
        } else null
        // 스트리밍은 문단이 완성되는 대로 화면에 붙으므로, 첫 문단을 붙이는 시점에는
        // 그 턴에 따옴표 대사가 나올지 아직 모릅니다. 앞 턴이 상황극이었다면 알려 줍니다.
        val wasRoleplaying = RoleplayParser.roleplayInProgress(history)
        val repeatControl = if (!BuildConfig.TABLET_MENTOR && requestMode == ChatMode.COMPANION) {
            repetitionAdviceFromConversation(conversation, suppressedExpressions)
        } else {
            null
        }

        responseJob?.cancel()
        responseJob = viewModelScope.launch {
            val responseTurnId = UUID.randomUUID()
            val groupBuffer = protocol?.let { GroupResponseBuffer(history) }
            val groupRawText = StringBuilder()
            val pendingGroupBubbles = mutableListOf<PendingGroupBubble>()
            var previousSpeakerId: UUID? = null
            var attempt = 0
            while (true) {
                try {
                    val rawText = ai.streamResponse(
                        conversation = conversation,
                        botName = requestBotName,
                        roomId = requestConversationId,
                        model = requestModel,
                        persona = requestPersona,
                        mode = requestMode,
                        roleplayInProgress = wasRoleplaying,
                        repetitionAdvice = repeatControl,
                        systemPromptOverride = systemPromptOverride,
                        onRawText = { piece -> if (protocol != null) groupRawText.append(piece) }
                    ) { bubble ->
                        val parsed = protocol?.parseBubble(bubble.text, bubble.kind, previousSpeakerId)
                        if (bubble.kind == com.sapiens.gagaodok.model.MessageKind.SPEECH) {
                            previousSpeakerId = parsed?.speakerRoomId ?: previousSpeakerId
                        }
                        val visibleText = parsed?.visibleText ?: if (personalAffectionEnabled) {
                            PersonalAffectionProtocol.visibleText(bubble.text)
                        } else bubble.text
                        if (visibleText.isEmpty() && bubble.attachment == null) return@streamResponse
                        if (groupBuffer == null) {
                            _isTyping.value = false
                            val message = ChatMessage(
                                sender = MessageSender.SAPIENS,
                                text = visibleText,
                                attachment = bubble.attachment,
                                turnId = responseTurnId,
                                kind = bubble.kind
                            )
                            _messages.value = _messages.value + message
                            persist(requestWorldlineId)
                        } else {
                            pendingGroupBubbles += PendingGroupBubble(
                                generated = bubble,
                                visibleText = visibleText,
                                speakerRoomId = if (bubble.kind == com.sapiens.gagaodok.model.MessageKind.SPEECH) parsed?.speakerRoomId else null,
                                reactions = parsed?.reactions.orEmpty()
                            )
                        }
                    }

                    _isTyping.value = false
                    if (groupBuffer != null) {
                        val scheduled = pendingGroupBubbles.mapIndexed { index, pending ->
                            GroupReplyBubble(
                                index = index,
                                visibleText = pending.visibleText,
                                kind = pending.generated.kind,
                                speakerRoomId = pending.speakerRoomId,
                                reactions = pending.reactions
                            )
                        }
                        val startedAt = SystemClock.elapsedRealtime()
                        val messageIds = mutableMapOf<Int, UUID>()
                        for (event in GroupReplyScheduler.plan(responseTurnId, scheduled)) {
                            val remaining = event.atMillis - (SystemClock.elapsedRealtime() - startedAt)
                            if (remaining > 0) delay(remaining)
                            when (event) {
                                is GroupReplyEvent.TypingStarted -> {
                                    _typingParticipantIds.value = _typingParticipantIds.value + event.participantRoomId
                                }
                                is GroupReplyEvent.TypingStopped -> {
                                    _typingParticipantIds.value = _typingParticipantIds.value - event.participantRoomId
                                }
                                is GroupReplyEvent.RevealBubble -> {
                                    val pending = pendingGroupBubbles[event.bubbleIndex]
                                    val message = ChatMessage(
                                        sender = MessageSender.SAPIENS,
                                        text = pending.visibleText,
                                        attachment = pending.generated.attachment,
                                        turnId = responseTurnId,
                                        kind = pending.generated.kind,
                                        speakerRoomId = pending.speakerRoomId
                                    )
                                    messageIds[event.bubbleIndex] = message.id
                                    groupBuffer.append(message)
                                    publishGroupResponse(requestBinding, groupBuffer)
                                    persist(id, requestWorldlineId, groupBuffer.messages)
                                }
                                is GroupReplyEvent.ApplyReaction -> {
                                    val messageId = messageIds[event.bubbleIndex] ?: continue
                                    val messageIndex = groupBuffer.messages.indexOfFirst { it.id == messageId }
                                    if (messageIndex >= 0) {
                                        val current = groupBuffer.messages[messageIndex]
                                        val reaction = MessageReaction(event.reaction.participantRoomId, event.reaction.emoji)
                                        if (reaction !in current.reactions) {
                                            groupBuffer.replace(messageIndex, current.copy(reactions = current.reactions + reaction))
                                            publishGroupResponse(requestBinding, groupBuffer)
                                            persist(id, requestWorldlineId, groupBuffer.messages)
                                        }
                                    }
                                }
                            }
                        }
                        _typingParticipantIds.value = emptySet()
                    }
                    // API에는 갈라지기 전 원문을 한 번만 보냅니다. 턴의 첫 말풍선에 담아 둡니다.
                    val responseMessages = groupBuffer?.messages ?: _messages.value
                    val firstIndex = responseMessages.indexOfFirst { it.turnId == responseTurnId }
                    if (firstIndex >= 0) {
                        val canonicalText = if (personalAffectionEnabled) PersonalAffectionProtocol.visibleText(rawText) else rawText
                        val canonical = responseMessages[firstIndex].copy(canonicalText = canonicalText)
                        if (groupBuffer == null) {
                            _messages.value = _messages.value.toMutableList().also { it[firstIndex] = canonical }
                            persist(requestWorldlineId)
                        } else {
                            groupBuffer.replace(firstIndex, canonical)
                            publishGroupResponse(requestBinding, groupBuffer)
                            persist(id, requestWorldlineId, groupBuffer.messages)
                        }
                    }
                    if (protocol != null && requestWorldlineId != null) {
                        protocol.heartDeltas(rawText).forEach { (participantRoomId, delta) ->
                            store.adjustWorldlineHeart(id, requestWorldlineId, participantRoomId, delta)
                        }
                    } else if (personalAffectionEnabled) {
                        store.adjustBaseAffection(id, PersonalAffectionProtocol.delta(rawText))
                    }
                    _isResponding.value = false
                    return@launch
                } catch (e: CancellationException) {
                    // 사용자가 멈춘 것은 실패가 아닙니다. 표시를 남기지 않습니다.
                    persistPartialGroupCanonical(groupBuffer, responseTurnId, groupRawText.toString(), requestBinding)
                    _isTyping.value = false
                    _typingParticipantIds.value = emptySet()
                    _isResponding.value = false
                    throw e
                } catch (e: Exception) {
                    // 말풍선이 이미 하나라도 붙었으면 다시 보낼 수 없습니다.
                    // 처음부터 다시 받으면 앞부분이 두 번 나옵니다.
                    val alreadyShown = (groupBuffer?.messages ?: _messages.value).any { it.turnId == responseTurnId }
                    if (alreadyShown) {
                        persistPartialGroupCanonical(groupBuffer, responseTurnId, groupRawText.toString(), requestBinding)
                    }
                    // **다시 보내도 소용없는 실패는 다시 보내지 않습니다.**
                    // 키가 틀렸거나 요청이 잘못됐으면 세 번을 보내도 똑같이 실패하고,
                    // 그 두 번은 화면에 아무것도 남기지 않은 채 요금만 냈습니다.
                    // 서비스가 아닌 곳에서 온 예외(주로 네트워크)는 다시 시도합니다.
                    val retryable = (e as? AIServiceException)?.retryable ?: true
                    if (protocol == null && !alreadyShown && retryable && attempt < SILENT_RETRIES) {
                        attempt += 1
                        continue
                    }
                    _isTyping.value = false
                    _typingParticipantIds.value = emptySet()
                    _isResponding.value = false
                    _errorMessage.value = e.message ?: "요청을 처리하지 못했습니다."
                    // 답변자 쪽에 오류 말풍선을 남기지 않습니다. 카카오톡처럼
                    // 내 말풍선에 표시를 달아 재전송하거나 지울 수 있게 합니다.
                    val failureMessages = groupBuffer?.messages ?: _messages.value
                    val failIndex = failureMessages.indexOfFirst { it.id == failingMessageId }
                    if (failIndex >= 0) {
                        val failed = failureMessages[failIndex].copy(deliveryFailed = true)
                        if (groupBuffer == null) {
                            _messages.value = _messages.value.toMutableList().also { it[failIndex] = failed }
                            persist(requestWorldlineId)
                        } else {
                            groupBuffer.replace(failIndex, failed)
                            publishGroupResponse(requestBinding, groupBuffer)
                            persist(id, requestWorldlineId, groupBuffer.messages)
                        }
                    }
                    return@launch
                }
            }
        }
    }

    private fun persistPartialGroupCanonical(
        buffer: GroupResponseBuffer?,
        turnId: UUID,
        rawText: String,
        binding: ConversationBinding
    ) {
        if (buffer == null || !buffer.preserveCanonical(turnId, rawText)) return
        publishGroupResponse(binding, buffer)
        persist(binding.roomId, binding.worldlineId, buffer.messages)
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
