package com.sapiens.gagaodok.sync

import java.io.File
import java.io.FileOutputStream
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

/**
 * Walking the server's two read paths into the opaque replica.
 *
 * Bootstrap first, one page at a time, then the account cursor starting at the
 * watermark that bootstrap fixed. That order is not a preference: a cursor
 * started anywhere else would either skip writes that landed behind the
 * snapshot or replay ones already inside it.
 *
 * The replica is the only thing this writes. It has no reference to `ChatStore`
 * or any conversation file, and nothing here decrypts a projection — the
 * entries stay opaque until a separate, later decision connects them to real
 * data.
 */

class SyncPullException(val reason: Reason, val statusCode: Int? = null) : Exception(reason.name) {
    enum class Reason {
        /** Bootstrap has not finished, so there is no watermark to pull from. */
        BOOTSTRAP_INCOMPLETE,

        /** The response was not the envelope this protocol version defines. */
        MALFORMED_ENVELOPE,
        HTTP_STATUS,
    }
}

data class SyncPullProgress(
    val bootstrapComplete: Boolean,
    /** The cursor for the next bootstrap page, or null when there is none left. */
    val bootstrapCursor: String?,
    /** The snapshot ceiling bootstrap fixed, which is where changes begins. */
    val snapshotWatermark: Long?,
    /** How far the account cursor has been scanned. */
    val changesCursor: Long?,
    val appliedItems: Int,
    val hasMore: Boolean,
)

/**
 * Where the walk has got to. Kept beside the replica rather than inside the
 * connection state, which is versioned and owned elsewhere.
 */
@Serializable
internal data class SyncPullState(
    val bootstrapComplete: Boolean = false,
    val bootstrapCursor: String? = null,
    val snapshotWatermark: Long? = null,
    val changesCursor: Long? = null,
)

class SyncPullCoordinator(
    private val client: SyncWorkerClient,
    private val replica: SyncReplicaStore,
    private val stateFile: File,
) {
    @Synchronized
    fun progress(): SyncPullProgress = loadState().let {
        SyncPullProgress(
            bootstrapComplete = it.bootstrapComplete,
            bootstrapCursor = it.bootstrapCursor,
            snapshotWatermark = it.snapshotWatermark,
            changesCursor = it.changesCursor,
            appliedItems = 0,
            hasMore = !it.bootstrapComplete,
        )
    }

    /**
     * Fetch and apply one bootstrap page.
     *
     * The page is applied before the cursor moves. A page that fails to parse or
     * fails to apply leaves both the replica and the cursor exactly as they
     * were, so the same page is fetched again rather than skipped.
     */
    @Synchronized
    fun advanceBootstrap(): SyncPullProgress {
        var state = loadState()
        if (state.bootstrapComplete) {
            return SyncPullProgress(true, null, state.snapshotWatermark, state.changesCursor, 0, false)
        }

        val response = fetch { client.bootstrap(state.bootstrapCursor) }
        val result = resultIn(
            response.body,
            setOf("snapshot_high_watermark_seq", "has_more", "next_cursor", "items"),
        )
        val watermark = sequenceIn(result, "snapshot_high_watermark_seq")
        val hasMore = booleanIn(result, "has_more")
        val items = result["items"] as? JsonArray ?: throw malformed()
        val nextCursor = cursorIn(result["next_cursor"], hasMore)

        // A snapshot that moved between pages is not a snapshot. The server
        // carries the watermark inside the cursor precisely so it cannot, and a
        // different one here means this page belongs to some other walk.
        val known = state.snapshotWatermark
        if (known != null && known != watermark) throw malformed()

        replica.apply(items.toString().toByteArray())

        state = state.copy(
            snapshotWatermark = watermark,
            bootstrapCursor = nextCursor,
            bootstrapComplete = !hasMore,
            // The account cursor starts exactly where the snapshot stopped, so
            // a write that landed behind the walk is picked up rather than lost.
            changesCursor = if (!hasMore) state.changesCursor ?: watermark else state.changesCursor,
        )
        saveState(state)
        return SyncPullProgress(
            bootstrapComplete = state.bootstrapComplete,
            bootstrapCursor = state.bootstrapCursor,
            snapshotWatermark = watermark,
            changesCursor = state.changesCursor,
            appliedItems = items.size,
            hasMore = hasMore,
        )
    }

    /**
     * Fetch and apply one changes page.
     *
     * Applying the same page twice is harmless: every change carries the current
     * projection for its identity and the replica keys on identity, so a device
     * that crashed mid-page converges on re-application.
     */
    @Synchronized
    fun advanceChanges(): SyncPullProgress {
        var state = loadState()
        val from = state.changesCursor
        if (!state.bootstrapComplete || from == null) {
            throw SyncPullException(SyncPullException.Reason.BOOTSTRAP_INCOMPLETE)
        }

        val response = fetch { client.changes(from) }
        val result = resultIn(
            response.body,
            setOf("scanned_through_seq", "account_high_watermark_seq", "has_more", "changes"),
        )
        val scanned = sequenceIn(result, "scanned_through_seq")
        val hasMore = booleanIn(result, "has_more")
        val changes = result["changes"] as? JsonArray ?: throw malformed()
        // A cursor that went backwards would replay applied work and could loop.
        if (scanned < from) throw malformed()

        val items = buildJsonArray {
            changes.forEach { element ->
                val change = element as? JsonObject ?: throw malformed()
                if (change.keys != CHANGE_KEYS) throw malformed()
                add(
                    buildJsonObject {
                        put("entity_type", change.getValue("entity_type"))
                        put("identity", change.getValue("identity"))
                        put("projection", change.getValue("projection"))
                    },
                )
            }
        }
        // One page, one apply. A page the replica refuses leaves the cursor
        // where it was, so nothing is silently skipped.
        replica.apply(items.toString().toByteArray())

        state = state.copy(changesCursor = scanned)
        saveState(state)
        return SyncPullProgress(
            bootstrapComplete = true,
            bootstrapCursor = null,
            snapshotWatermark = state.snapshotWatermark,
            changesCursor = scanned,
            appliedItems = items.size,
            hasMore = hasMore,
        )
    }

    /** Run one client call and present its failures on this coordinator's surface. */
    private fun fetch(work: () -> SyncHttpResponse): SyncHttpResponse = try {
        work()
    } catch (error: SyncWorkerClientException) {
        throw SyncPullException(SyncPullException.Reason.HTTP_STATUS, error.statusCode)
    }

    /**
     * The `result` object, with the envelope and its keys checked exactly.
     *
     * An unexpected key means the server is speaking a protocol this build does
     * not know. Ignoring it and reading the fields that happen to match is how a
     * client silently mis-applies a newer wire format.
     */
    private fun resultIn(body: ByteArray, keys: Set<String>): JsonObject = runCatching {
        require(body.size <= 8_000_000)
        val root = Json.parseToJsonElement(body.toString(Charsets.UTF_8)).jsonObject
        require(root.keys == ENVELOPE_KEYS)
        require(root.getValue("protocol_version").jsonPrimitive.content == "1")
        require(root.getValue("request_id").jsonPrimitive.content.isNotEmpty())
        val result = root.getValue("result").jsonObject
        require(result.keys == keys)
        result
    }.getOrElse { throw malformed() }

    private fun sequenceIn(result: JsonObject, key: String): Long = runCatching {
        result.getValue(key).jsonPrimitive.long.also { require(it >= 0) }
    }.getOrElse { throw malformed() }

    private fun booleanIn(result: JsonObject, key: String): Boolean = runCatching {
        (result.getValue(key) as JsonPrimitive).content.toBooleanStrict()
    }.getOrElse { throw malformed() }

    /**
     * `next_cursor` is a token when there is more and null when there is not.
     * Any other combination is a page this client will not act on.
     */
    private fun cursorIn(value: kotlinx.serialization.json.JsonElement?, hasMore: Boolean): String? {
        if (hasMore) {
            val token = (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw malformed()
            if (token.isEmpty() || token.length > 4_096) throw malformed()
            return token
        }
        if (value != null && value != JsonNull) throw malformed()
        return null
    }

    private fun malformed() = SyncPullException(SyncPullException.Reason.MALFORMED_ENVELOPE)

    private fun loadState(): SyncPullState {
        if (!stateFile.exists()) return SyncPullState()
        // Unreadable progress is restarted rather than guessed at: a wrong
        // cursor would skip pages, and a full re-walk is only slow.
        return runCatching { Json.decodeFromString<SyncPullState>(stateFile.readText()) }
            .getOrElse { SyncPullState() }
    }

    private fun saveState(state: SyncPullState) {
        stateFile.parentFile?.mkdirs()
        val temp = File(stateFile.parentFile, "${stateFile.name}.tmp")
        FileOutputStream(temp).use {
            it.write(Json.encodeToString(SyncPullState.serializer(), state).toByteArray())
            it.fd.sync()
        }
        if (!temp.renameTo(stateFile)) {
            temp.delete()
            throw malformed()
        }
    }

    private companion object {
        private val ENVELOPE_KEYS = setOf("protocol_version", "request_id", "result")
        private val CHANGE_KEYS = setOf(
            "change_seq", "entity_type", "change_kind", "revision", "identity", "projection",
        )
    }
}
