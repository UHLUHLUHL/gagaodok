package com.sapiens.gagaodok.data

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/// API 키를 두는 곳입니다. 맥 판의 키체인에 해당합니다.
///
/// **APK는 뜯어보면 안이 다 보입니다.** 키를 코드나 리소스에 넣으면 안 됩니다.
/// 사용자가 설정 화면에서 직접 넣고, 그 값은 안드로이드 키스토어가 만든 키로
/// 암호화해 저장합니다. 맥 판이 키를 키체인에 두는 것과 같은 이유이고 같은 방식입니다.
object SecureStore {

    /// 공급자마다 항목을 따로 둡니다. 한쪽 키를 지워도 다른 쪽은 남습니다.
    enum class Credential(val key: String, val displayName: String) {
        GEMINI("gemini-api-key", "Gemini"),
        OPENAI("openai-api-key", "OpenAI")
    }

    private const val FILE_NAME = "gagaodok_secure"

    @Volatile
    private var prefs: SharedPreferences? = null

    private fun prefs(context: Context): SharedPreferences =
        prefs ?: synchronized(this) {
            prefs ?: create(context).also { prefs = it }
        }

    private fun create(context: Context): SharedPreferences {
        val masterKey = MasterKey.Builder(context.applicationContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            context.applicationContext,
            FILE_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    fun apiKey(context: Context, credential: Credential): String? =
        prefs(context).getString(credential.key, null)?.takeIf { it.isNotEmpty() }

    fun save(context: Context, credential: Credential, key: String) {
        val trimmed = key.trim()
        prefs(context).edit().apply {
            if (trimmed.isEmpty()) remove(credential.key) else putString(credential.key, trimmed)
        }.apply()
    }

    fun hasKey(context: Context, credential: Credential): Boolean =
        apiKey(context, credential) != null
}
