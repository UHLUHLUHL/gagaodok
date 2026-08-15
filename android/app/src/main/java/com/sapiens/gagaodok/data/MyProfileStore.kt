package com.sapiens.gagaodok.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.sapiens.gagaodok.model.Codec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import java.io.File

@Serializable
data class MyProfile(
    val name: String = "나",
    val statusMessage: String = "",
    val musicTitle: String = "",
    val musicArtist: String = ""
)

/// 내 프로필입니다. 맥 판 `ProfileState` 자리입니다.
class MyProfileStore private constructor(context: Context) {

    private val dir = File(context.applicationContext.filesDir, "KakaoSapiens").apply {
        if (!exists()) mkdirs()
    }
    private val profileFile = File(dir, "profile.json")
    private val avatarFile = File(dir, "my_avatar.png")

    private val _profile = MutableStateFlow(
        runCatching { Codec.json.decodeFromString<MyProfile>(profileFile.readText()) }
            .getOrElse { MyProfile() }
    )
    val profile: StateFlow<MyProfile> = _profile

    private val _avatar = MutableStateFlow(
        if (avatarFile.exists()) BitmapFactory.decodeFile(avatarFile.absolutePath) else null
    )
    val avatar: StateFlow<Bitmap?> = _avatar

    fun update(name: String, statusMessage: String) {
        _profile.value = _profile.value.copy(name = name, statusMessage = statusMessage)
        runCatching { profileFile.writeText(Codec.json.encodeToString(_profile.value)) }
    }

    fun setAvatar(bitmap: Bitmap?) {
        _avatar.value = bitmap
        if (bitmap == null) {
            avatarFile.delete()
        } else {
            runCatching {
                avatarFile.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            }
        }
    }

    companion object {
        @Volatile
        private var instance: MyProfileStore? = null

        fun get(context: Context): MyProfileStore =
            instance ?: synchronized(this) {
                instance ?: MyProfileStore(context).also { instance = it }
            }
    }
}
