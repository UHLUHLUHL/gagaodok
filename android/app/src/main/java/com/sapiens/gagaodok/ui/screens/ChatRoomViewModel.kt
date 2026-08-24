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
import com.sapiens.gagaodok.model.MessageHeartChange
import com.sapiens.gagaodok.model.MessageReaction
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.service.AIService
import com.sapiens.gagaodok.service.AIServiceException
import com.sapiens.gagaodok.service.GeneratedMessageBubble
import com.sapiens.gagaodok.service.GroupConversationProtocol
import com.sapiens.gagaodok.service.GroupReplyBubble
import com.sapiens.gagaodok.service.GroupReplyTimeline
import com.sapiens.gagaodok.service.PersonalAffectionProtocol
import com.sapiens.gagaodok.service.PlannedReaction
import com.sapiens.gagaodok.service.RoleplayParser
import com.sapiens.gagaodok.service.repetitionAdviceFromConversation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
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

/// 방금 끝난 턴에서 일어난 호감도 변화입니다.
data class AffectionCue(val turnId: UUID, val changes: List<MessageHeartChange>)

/// 호감도 카드가 스스로 펼쳐져 있는 시간입니다.
///
/// 지나면 접습니다. 사용자가 스크롤하거나 입력을 시작하면 이 시간을 기다리지 않고 바로
/// 접습니다. 읽는 데 걸리는 시간과 대화를 가리는 시간 사이의 타협이라 **짐작입니다.**
internal const val AFFECTION_CUE_MILLIS = 4_000L

/// 단톡방에서 지금 누가 입력 중으로 보이는지입니다.
sealed interface GroupTypingState {
    /// 아무도 입력 중이 아닙니다. **이 턴이 끝났다는 뜻입니다.**
    data object Idle : GroupTypingState

    /// 누군가 쓰고 있지만 아직 누구인지 모릅니다. 이름 없이 참여자 아바타만 보여줍니다.
    ///
    /// 응답이 오기 전에는 화자를 알 수 없어 한 명을 추측해 보여주는데, 그 추측이 오래
    /// 노출되면 명백한 거짓말이 됩니다. 실기기에서 "아라 입력 중"이 23초 떠 있다가
    /// 마린이 말한 적이 있습니다. 짧은 대기에는 추측이 대체로 맞으니 이름을 보여주고,
    /// [GUESS_GRACE_MILLIS]가 지나도록 응답이 없으면 이름을 내려 이 상태로 물러납니다.
    data object Unknown : GroupTypingState

    /// 이 사람이 입력 중입니다.
    data class Speaking(val roomId: UUID) : GroupTypingState
}

/// 추측한 화자의 이름을 보여줄 수 있는 시간입니다. (짐작)
private const val GUESS_GRACE_MILLIS = 3_000L

/// 화자가 확정된 뒤 말풍선이 뜨기 전에 그 사람의 입력 표시를 최소한 보여줄 시간입니다.
///
/// 응답이 계획보다 늦게 오면 예정 시각이 이미 지나 있어서 말풍선이 곧바로 떠 버립니다.
/// 그러면 정작 오래 기다린 턴에서 "누가 말하는지"의 연출이 통째로 사라집니다. 23초를
/// 기다린 뒤의 이 짧은 시간은 체감되지 않습니다. (짐작)
private const val MIN_TYPING_VISIBLE_MILLIS = 600L

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

    /// 단톡방 입력 표시의 상태입니다.
    ///
    /// **[GroupTypingState.Idle]은 이 턴이 끝났다는 뜻입니다.** 그 밖의 상태인 동안에는
    /// 모델이 아직 쓰고 있거나 보여줄 말풍선이 남아 있습니다. 사용자는 이 표시 하나만
    /// 보고 "더 오나"를 판단할 수 있어야 합니다.
    ///
    /// 한 명만 두는 이유가 있습니다. 두 명이 동시에 입력 중이면 누가 말할 차례인지
    /// 흐려지고, "눌러서 중지"도 두 개가 떠서 무엇을 멈추는지 헷갈립니다. 그리고 어차피
    /// 대사는 한 번의 호출에서 순서대로 만들어지므로, 동시에 치는 두 사람은 실제로
    /// 존재하지 않습니다.
    private val _groupTyping = MutableStateFlow<GroupTypingState>(GroupTypingState.Idle)
    val groupTyping: StateFlow<GroupTypingState> = _groupTyping

    private val _isResponding = MutableStateFlow(false)
    val isResponding: StateFlow<Boolean> = _isResponding

    /// 방금 일어난 호감도 변화입니다. 카드가 스스로 펼쳐져 이유를 보여줄 신호입니다.
    ///
    /// 비어 있으면 평소 상태입니다. 화면이 다 보여준 뒤 [clearAffectionCue]로 지웁니다.
    private val _affectionCue = MutableStateFlow<AffectionCue?>(null)
    val affectionCue: StateFlow<AffectionCue?> = _affectionCue

    /// 자동으로 접히거나, 사용자가 스크롤·입력으로 먼저 물릴 때 호출합니다.
    fun clearAffectionCue() {
        if (_affectionCue.value != null) _affectionCue.value = null
    }

    private fun clearTyping() {
        if (_groupTyping.value != GroupTypingState.Idle) _groupTyping.value = GroupTypingState.Idle
    }


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
        clearTyping()
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
        clearTyping()
        _isResponding.value = false
    }

    /// 모델이 만들어 내는 말풍선을 도착하는 대로 화면에 올립니다.
    ///
    /// 입력 표시는 이 함수가 도는 내내 떠 있고, 함수가 끝날 때 내려갑니다. 그래서 사용자에게
    /// 표시의 유무가 곧 "이 턴이 진행 중인가"입니다.
    ///
    /// 다음 말풍선의 화자는 그것이 도착하기 전에는 알 수 없습니다. 모르는 동안에는 **직전
    /// 화자를 그대로 둡니다.** 같은 사람이 이어서 치는 것으로 보이고, 실제로 그 사람이
    /// 이어서 말하는 경우도 많아 대개는 맞습니다. 틀리면 다음 말풍선이 도착할 때 바뀝니다.
    private suspend fun playGroupBubbles(
        channel: Channel<PendingGroupBubble>,
        buffer: GroupResponseBuffer,
        turnId: UUID,
        turnStartedAt: Long,
        roomId: UUID,
        worldlineId: UUID?,
        binding: ConversationBinding,
        onSpeakerKnown: () -> Unit
    ) = coroutineScope {
        val timeline = GroupReplyTimeline(turnId)
        var index = 0
        for (pending in channel) {
            val step = timeline.next(
                GroupReplyBubble(
                    index = index,
                    visibleText = pending.visibleText,
                    kind = pending.generated.kind,
                    speakerRoomId = pending.speakerRoomId,
                    reactions = pending.reactions
                )
            )
            // 이제 이 말풍선의 화자를 알았으므로 입력 표시를 그 사람으로 맞춥니다.
            val speakerShownAt = SystemClock.elapsedRealtime()
            if (pending.speakerRoomId != null) {
                onSpeakerKnown()
                _groupTyping.value = GroupTypingState.Speaking(pending.speakerRoomId)
            }
            delayUntil(turnStartedAt + step.revealAt)
            // 응답이 늦게 오면 예정 시각이 이미 지나 있어 말풍선이 곧바로 떠 버립니다.
            // 오래 기다린 턴일수록 연출이 사라지는 셈이라, 최소한의 입력 표시를 보장합니다.
            if (pending.speakerRoomId != null) delayUntil(speakerShownAt + MIN_TYPING_VISIBLE_MILLIS)
            // 모델이 늦게 써서 예정보다 뒤에 떴다면 실제 시각으로 기준을 옮깁니다.
            timeline.commitReveal(SystemClock.elapsedRealtime() - turnStartedAt)

            val message = ChatMessage(
                sender = MessageSender.SAPIENS,
                text = pending.visibleText,
                attachment = pending.generated.attachment,
                turnId = turnId,
                kind = pending.generated.kind,
                speakerRoomId = pending.speakerRoomId
            )
            buffer.append(message)
            publishGroupResponse(binding, buffer)
            persist(roomId, worldlineId, buffer.messages)

            pending.reactions.forEachIndexed { reactionIndex, planned ->
                val at = step.reactionAt.getOrNull(reactionIndex) ?: return@forEachIndexed
                // 반응은 말풍선보다 뒤에 붙지만, 다음 말풍선을 기다리게 하지는 않습니다.
                launch {
                    delayUntil(turnStartedAt + at)
                    val messageIndex = buffer.messages.indexOfFirst { it.id == message.id }
                    if (messageIndex < 0) return@launch
                    val current = buffer.messages[messageIndex]
                    val reaction = MessageReaction(planned.participantRoomId, planned.emoji)
                    if (reaction in current.reactions) return@launch
                    buffer.replace(messageIndex, current.copy(reactions = current.reactions + reaction))
                    publishGroupResponse(binding, buffer)
                    persist(roomId, worldlineId, buffer.messages)
                }
            }
            index += 1
        }
        // 통로가 닫혔고 남은 말풍선도 다 보여줬습니다. 표시를 내리는 것이 곧 "턴이 끝났다"입니다.
        clearTyping()
    }

    private suspend fun delayUntil(targetElapsedRealtime: Long) {
        val remaining = targetElapsedRealtime - SystemClock.elapsedRealtime()
        if (remaining > 0) delay(remaining)
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
            clearTyping()
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
        if (protocol != null) {
            // 보내자마자 캐릭터 한 명이 입력 중으로 보입니다. 응답을 기다리는 동안 앱 사정을
            // 알리는 표시가 화면에 남지 않게 합니다.
            _isTyping.value = false
            _groupTyping.value = GroupTypingState.Speaking(
                protocol.guessFirstSpeaker(
                    history = history,
                    userText = history.lastOrNull { it.sender == MessageSender.USER }?.text.orEmpty()
                )
            )
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
            var previousSpeakerId: UUID? = null
            var attempt = 0
            // 사용자가 보낸 순간을 0으로 잡습니다. 연출 시간을 API 응답 시간 **뒤에** 이어
            // 붙이면 둘이 더해져서 첫 글자까지 7초가 넘게 걸립니다. 겹쳐야 합니다.
            val turnStartedAt = SystemClock.elapsedRealtime()
            // 스트리밍이 만들어 내는 말풍선을 받아 두는 통로입니다. 재생은 이 통로를 읽는
            // 별도 코루틴이 맡으므로, 모델이 아직 쓰는 중에도 앞 말풍선을 보여줄 수 있습니다.
            val bubbleChannel = if (groupBuffer == null) null else Channel<PendingGroupBubble>(Channel.UNLIMITED)
            // 추측한 화자의 이름을 언제까지 보여줄지를 재는 시계입니다.
            var speakerConfirmed = false
            var guessGrace: Job? = null
            val playback = if (groupBuffer == null || bubbleChannel == null) null else launch {
                playGroupBubbles(
                    channel = bubbleChannel,
                    buffer = groupBuffer,
                    turnId = responseTurnId,
                    turnStartedAt = turnStartedAt,
                    roomId = id,
                    worldlineId = requestWorldlineId,
                    binding = requestBinding,
                    onSpeakerKnown = {
                        speakerConfirmed = true
                        guessGrace?.cancel()
                    }
                )
            }
            guessGrace = if (groupBuffer == null) null else launch {
                delay(GUESS_GRACE_MILLIS)
                // 아직 응답이 없으면 추측한 이름을 내립니다. 틀린 이름을 오래 붙여 두는 것보다
                // 이름 없이 "누군가 쓰는 중"만 보여주는 편이 낫습니다.
                if (!speakerConfirmed && _groupTyping.value is GroupTypingState.Speaking) {
                    _groupTyping.value = GroupTypingState.Unknown
                }
            }
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
                            bubbleChannel?.trySend(
                                PendingGroupBubble(
                                    generated = bubble,
                                    visibleText = visibleText,
                                    speakerRoomId = if (bubble.kind == com.sapiens.gagaodok.model.MessageKind.SPEECH) parsed?.speakerRoomId else null,
                                    reactions = parsed?.reactions.orEmpty()
                                )
                            )
                        }
                    }

                    _isTyping.value = false
                    // 통로를 닫으면 재생 쪽이 "더 올 말풍선이 없다"를 압니다. 남은 것을 다
                    // 보여주고 입력 표시를 내린 뒤에 끝납니다.
                    bubbleChannel?.close()
                    playback?.join()
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
                        val changes = protocol.heartChanges(rawText).filter { it.delta != 0 }
                        changes.forEach { change ->
                            store.adjustWorldlineHeart(id, requestWorldlineId, change.participantRoomId, change.delta)
                        }
                        if (changes.isNotEmpty() && groupBuffer != null) {
                            // 변화를 **턴의 마지막 말풍선**에 붙여 둡니다. 나중에 대화를 거슬러
                            // 올라가도 "이때 왜 변했는지"가 그 자리에 남습니다.
                            val stored = changes.map {
                                MessageHeartChange(it.participantRoomId, it.delta, it.reason)
                            }
                            val lastIndex = groupBuffer.messages.indexOfLast { it.turnId == responseTurnId }
                            if (lastIndex >= 0) {
                                groupBuffer.replace(lastIndex, groupBuffer.messages[lastIndex].copy(heartChanges = stored))
                                publishGroupResponse(requestBinding, groupBuffer)
                                persist(id, requestWorldlineId, groupBuffer.messages)
                            }
                            // 마지막 말풍선이 뜬 **뒤**에 카드를 펼칩니다. 중간에 펼치면 대화를 가립니다.
                            if (requestBinding.matches(roomId, boundWorldlineId)) {
                                _affectionCue.value = AffectionCue(responseTurnId, stored)
                            }
                        }
                    } else if (personalAffectionEnabled) {
                        store.adjustBaseAffection(id, PersonalAffectionProtocol.delta(rawText))
                    }
                    _isResponding.value = false
                    return@launch
                } catch (e: CancellationException) {
                    // 사용자가 멈춘 것은 실패가 아닙니다. 표시를 남기지 않습니다.
                    bubbleChannel?.close()
                    persistPartialGroupCanonical(groupBuffer, responseTurnId, groupRawText.toString(), requestBinding)
                    _isTyping.value = false
                    clearTyping()
                    _isResponding.value = false
                    throw e
                } catch (e: Exception) {
                    // 재생 쪽이 통로를 기다리며 남아 있지 않게 먼저 닫습니다. 닫지 않으면
                    // 이 코루틴이 자식을 기다리느라 끝나지 않습니다.
                    bubbleChannel?.close()
                    playback?.join()
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
                    clearTyping()
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
