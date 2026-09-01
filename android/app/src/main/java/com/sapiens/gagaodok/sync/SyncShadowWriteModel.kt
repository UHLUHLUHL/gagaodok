package com.sapiens.gagaodok.sync

import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.MessageKind
import com.sapiens.gagaodok.model.MessageSender
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** What the button would copy, named before anything is sent. */
data class SyncShadowWriteTarget(
    val roomId: UUID,
    val title: String,
    val bubbleCount: Int,
    val attachmentCount: Int,
    val worldlineId: UUID?,
)

data class SyncShadowWriteResult(
    val manifest: SyncShadowWriteManifest,
    val uploadedOperations: Int,
    val skippedAttachments: Int,
)

sealed interface SyncShadowWriteState {
    data object Idle : SyncShadowWriteState
    data class Ready(val target: SyncShadowWriteTarget) : SyncShadowWriteState
    data object Running : SyncShadowWriteState
    data class Finished(val result: SyncShadowWriteResult) : SyncShadowWriteState
    data class Failed(val reason: String) : SyncShadowWriteState
}

/**
 * The reverse direction: this device's own room, copied up for the others.
 *
 * The room is found by the exact title the user gave it rather than by an id
 * nobody can read off a screen, and it is named on screen before anything is
 * sent. Two rooms sharing that title is refused rather than guessed at — this
 * phase copies one room, and picking the first of several would copy whichever
 * happened to sort first.
 *
 * Local conversation files are opened read-only. Nothing the Worker returns is
 * written back to them.
 */
class SyncShadowWriteModel(
    private val rooms: () -> List<ChatRoom>,
    private val messages: (ChatRoom) -> List<ChatMessage>,
    private val roomTitle: String,
    private val accountId: String,
    private val deviceId: String,
    private val spaceId: String,
    private val client: SyncWorkerClient,
    private val outbox: SyncOutbox,
    private val loadSecrets: () -> SyncSecretLoadResult,
) {
    private val _state = MutableStateFlow<SyncShadowWriteState>(SyncShadowWriteState.Idle)
    val state: StateFlow<SyncShadowWriteState> = _state

    private val timestamps: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC)

    /** Blocking; the screen runs it off the main thread. */
    fun inspect() {
        _state.value = runCatching {
            val room = resolveRoom()
            val stored = messages(room)
            SyncShadowWriteState.Ready(
                SyncShadowWriteTarget(
                    roomId = room.id,
                    title = room.title,
                    bubbleCount = stored.count { it.text.isNotEmpty() },
                    attachmentCount = stored.count { it.attachment != null },
                    worldlineId = room.groupChat?.activeWorldlineId,
                )
            )
        }.getOrElse { SyncShadowWriteState.Failed(reasonFor(it)) }
    }

    /** Blocking; the screen runs it off the main thread. */
    fun run() {
        if (_state.value is SyncShadowWriteState.Running) return
        val ready = _state.value as? SyncShadowWriteState.Ready ?: run {
            // Nothing is sent before the room has been named on screen.
            _state.value = SyncShadowWriteState.Failed("먼저 올릴 방을 확인하십시오.")
            return
        }
        _state.value = SyncShadowWriteState.Running
        _state.value = runCatching { copy(ready.target) }
            .map { SyncShadowWriteState.Finished(it) }
            .getOrElse { SyncShadowWriteState.Failed(reasonFor(it)) }
    }

    private fun copy(target: SyncShadowWriteTarget): SyncShadowWriteResult {
        val secrets = (loadSecrets() as? SyncSecretLoadResult.Available)
            ?: throw IllegalStateException("secrets")
        val room = resolveRoom()
        val stored = messages(room)

        var skipped = 0
        val outgoing = stored.mapNotNull { message ->
            if (message.attachment != null) skipped += 1
            if (message.text.isEmpty()) return@mapNotNull null
            SyncShadowOutgoingBubble(
                messageId = message.id.toString().uppercase(Locale.ROOT),
                // A message with no turn of its own is its own turn; inventing
                // a shared one would merge unrelated exchanges on the reader.
                turnId = (message.turnId ?: message.id).toString().uppercase(Locale.ROOT),
                sender = when (message.sender) {
                    MessageSender.USER -> "user"
                    MessageSender.SAPIENS -> "sapiens"
                },
                kind = when (message.kind) {
                    MessageKind.SPEECH -> "speech"
                    MessageKind.NARRATION -> "narration"
                },
                text = message.text,
                timestampRfc3339 = timestamps.format(Instant.ofEpochMilli(message.timestamp)),
            )
        }

        val writer = SyncShadowWriter(
            accountId = accountId,
            deviceId = deviceId,
            originSpaceId = spaceId,
            writerSpaceId = spaceId,
            masterKey = secrets.secrets.accountMasterKey,
        )
        val manifest = writer.write(
            roomId = target.roomId.toString().uppercase(Locale.ROOT),
            title = room.title,
            bubbles = outgoing,
            outbox = outbox,
            worldlineId = target.worldlineId?.toString()?.uppercase(Locale.ROOT),
        )

        var uploaded = 0
        // `drainOne` throws on a refusal and acknowledges only on success, so
        // the journal keeps the original bytes and the pass resumes rather
        // than being rebuilt from a conversation that may have moved on.
        while (client.drainOne(outbox) != null) uploaded += 1
        return SyncShadowWriteResult(manifest, uploaded, skipped)
    }

    private fun resolveRoom(): ChatRoom {
        val matches = rooms().filter { it.title.trim() == roomTitle }
        if (matches.isEmpty()) throw NoSuchElementException("room")
        if (matches.size > 1) throw IllegalStateException("ambiguous")
        return matches.single()
    }

    private fun reasonFor(error: Throwable): String = when {
        error is NoSuchElementException ->
            "이 기기에 \"$roomTitle\" 방이 없습니다."
        error is IllegalStateException && error.message == "ambiguous" ->
            "\"$roomTitle\" 이름의 방이 둘 이상입니다. 어느 것인지 정해지지 않아 아무것도 올리지 않았습니다."
        error is IllegalStateException && error.message == "secrets" ->
            "이 기기에 계정 키가 없습니다."
        error is SyncWorkerClientException ->
            "서버가 받지 않았습니다 (${error.statusCode}). 남은 것은 outbox에 그대로 있습니다."
        else -> "올리지 못했습니다. 원본 대화는 그대로입니다."
    }
}
