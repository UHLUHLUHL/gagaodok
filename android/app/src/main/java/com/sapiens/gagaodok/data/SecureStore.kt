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

    /// 열 수 없으면 `null`입니다. **던지지 않습니다.**
    ///
    /// `EncryptedSharedPreferences`는 마스터 키와 파일이 안 맞으면 여는 순간
    /// 예외를 던집니다. 기기 백업을 복원했거나 키스토어가 초기화된 뒤에 그렇게 됩니다.
    /// 예전에는 그 예외가 그대로 앱을 죽였습니다. 하필 설정 화면을 열거나 메시지를
    /// 보내는 순간이라 제일 잘 보이는 자리에서 죽었습니다.
    ///
    /// 그때는 파일을 버리고 새로 만듭니다. **키는 다시 넣어야 합니다.** 읽을 수 없는
    /// 암호문을 살릴 방법은 없습니다. 다만 앱은 삽니다.
    private fun prefs(context: Context): SharedPreferences? =
        prefs ?: synchronized(this) {
            prefs ?: open(context).also { prefs = it }
        }

    private fun open(context: Context): SharedPreferences? {
        val app = context.applicationContext
        runCatching { build(app) }.getOrNull()?.let { return it }

        // 한 번 더 시도합니다. 이번에는 못 읽는 파일을 버리고 빈 채로 시작합니다.
        runCatching { app.deleteSharedPreferences(FILE_NAME) }
        return runCatching { build(app) }.getOrNull()
    }

    private fun build(context: Context): SharedPreferences {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            context,
            FILE_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    fun apiKey(context: Context, credential: Credential): String? =
        prefs(context)?.getString(credential.key, null)?.takeIf { it.isNotEmpty() }

    /// 저장했으면 참입니다. **거짓이면 화면에서 알려야 합니다.**
    /// 조용히 실패하면 사용자는 키를 넣었다고 믿은 채로 계속 오류를 봅니다.
    fun save(context: Context, credential: Credential, key: String): Boolean {
        val store = prefs(context) ?: return false
        val trimmed = key.trim()
        return runCatching {
            store.edit().apply {
                if (trimmed.isEmpty()) remove(credential.key) else putString(credential.key, trimmed)
            }.commit()
        }.getOrDefault(false)
    }

    fun hasKey(context: Context, credential: Credential): Boolean =
        apiKey(context, credential) != null
}
