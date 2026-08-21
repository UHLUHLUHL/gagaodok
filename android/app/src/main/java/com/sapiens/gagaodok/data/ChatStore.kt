package com.sapiens.gagaodok.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.Codec
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.model.PersonaStyle
import com.sapiens.gagaodok.model.RoomProfile
import com.sapiens.gagaodok.service.ConversationDigest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.encodeToString
import java.io.File
import java.util.UUID

/// 대화방과 대화 내용을 파일에 둡니다.
///
/// **파일 이름과 JSON 형식을 맥 판과 똑같이 맞췄습니다.** 맥에서 쓰던 기록을
/// 그대로 복사해 넣으면 읽힙니다. 그 호환을 지키느라 Swift 기준시 날짜와
/// 대문자 UUID를 쓰는데, 그 처리는 `Codec`에 모아 두었습니다.
class ChatStore private constructor(context: Context) {

    private val dir: File = File(context.applicationContext.filesDir, "KakaoSapiens").apply {
        if (!exists()) mkdirs()
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val writeLock = Mutex()

    private val roomsListFile get() = File(dir, "rooms_list.json")
    fun messagesFile(roomId: UUID) = File(dir, "room_${roomId.toString().uppercase()}_messages.json")
    fun digestFile(roomId: UUID) = File(dir, "room_${roomId.toString().uppercase()}_digest.json")
    fun avatarFile(roomId: UUID) = File(dir, "avatar_${roomId.toString().uppercase()}.png")

    private val _rooms = MutableStateFlow<List<ChatRoom>>(emptyList())
    val rooms: StateFlow<List<ChatRoom>> = _rooms

    /// 친구 목록에는 모든 상대가 나오고, 채팅 목록에는 대화를 시작한 방만 나옵니다.
    /// 카카오톡에서 친구를 추가해도 대화 전까지 채팅 목록에 안 뜨는 것과 같습니다.
    private val _roomsWithConversation = MutableStateFlow<Set<UUID>>(emptySet())
    val roomsWithConversation: StateFlow<Set<UUID>> = _roomsWithConversation

    init {
        val saved = loadRoomsFromDisk()
        if (saved.isNotEmpty()) {
            _rooms.value = saved
        } else {
            val defaultRoom = ChatRoom(
                title = "사피엔스",
                profile = RoomProfile(name = "사피엔스", statusMessage = "수학 학습 파트너 · 냉철한 피드백"),
                lastMessageText = "대화를 시작해보세요."
            )
            _rooms.value = listOf(defaultRoom)
            writeMessages(messagesFile(defaultRoom.id), emptyList())
            persistRooms()
        }
        refreshConversationIndex()
    }

    // MARK: - 방 목록

    fun room(id: UUID): ChatRoom? = _rooms.value.firstOrNull { it.id == id }

    fun hasConversation(roomId: UUID): Boolean = roomId in _roomsWithConversation.value

    private fun refreshConversationIndex() {
        // 빈 배열("[]")만 있는 파일은 대화가 없는 것으로 봅니다.
        _roomsWithConversation.value = _rooms.value
            .filter { messagesFile(it.id).let { f -> f.exists() && f.length() > 4 } }
            .map { it.id }
            .toSet()
    }

    /// 채팅 탭에 보여줄 방입니다. 고정한 방이 먼저, 그 뒤는 최근 대화 순입니다.
    fun conversationRooms(all: List<ChatRoom>, withConversation: Set<UUID>): List<ChatRoom> =
        all.filter { it.id in withConversation }
            .sortedWith(compareByDescending<ChatRoom> { it.isPinned }.thenByDescending { it.lastMessageTime })

    fun createRoom(name: String, status: String = "수학 학습 코치"): ChatRoom {
        val room = ChatRoom(
            title = name,
            profile = RoomProfile(name = name, statusMessage = status),
            lastMessageText = "대화를 시작해보세요."
        )
        // 인삿말 없이 빈 대화로 시작합니다.
        writeMessages(messagesFile(room.id), emptyList())
        _rooms.value = listOf(room) + _rooms.value
        persistRooms()
        return room
    }

    fun deleteRoom(id: UUID) {
        _rooms.value = _rooms.value.filterNot { it.id == id }
        _roomsWithConversation.value = _roomsWithConversation.value - id
        // 대화 기록과 아바타 파일도 같이 정리합니다.
        messagesFile(id).delete()
        digestFile(id).delete()
        avatarFile(id).delete()
        avatarCache.remove(id.toString())
        searchIndex.remove(id)
        persistRooms()
    }

    private fun update(roomId: UUID, transform: (ChatRoom) -> ChatRoom) {
        val list = _rooms.value
        val idx = list.indexOfFirst { it.id == roomId }
        if (idx < 0) return
        val updated = transform(list[idx])
        if (updated == list[idx]) return
        _rooms.value = list.toMutableList().also { it[idx] = updated }
        persistRooms()
    }

    fun updateProfile(roomId: UUID, name: String, statusMessage: String) =
        update(roomId) {
            it.copy(title = name, profile = it.profile.copy(name = name, statusMessage = statusMessage))
        }

    fun updateModel(roomId: UUID, model: AIModel) =
        update(roomId) { it.copy(modelIdentifier = model.rawValue) }

    fun updateMode(roomId: UUID, mode: ChatMode) =
        update(roomId) { it.copy(modeIdentifier = mode.rawValue) }

    fun updatePersona(roomId: UUID, persona: PersonaStyle) =
        update(roomId) { it.copy(profile = it.profile.copy(persona = persona)) }

    /// 사용자가 직접 선택한 표현만 방별 영구 규칙으로 추가합니다.
    /// 자동 감지 결과를 이 목록에 넣는 호출은 없습니다.
    fun suppressExpression(roomId: UUID, expression: String) {
        val trimmed = expression.trim()
        if (trimmed.isEmpty()) return
        update(roomId) { room ->
            val persona = room.profile.persona
            if (persona.suppressedExpressions.any { it.trim().equals(trimmed, ignoreCase = true) }) {
                room
            } else {
                room.copy(
                    profile = room.profile.copy(
                        persona = persona.copy(
                            suppressedExpressions = persona.suppressedExpressions + trimmed
                        )
                    )
                )
            }
        }
    }

    fun togglePinned(roomId: UUID) = update(roomId) { it.copy(isPinned = !it.isPinned) }

    fun updateAvatar(roomId: UUID, bitmap: Bitmap?) {
        val file = avatarFile(roomId)
        // 파일 이름이 그대로라 캐시를 비우지 않으면 옛 사진이 계속 보입니다.
        avatarCache.remove(roomId.toString())
        if (bitmap != null) {
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            update(roomId) { it.copy(profile = it.profile.copy(avatarImageFileName = file.name)) }
        } else {
            file.delete()
            update(roomId) { it.copy(profile = it.profile.copy(avatarImageFileName = null)) }
        }
    }

    /// 방 아바타를 캐시합니다.
    ///
    /// 이 함수는 목록 한 줄을 그릴 때마다 불립니다. 캐시가 없으면 400줄짜리 방에서
    /// 1MB 사진을 400번 읽고 디코드해서, 스크롤이 눈에 띄게 버벅입니다.
    private val avatarCache = LruCache<String, Bitmap>(40)

    fun avatar(roomId: UUID, profile: RoomProfile): Bitmap? {
        if (profile.avatarImageFileName == null) return null
        avatarCache.get(roomId.toString())?.let { return it }
        val file = avatarFile(roomId)
        if (!file.exists()) return null
        val bitmap = BitmapFactory.decodeFile(file.absolutePath) ?: return null
        avatarCache.put(roomId.toString(), bitmap)
        return bitmap
    }

    // MARK: - 대화 내용

    fun loadMessages(roomId: UUID): List<ChatMessage> {
        val file = messagesFile(roomId)
        if (!file.exists()) return emptyList()
        val raw = runCatching {
            Codec.json.decodeFromString<List<ChatMessage>>(file.readText())
        }.getOrElse { return emptyList() }

        val migrated = migrateLegacyTurns(raw)
        if (migrated.second) writeMessages(file, migrated.first)
        return migrated.first
    }

    // 답변은 말풍선 단위로 붙습니다. 그때마다 대화 전체를 인코딩해 쓰면
    // 첨부 이미지의 base64까지 매번 직렬화되어 디스크가 계속 들썩입니다.
    // 마지막 호출로부터 잠깐 조용해진 뒤 한 번만 저장하도록 모읍니다.
    private val pendingSaves = mutableMapOf<UUID, Pair<Job, List<ChatMessage>>>()
    private val saveCoalescingMillis = 700L

    fun saveMessages(roomId: UUID, messages: List<ChatMessage>) {
        // 대화가 바뀌면 검색 색인도 다시 만들어야 합니다.
        searchIndex[roomId] = messages.filter { it.text.isNotEmpty() }
            .map { SearchEntry(it.id, it.text, it.text.lowercase()) }

        synchronized(pendingSaves) {
            pendingSaves[roomId]?.first?.cancel()
            val job = scope.launch {
                delay(saveCoalescingMillis)
                writeLock.withLock { writeMessages(messagesFile(roomId), messages) }
                synchronized(pendingSaves) { pendingSaves.remove(roomId) }
            }
            pendingSaves[roomId] = job to messages
        }

        // 첫 메시지가 오는 순간 이 방이 채팅 목록에 나타나야 합니다.
        _roomsWithConversation.value = if (messages.isEmpty()) {
            _roomsWithConversation.value - roomId
        } else {
            _roomsWithConversation.value + roomId
        }

        val last = messages.lastOrNull() ?: return
        val preview = if (last.text.isEmpty()) "사진/파일 전송됨" else last.text
        update(roomId) { it.copy(lastMessageText = preview, lastMessageTime = last.timestamp) }
    }

    /// 앱이 내려가기 전에 아직 기다리고 있는 저장을 즉시 처리합니다.
    /// 저장을 0.7초 모아서 하기 때문에, 이게 없으면 마지막 말풍선이 유실될 수 있습니다.
    fun flushPendingSaves() {
        val pending = synchronized(pendingSaves) {
            pendingSaves.toMap().also { pendingSaves.clear() }
        }
        runBlocking {
            for ((roomId, entry) in pending) {
                entry.first.cancel()
                writeLock.withLock { writeMessages(messagesFile(roomId), entry.second) }
            }
        }
    }

    private fun writeMessages(file: File, messages: List<ChatMessage>) {
        runCatching {
            val tmp = File(file.parentFile, "${file.name}.tmp")
            tmp.writeText(Codec.json.encodeToString(messages))
            tmp.renameTo(file)
        }
    }

    // MARK: - 구간 요약

    fun loadDigest(roomId: UUID): ConversationDigest {
        val file = digestFile(roomId)
        if (!file.exists()) return ConversationDigest()
        return runCatching {
            Codec.json.decodeFromString<ConversationDigest>(file.readText())
        }.getOrElse { ConversationDigest() }
    }

    fun saveDigest(roomId: UUID, digest: ConversationDigest) {
        scope.launch {
            runCatching { digestFile(roomId).writeText(Codec.json.encodeToString(digest)) }
        }
    }

    // MARK: - 대화 내용 검색 색인
    //
    // 메시지 파일에는 사진이 base64로 함께 들어 있어 통째로 읽으면 수 MB입니다.
    // 타자마다 읽을 수는 없으므로 글자만 뽑아 방마다 한 번씩 담아 둡니다.
    private data class SearchEntry(val id: UUID, val text: String, val lowercased: String)

    private val searchIndex = mutableMapOf<UUID, List<SearchEntry>>()

    private fun searchEntries(roomId: UUID): List<SearchEntry> =
        searchIndex.getOrPut(roomId) {
            loadMessages(roomId).filter { it.text.isNotEmpty() }
                .map { SearchEntry(it.id, it.text, it.text.lowercase()) }
        }

    /// 그 방에서 검색어를 담은 마지막 메시지입니다. 없으면 null입니다.
    fun firstMatch(roomId: UUID, query: String): String? {
        val needle = query.lowercase()
        if (needle.isEmpty()) return null
        return searchEntries(roomId).lastOrNull { it.lowercased.contains(needle) }?.text
    }

    /// 창을 열 때 미리 만들어 둡니다. 첫 검색에서 한꺼번에 읽느라 멈추지 않도록요.
    fun primeSearchIndex() {
        scope.launch {
            _rooms.value.forEach { searchEntries(it.id) }
        }
    }

    // MARK: - 저장

    private fun persistRooms() {
        val snapshot = _rooms.value
        scope.launch {
            writeLock.withLock {
                runCatching {
                    val tmp = File(dir, "rooms_list.json.tmp")
                    tmp.writeText(Codec.json.encodeToString(snapshot))
                    tmp.renameTo(roomsListFile)
                }
            }
        }
    }

    private fun loadRoomsFromDisk(): List<ChatRoom> {
        if (!roomsListFile.exists()) return emptyList()
        return runCatching {
            Codec.json.decodeFromString<List<ChatRoom>>(roomsListFile.readText())
        }.getOrElse { emptyList() }
    }

    private fun migrateLegacyTurns(messages: List<ChatMessage>): Pair<List<ChatMessage>, Boolean> {
        if (messages.none { it.turnId == null }) return messages to false
        val migrated = messages.toMutableList()
        var index = 0

        while (index < migrated.size) {
            if (migrated[index].sender == MessageSender.USER) {
                val id = migrated[index].turnId ?: UUID.randomUUID()
                migrated[index] = migrated[index].copy(
                    turnId = id,
                    canonicalText = migrated[index].canonicalText ?: migrated[index].text
                )
                index += 1
                continue
            }

            val start = index
            while (index < migrated.size && migrated[index].sender == MessageSender.SAPIENS) index += 1
            val id = migrated[start].turnId ?: UUID.randomUUID()
            val canonical = migrated.subList(start, index)
                .map { it.text }.filter { it.isNotEmpty() }.joinToString("\n\n")
            for (position in start until index) {
                migrated[position] = migrated[position].copy(
                    turnId = id,
                    canonicalText = if (position == start) canonical else null
                )
            }
        }
        return migrated to true
    }

    companion object {
        @Volatile
        private var instance: ChatStore? = null

        fun get(context: Context): ChatStore =
            instance ?: synchronized(this) {
                instance ?: ChatStore(context).also { instance = it }
            }
    }
}
