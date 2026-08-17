package com.sapiens.gagaodok.service

import android.graphics.BitmapFactory
import android.util.Base64
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.roundToInt

/// 요청에 실릴 토큰 수를 어림합니다.
///
/// 캐시를 만들지 말지 정할 때 씁니다. 예전에는 글자 수만 셌는데, 사진은 글자가 0이라
/// 사진이 가득한 방이 오히려 캐시를 못 받았습니다. 사진 한 장이 대화 두어 턴만큼 무거우니
/// 정확히 거꾸로 동작한 셈입니다.
///
/// 계수는 실제 사용량 장부에서 뽑았습니다. 대화방 두 곳의 요청별 구성과 총 입력 토큰을
/// 연립해서 풀었고, 타일당 258 말고는 앞뒤가 맞는 해가 없었습니다.
object TokenEstimator {
    /// 한국어 대화 기준입니다. 영어는 글자당 토큰이 이보다 낮아 조금 넉넉하게 잡힙니다.
    const val TOKENS_PER_CHARACTER = 0.820

    /// 이미지는 타일로 잘려 들어가고 타일 하나가 258토큰입니다.
    const val TOKENS_PER_IMAGE_TILE = 258
    const val IMAGE_TILE_SIZE = 768

    /// 크기를 못 읽은 이미지는 최소 한 타일로 칩니다. 0으로 치면 예전 버그가 되살아납니다.
    const val FALLBACK_IMAGE_TOKENS = TOKENS_PER_IMAGE_TILE

    fun textTokens(text: String): Int = (text.length * TOKENS_PER_CHARACTER).roundToInt()

    fun imageTokens(width: Int, height: Int): Int {
        if (width <= 0 || height <= 0) return FALLBACK_IMAGE_TOKENS
        val columns = ceil(width.toDouble() / IMAGE_TILE_SIZE).toInt()
        val rows = ceil(height.toDouble() / IMAGE_TILE_SIZE).toInt()
        return max(1, columns * rows) * TOKENS_PER_IMAGE_TILE
    }

    /// 헤더만 읽어 크기를 알아냅니다. 전체를 디코드하면 큰 스크린샷에서 눈에 띄게 느려집니다.
    fun imageTokens(data: ByteArray): Int {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, options)
        return imageTokens(options.outWidth, options.outHeight)
    }

    fun imageTokensFromBase64(base64: String): Int = try {
        imageTokens(Base64.decode(base64, Base64.DEFAULT))
    } catch (_: IllegalArgumentException) {
        FALLBACK_IMAGE_TOKENS
    }
}
