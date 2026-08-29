package com.sapiens.gagaodok.sync

import android.content.Context
import java.io.File
import java.net.URI
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Where the synthetic test endpoint comes from.
 *
 * Never a literal in this repository. The address of a deployed Worker is not a
 * secret, but hardcoding one means every build points at somebody's account and
 * a checkout can start talking to it by accident. The app reads it from a file
 * placed on the device, and when that file is absent the sync screen simply has
 * nothing to offer.
 *
 * This is the synthetic test environment only. It is not a route to real
 * conversation data, and nothing here enables synchronisation.
 */
@Serializable
data class SyncSyntheticEnvironment(
    val base_url: String,
    val account_id: String,
    val device_id: String,
    val enrollment_id: String,
) {
    /**
     * The host, for a screen that has to say *something* about where it points.
     * The host alone, never the full URL: a path or a query could carry a token.
     */
    val displayHost: String get() = runCatching { URI(base_url).host.orEmpty() }.getOrDefault("")

    companion object {
        fun file(context: Context): File = File(context.filesDir, "sync-synthetic.json")

        /**
         * Load the environment, or null when it is absent or does not check out.
         *
         * A malformed file is treated exactly like a missing one. Guessing at a
         * half-written endpoint is how a build ends up sending an enrollment
         * somewhere nobody intended.
         */
        fun load(file: File): SyncSyntheticEnvironment? = runCatching {
            val parsed = Json { ignoreUnknownKeys = true }
                .decodeFromString<SyncSyntheticEnvironment>(file.readText())
            val uri = URI(parsed.base_url)
            require(uri.scheme == "https" && !uri.host.isNullOrEmpty() && uri.query == null && uri.fragment == null)
            require(SyncConnectionConfiguration.UUID.matches(parsed.account_id))
            require(SyncConnectionConfiguration.UUID.matches(parsed.device_id))
            require(SyncConnectionConfiguration.UUID.matches(parsed.enrollment_id))
            parsed
        }.getOrNull()
    }
}
