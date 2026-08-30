package com.sapiens.gagaodok.sync

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class SyncSecretBundle(val accountMasterKey: ByteArray, val deviceToken: ByteArray) {
    init {
        require(accountMasterKey.size == 32)
        require(deviceToken.size == 32)
    }

    override fun equals(other: Any?): Boolean =
        other is SyncSecretBundle &&
            accountMasterKey.contentEquals(other.accountMasterKey) &&
            deviceToken.contentEquals(other.deviceToken)

    override fun hashCode(): Int = 31 * accountMasterKey.contentHashCode() + deviceToken.contentHashCode()
}

sealed interface SyncSecretLoadResult {
    data object Absent : SyncSecretLoadResult
    data class Available(val secrets: SyncSecretBundle) : SyncSecretLoadResult
    data object RelinkRequired : SyncSecretLoadResult
}

enum class SyncSecretSlot { ACTIVE, STAGING, ROLLBACK }

/**
 * Device-local sync-secret custody backed by a non-exportable Android Keystore
 * AES key. The encrypted blob lives in ordinary private preferences; it is not
 * a second secret and the application has `allowBackup=false`.
 *
 * A blob without its Keystore alias means a restored or reset device. `load`
 * returns `RelinkRequired` and never silently creates a replacement key.
 */
class SyncSecretStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun load(slot: SyncSecretSlot = SyncSecretSlot.ACTIVE): SyncSecretLoadResult {
        val encoded = prefs.getString(blobKey(slot), null) ?: return SyncSecretLoadResult.Absent
        val key = existingKey() ?: return SyncSecretLoadResult.RelinkRequired
        return runCatching {
            val blob = android.util.Base64.decode(encoded, android.util.Base64.NO_WRAP)
            require(blob.size >= 1 + IV_BYTES + TAG_BYTES)
            require(blob[0].toInt() == VERSION)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, blob, 1, IV_BYTES))
            val clear = cipher.doFinal(blob, 1 + IV_BYTES, blob.size - 1 - IV_BYTES)
            require(clear.size == SECRET_BYTES * 2)
            SyncSecretLoadResult.Available(
                SyncSecretBundle(clear.copyOfRange(0, SECRET_BYTES), clear.copyOfRange(SECRET_BYTES, clear.size))
            )
        }.getOrElse { SyncSecretLoadResult.RelinkRequired }
    }

    fun save(secrets: SyncSecretBundle, slot: SyncSecretSlot = SyncSecretSlot.ACTIVE): Boolean = runCatching {
        val key = existingKey() ?: createKey()
        val clear = secrets.accountMasterKey + secrets.deviceToken
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val encrypted = cipher.doFinal(clear)
        val blob = byteArrayOf(VERSION.toByte()) + cipher.iv + encrypted
        prefs.edit().putString(blobKey(slot), android.util.Base64.encodeToString(blob, android.util.Base64.NO_WRAP)).commit()
    }.getOrDefault(false)

    fun remove(slot: SyncSecretSlot = SyncSecretSlot.ACTIVE): Boolean = prefs.edit().remove(blobKey(slot)).commit()

    private fun existingKey(): SecretKey? = runCatching {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey
    }.getOrNull()

    private fun createKey(): SecretKey {
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return generator.generateKey()
    }

    companion object {
        private const val PREFS = "gagaodok_sync_secret_blob"
        private const val BLOB = "v1"
        internal fun blobKey(slot: SyncSecretSlot): String = when (slot) {
            SyncSecretSlot.ACTIVE -> BLOB
            SyncSecretSlot.STAGING -> "$BLOB.staging"
            SyncSecretSlot.ROLLBACK -> "$BLOB.rollback"
        }
        private const val KEYSTORE = "AndroidKeyStore"
        private const val ALIAS = "gagaodok.sync.wrap.v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val VERSION = 1
        private const val SECRET_BYTES = 32
        private const val IV_BYTES = 12
        private const val TAG_BYTES = 16
        private const val TAG_BITS = 128
    }
}
