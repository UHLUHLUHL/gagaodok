package com.sapiens.gagaodok.ui.components

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import android.util.LruCache
import com.sapiens.gagaodok.model.AttachmentType
import com.sapiens.gagaodok.model.ChatAttachment

/// 첨부 이미지를 첨부 id 기준으로 캐시합니다.
///
/// 캐시가 없으면 화면을 다시 그릴 때마다 base64를 디코드하고 비트맵을 새로 만듭니다.
/// 답변이 말풍선 단위로 붙는 동안 화면 전체가 반복해서 다시 그려지므로,
/// 스크린샷 한 장이 초당 여러 번 디코드되면서 이미지가 깜빡이고 스크롤이 끊깁니다.
/// 맥 판에서 실제로 그랬습니다.
object AttachmentImageCache {

    // 원본 해상도 스크린샷이 쌓여도 메모리를 물고 있지 않도록 상한을 둡니다.
    private val cache = object : LruCache<String, Bitmap>(48 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }

    fun bitmap(attachment: ChatAttachment): Bitmap? {
        if (attachment.type != AttachmentType.IMAGE) return null
        val key = attachment.id.toString()
        cache.get(key)?.let { return it }
        val decoded = runCatching {
            val bytes = Base64.decode(attachment.dataBase64, Base64.DEFAULT)
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }.getOrNull() ?: return null
        cache.put(key, decoded)
        return decoded
    }

    fun clear() = cache.evictAll()
}
