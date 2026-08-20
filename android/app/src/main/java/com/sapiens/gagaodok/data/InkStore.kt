package com.sapiens.gagaodok.data

import android.content.Context
import com.sapiens.gagaodok.model.Codec
import com.sapiens.gagaodok.model.InkDocument
import com.sapiens.gagaodok.service.InkCoordinateSpace
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.encodeToString
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking

/**
 * 필기 원본은 채팅 말풍선과 분리해 로컬에 저장합니다.
 *
 * 필기 중에는 메모리의 벡터 포인트만 갱신하고, 펜을 뗐을 때만 비동기로 JSON을 씁니다.
 * 따라서 매 move 이벤트마다 파일과 PNG를 만들지 않아 필기감과 메모리를 지킵니다.
 */
class InkStore private constructor(context: Context) {
    private val directory = File(context.applicationContext.filesDir, "KakaoSapiens").apply { mkdirs() }
    private val file = File(directory, "ink_documents.json")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val writeLock = Mutex()

    private var migrationNeeded = false
    private val _documents = MutableStateFlow(load())
    val documents: StateFlow<List<InkDocument>> = _documents

    init {
        if (migrationNeeded) persistAsync()
    }

    fun document(id: UUID): InkDocument? = _documents.value.firstOrNull { it.id == id }

    fun save(document: InkDocument) {
        val updated = document.copy(updatedAtMillis = System.currentTimeMillis())
        _documents.value = (_documents.value.filterNot { it.id == updated.id } + updated)
            .sortedByDescending { it.updatedAtMillis }
        persistAsync()
    }

    fun rename(id: UUID, title: String) {
        val clean = title.trim().ifEmpty { "새 필기" }.take(60)
        document(id)?.let { save(it.copy(title = clean)) }
    }

    fun delete(id: UUID) {
        _documents.value = _documents.value.filterNot { it.id == id }
        persistAsync()
    }

    /** 마지막 획을 쓴 직후 앱이 백그라운드로 가도 원본이 남도록 동기화합니다. */
    fun flushPendingSaves() {
        val snapshot = _documents.value
        runBlocking {
            writeLock.withLock { write(snapshot) }
        }
    }

    fun forRoom(roomId: UUID): List<InkDocument> =
        _documents.value.filter { it.roomId == roomId.toString() }

    private fun load(): List<InkDocument> = runCatching {
        if (!file.exists()) {
            emptyList()
        } else {
            Codec.json.decodeFromString<List<InkDocument>>(file.readText()).map { document ->
                InkCoordinateSpace.toCurrent(document).also { migrated ->
                    if (migrated != document) migrationNeeded = true
                }
            }
        }
    }.getOrDefault(emptyList()).sortedByDescending { it.updatedAtMillis }

    private fun persistAsync() {
        val snapshot = _documents.value
        scope.launch {
            writeLock.withLock {
                runCatching {
                    write(snapshot)
                }
            }
        }
    }

    private fun write(snapshot: List<InkDocument>) {
        runCatching {
            val temporary = File(directory, "${file.name}.tmp")
            temporary.writeText(Codec.json.encodeToString(snapshot))
            if (!temporary.renameTo(file)) {
                file.delete()
                temporary.renameTo(file)
            }
        }
    }

    companion object {
        @Volatile private var instance: InkStore? = null

        fun get(context: Context): InkStore = instance ?: synchronized(this) {
            instance ?: InkStore(context).also { instance = it }
        }
    }
}
