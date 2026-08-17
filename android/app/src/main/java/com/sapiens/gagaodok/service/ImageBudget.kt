package com.sapiens.gagaodok.service

import kotlin.math.floor
import kotlin.math.min

/// 사진을 몇 화소로 줄여 보낼지 정합니다.
///
/// **요금이 화소 수에 비례하지 않고 타일 수에 비례합니다.** Gemini는 사진을
/// 768×768 타일로 잘라 읽고 타일 하나가 258토큰입니다. 그래서 화소를 조금 줄이는
/// 것은 대개 요금을 한 푼도 못 줄이고, 타일 하나를 없앨 때만 258토큰이 통째로 빠집니다.
///
/// 예전에는 긴 변을 1600화소로만 맞췄습니다. 4:3 사진이면 1600×1200이 되는데,
/// 1600 ÷ 768 = 2.08이라 **세 번째 세로 타일이 생깁니다.** 그 타일에 실린 그림은
/// 폭 64화소뿐인데 요금은 다른 타일과 똑같이 냅니다. 6타일 = 1,548토큰이었습니다.
///
/// 지금은 타일 격자를 먼저 고르고 거기 꽉 차게 줄입니다. 같은 4:3 사진이 2×1 격자의
/// 1024×768이 되어 2타일 = 516토큰입니다. **같은 사진을 3분의 1 값에 보냅니다.**
///
/// 사진은 대화에 남아 있는 한 요청마다 다시 실리므로, 이 차이는 한 번이 아니라
/// 그 사진이 대화창에 있는 내내 매 턴 반복됩니다.
object ImageBudget {
    /// 타일 한 변입니다. 요금 단위가 이 격자로 매겨집니다.
    const val TILE = 768

    /// 이 아래로는 줄이지 않습니다.
    ///
    /// 이 앱에 올라오는 사진은 대개 문제지나 손으로 푼 풀이입니다. 타일을 하나로
    /// 줄이면 긴 변이 768화소가 되는데, 그러면 작은 글씨와 지수·첨자가 뭉갭니다.
    /// 900은 **잰 값이 아니라 정한 값입니다.** 실제로 안 읽히는 사진이 나오면
    /// 올려야 할 값입니다.
    const val MIN_LONG_SIDE = 900

    /// 격자를 이 이상은 키우지 않습니다. 3×3이면 9타일 = 2,322토큰입니다.
    private const val MAX_SIDE_TILES = 3

    data class Plan(val width: Int, val height: Int, val tiles: Int) {
        val tokens: Int get() = tiles * TokenEstimator.TOKENS_PER_IMAGE_TILE
    }

    fun tiles(width: Int, height: Int): Int {
        if (width <= 0 || height <= 0) return 1
        val columns = (width + TILE - 1) / TILE
        val rows = (height + TILE - 1) / TILE
        return maxOf(1, columns * rows)
    }

    /// 이 크기의 사진을 어떤 크기로 보낼지 정합니다.
    ///
    /// 타일이 적은 격자부터 넣어 보고, 줄인 결과의 긴 변이 [MIN_LONG_SIDE] 이상이면
    /// 그걸로 정합니다. 타일 수가 같으면 더 큰 쪽을 고릅니다.
    fun plan(width: Int, height: Int): Plan {
        if (width <= 0 || height <= 0) return Plan(width, height, 1)

        // 이미 작은 사진은 그대로 둡니다. 키우면 타일만 늘고 보이는 것은 그대로입니다.
        if (maxOf(width, height) <= MIN_LONG_SIDE) {
            return Plan(width, height, tiles(width, height))
        }

        val candidates = mutableListOf<Plan>()
        for (columns in 1..MAX_SIDE_TILES) {
            for (rows in 1..MAX_SIDE_TILES) {
                // 격자에 꽉 차게 줄입니다. 키우지는 않습니다.
                val scale = min(
                    min(TILE.toDouble() * columns / width, TILE.toDouble() * rows / height),
                    1.0
                )
                // 내림으로 잘라야 반올림 때문에 타일이 하나 더 생기는 일이 없습니다.
                val w = maxOf(1, floor(width * scale).toInt())
                val h = maxOf(1, floor(height * scale).toInt())
                if (maxOf(w, h) < MIN_LONG_SIDE) continue
                candidates += Plan(w, h, tiles(w, h))
            }
        }

        // 어떤 격자에도 안 맞을 만큼 극단적인 비율이면 긴 변만 맞춰 둡니다.
        val fallback = run {
            val scale = min(TILE.toDouble() * MAX_SIDE_TILES / maxOf(width, height), 1.0)
            val w = maxOf(1, floor(width * scale).toInt())
            val h = maxOf(1, floor(height * scale).toInt())
            Plan(w, h, tiles(w, h))
        }

        return candidates.minWithOrNull(
            compareBy<Plan> { it.tiles }.thenByDescending { it.width.toLong() * it.height }
        ) ?: fallback
    }

    /// 통째로 디코드하지 않고 몇 분의 1로 읽을지입니다.
    ///
    /// 1200만 화소 사진을 다 펼치면 48MB입니다. 어차피 줄일 것이라 읽을 때부터
    /// 줄여 읽습니다. `BitmapFactory`는 2의 거듭제곱만 받으므로, 목표보다 작아지지
    /// 않도록 **넘치지 않는 가장 큰 값**을 고릅니다.
    fun sampleSize(width: Int, height: Int, target: Plan): Int {
        var sample = 1
        while (width / (sample * 2) >= target.width && height / (sample * 2) >= target.height) {
            sample *= 2
        }
        return sample
    }
}
