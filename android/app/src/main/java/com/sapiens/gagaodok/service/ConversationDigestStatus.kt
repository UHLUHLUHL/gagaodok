package com.sapiens.gagaodok.service

/**
 * 한 방의 요약이 지금 어디까지 왔는지입니다.
 *
 * 화면에서 떼어낸 이유는 이 계산이 검증 가능해야 하기 때문입니다. 턴 수와 구간
 * 목록만 있으면 정해지므로 앱을 띄우지 않고 시험할 수 있습니다.
 */
data class ConversationDigestStatus(
    /** 이 방의 사용자 턴 수입니다. */
    val totalTurns: Int,
    /** 요약이 덮은 마지막 턴입니다. 요약이 없으면 0입니다. */
    val coveredTurns: Int,
    val segments: List<ConversationSegment>,
) {
    /** 요약이 시작될 만큼 대화가 길어졌는가. */
    val isActive: Boolean get() = totalTurns >= ConversationCompactor.THRESHOLD_TURNS

    /** 요약 없이 원문 그대로 나가는 턴 수입니다. */
    val verbatimTurns: Int get() = (totalTurns - coveredTurns).coerceAtLeast(0)

    /**
     * 다음 일이 벌어지기까지 남은 턴 수입니다.
     *
     * 아직 시작 전이면 시작까지, 시작한 뒤에는 다음 구간 요약까지입니다.
     * 이미 조건을 넘겼다면 0입니다 — 다음 답변 뒤에 만들어집니다.
     */
    val turnsUntilNext: Int
        get() = if (!isActive) {
            ConversationCompactor.THRESHOLD_TURNS - totalTurns
        } else {
            (REFRESH_TRIGGER - verbatimTurns).coerceAtLeast(0)
        }

    companion object {
        /**
         * 원문이 이만큼 쌓여야 다음 요약이 만들어집니다.
         *
         * 흔히 하는 착각이 있어 적어 둡니다. **주기(50턴)마다 만들어지는 것이
         * 아니라, 원문 구간이 창(30턴) + 주기(50턴)를 넘을 때** 만들어집니다.
         * 그래서 요약 하나가 만들어진 직후에는 다음까지 80턴이 아니라 50턴이
         * 남습니다 — 창 30턴은 언제나 원문으로 남아 있기 때문입니다.
         */
        const val REFRESH_TRIGGER =
            ConversationCompactor.VERBATIM_WINDOW_TURNS + ConversationCompactor.REFRESH_PERIOD_TURNS

        fun of(totalTurns: Int, digest: ConversationDigest?): ConversationDigestStatus {
            val segments = digest?.segments.orEmpty()
            return ConversationDigestStatus(
                totalTurns = totalTurns,
                coveredTurns = segments.lastOrNull()?.lastTurn ?: 0,
                segments = segments,
            )
        }
    }
}
