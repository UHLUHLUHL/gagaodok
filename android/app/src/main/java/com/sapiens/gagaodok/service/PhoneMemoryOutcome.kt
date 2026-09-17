package com.sapiens.gagaodok.service

import kotlinx.serialization.Serializable

/// 기억 갱신 한 번이 어떻게 끝났는지입니다.
///
/// **모든 종료 경로에 이름을 붙입니다.** 예전에는 일곱 갈래 중 다섯이 로그 없이
/// 그냥 `return`했고, 그중 셋은 **유료 요청을 보낸 뒤**였습니다. 그래서 돈을 쓰고
/// 실패해도 화면에도 로그에도 아무것도 남지 않았습니다.
///
/// 그 상태에서는 요약 범위가 멈춘 채 재시도가 되풀이돼도 알 방법이 없습니다.
/// `logcat`에 오류가 안 보인다고 정상이라고 판정할 수 없다는 뜻이기도 합니다.
///
/// 실사용 내보내기에서 최신 구간의 최근 원문이 추정 입력의 87.68%였고 요약 기억은
/// 3.11%였습니다. 원문이 큰 것이 **기억 갱신이 진전되지 않은 결과일 수 있다**는
/// 것이 이 계측을 넣는 이유입니다. 아직 확정된 원인이 아니라 조사 가설입니다.
@Serializable
enum class PhoneMemoryOutcome(
    /// 유료 요청을 보낸 뒤에 끝났는지입니다. **반복 비용의 원인은 이것뿐입니다.**
    val paid: Boolean,
    /// 요약 범위(coverage)를 실제로 진전시켰는지입니다.
    val advancesCoverage: Boolean = false
) {
    /// 재시도 대기 중이라 아무것도 하지 않았습니다.
    BACKOFF_SKIPPED(paid = false),

    /// 같은 방의 갱신이 이미 돌고 있습니다.
    ALREADY_RUNNING(paid = false),

    /// 요약할 구간이 없습니다.
    NO_PENDING(paid = false),

    /// 원문 턴 수가 기대와 달라 입력을 만들 수 없습니다.
    /// 삭제·재전송으로 대화가 짧아졌을 때 나옵니다.
    SOURCE_TURN_MISMATCH(paid = false),

    /// 응답에 후보가 없습니다.
    NO_CANDIDATE(paid = true),

    /// 종료 사유가 `STOP`이 아닙니다. 대개 출력 한도에 먼저 걸린 것입니다.
    NOT_STOP(paid = true),

    /// 전환 결과가 기존 요약보다 커서 저장하지 않았습니다.
    ///
    /// **입력이 그대로면 다음 시도도 같은 결과입니다.** v2 렌더는 v0 렌더에 M3
    /// 블록(250~800토큰)을 더한 형태인데 머리말 차이는 수십 자뿐이라, 모델이 기존
    /// 구간을 M3 몫만큼 압축해내지 못하면 이 조건은 구조적으로 실패합니다.
    /// 반복 비용의 가장 유력한 후보입니다.
    MIGRATION_NOT_SMALLER(paid = true),

    /// 저장 직전 검사(원문 hash, revision)에서 거부되었습니다.
    COMMIT_REJECTED(paid = true),

    /// 응답이 JSON으로 읽히지 않았습니다.
    ///
    /// **출력이 잘렸을 때 가장 먼저 나타나는 증상입니다.** 다만 지시문을 안 지킨
    /// 응답도 여기로 오므로, `failureDetail`을 함께 봐야 어느 쪽인지 갈립니다.
    PARSE_FAILED(paid = true),

    /// 요청한 구간과 다른 범위를 돌려주었습니다. 지시문을 안 지킨 것입니다.
    RANGE_MISMATCH(paid = true),

    /// 요약 한 구간이 분량 상한을 넘었거나 비었습니다.
    SEGMENT_TOO_LONG(paid = true),

    /// M3 상태 갱신이 검증에서 거부되었습니다.
    ///
    /// 허용되지 않은 key, 원문 밖의 근거 ID, 중복 연산, 상태 총량 초과가 여기 옵니다.
    /// 예산과 무관한 실패이므로 예산을 늘려도 줄지 않습니다.
    STATE_REJECTED(paid = true),

    /// 위 어디에도 안 드는 예외입니다. 남아 있으면 새 갈래를 만들어야 한다는 뜻입니다.
    EXCEPTION(paid = true),

    /// 저장에 성공했습니다.
    COMMITTED(paid = true, advancesCoverage = true)
}

/// 기억 갱신 한 번에 줄 출력 예산입니다.
///
/// 본문 몫은 지시문이 요구하는 최대치에서 나옵니다 — M2 구간당 1,500, M3 합계 800,
/// JSON 구조 약 200. 사고 몫은 `outputBudget`이 붙입니다.
internal fun phoneMemoryOutputBudget(segmentCount: Int): Int =
    outputBudget(segmentCount * ConversationCompactor.SEGMENT_TOKEN_BUDGET + 1000)

/// 실패한 뒤 다음 시도까지 기다리는 기본 시간입니다.
internal const val PHONE_MEMORY_RETRY_MILLIS = 15 * 60_000L

/// 연속 실패가 이어질 때의 대기 시간입니다.
///
/// **15분 고정은 위험합니다.** 실패해도 요약 범위가 안 늘어나므로 `pending`이 계속
/// 남고, 매 요청이 갱신을 다시 걸어 15분마다 유료 호출이 나갑니다. 원인이 입력에
/// 있다면(예: 전환 결과가 구조적으로 더 큰 경우) 며칠이고 같은 실패를 되풀이합니다.
/// 하루면 최대 96번입니다.
///
/// 상한을 6시간으로 둡니다. 영원히 멈추면 원인을 고친 뒤에도 돌아오지 않습니다.
/// 15분 · 30분 · 1시간 · 2시간 · 4시간 · 6시간(상한) 순으로 늘어납니다.
/// `shl` 폭을 5까지 두는 이유는 그래야 마지막 단계(8시간)가 상한에 걸려 6시간이
/// 되기 때문입니다. 4까지만 두면 상한이 아예 걸리지 않고 4시간에서 멈춥니다.
internal fun phoneMemoryBackoffMillis(consecutiveFailures: Int): Long {
    val steps = (consecutiveFailures - 1).coerceIn(0, 5)
    return (PHONE_MEMORY_RETRY_MILLIS shl steps).coerceAtMost(6 * 60 * 60_000L)
}

/// 기억 갱신 한 번의 관측값입니다.
///
/// **대화 내용도 방 이름도 담지 않습니다.** 전부 집계용 수치와 분류입니다.
data class PhoneMemoryObservation(
    val outcome: PhoneMemoryOutcome,
    /// 기존 요약을 v2로 옮기는 전환이었는지입니다. 일반 갱신과 실패 양상이 다릅니다.
    val migration: Boolean,
    /// 시도 전의 요약 범위입니다.
    val coverageBefore: Int,
    /// 시도 후의 요약 범위입니다. 실패하면 `coverageBefore`와 같습니다.
    val coverageAfter: Int,
    /// 이번 시도가 목표로 한 구간의 끝입니다. 정하기 전에 끝났으면 0입니다.
    val targetThrough: Int,
    /// 이번 시도가 다룬 구간 수입니다. 전환이면 여러 개일 수 있습니다.
    val segmentCount: Int,
    /// 실패 뒤 다음 시도까지의 대기 시간입니다. 성공이나 무료 건너뜀이면 0입니다.
    val retryAfterMillis: Long,
    /// 실패를 한 단계 더 좁히는 단서입니다. 실패했을 때만 채웁니다.
    ///
    /// 두 곳에서 옵니다. 모델이 알려준 종료 사유(`MAX_TOKENS`, `SAFETY` 등)와,
    /// 우리 검증이 거부한 이유(`State too large`, `Evidence outside source` 등)입니다.
    /// `outcome`이 어느 쪽인지 이미 말해주므로 한 칸에 담아도 헷갈리지 않습니다.
    ///
    /// **이것이 없으면 갈래 이름만으로는 고칠 곳을 못 정합니다.** 출력 한도와 안전
    /// 필터는 처방이 정반대이고, 상태 초과와 근거 오류도 마찬가지입니다.
    /// 성공한 건에까지 남기면 집계가 뒤덮이므로 실패했을 때만 남깁니다.
    ///
    /// **수치를 담지 않습니다.** 집계에서 키로 쓰이므로 값이 섞이면 같은 원인이
    /// 여러 칸으로 흩어집니다.
    val failureDetail: String? = null,
    /// 자리를 만들려고 놓아준 반복 패턴의 수입니다.
    ///
    /// **0이 아니면 기억이 그만큼 흐려졌다는 뜻입니다.** 원문과 M2 요약에는 남아
    /// 있지만 규칙으로 튀어나오지는 않습니다. 이 값이 쌓이는 속도를 보고
    /// `LOOP_RULE_LIMIT`과 `STATE_TOKEN_BUDGET`을 조정합니다.
    val droppedLoops: Int = 0,
    /// 기억 호출을 받은 모델의 식별자입니다. 모델별 장부를 가르는 데 씁니다.
    /// **기본값을 두지 않습니다** — 빠뜨리면 Gemini와 DeepSeek의 실패율이 섞입니다.
    val model: String
)
