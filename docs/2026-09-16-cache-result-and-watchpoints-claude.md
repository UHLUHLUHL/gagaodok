# 캐시 보존 작업의 실측 결과와 앞으로 볼 시점

기준 커밋: `a1a9c6e` (worktree `~/Desktop/gagaodok-phone-30m-claude`, 브랜치 `claude/phone-30m-diagnostics`)
측정 대상: 폰 `claudeLab` 빌드, 방 `E3D62961`(COMPANION), `gemini-3.8-flash`
작성: 2026-09-16

이 문서는 두 가지를 한다. **앞부분은 지금까지 무엇을 고쳤고 결과가 어땠는지**를
코드 경로와 함께 적고, **뒷부분은 앞으로 무엇을 언제 왜 봐야 하는지**를 적는다.

앞선 기록은 `2026-09-15-cache-preservation-handoff-claude.md`에 있다. 이 문서는 그
뒤로 얻은 실측과, 관찰 계획을 다시 세운 결과다.

---

## 1. 무엇을 고쳤나 — 코드 경로

### 1.1 물림 (`CACHE_LAG_ENTRIES`)

`android/app/src/main/java/com/sapiens/gagaodok/service/AIServicePrefixCache.kt`

```kotlin
internal const val CACHE_LAG_ENTRIES = 2
```

캐시를 만들 때 `contents`의 마지막 두 엔트리를 빼고 올린다. 실제 적용은
`refreshPrefixCache`(같은 파일 `:323`) 안이다.

```kotlin
val lag = prefixCacheLagEntries(entryCount, laggedPrefixTokens, shrinkProne)
val prefix = if (lag > 0) contents.dropLast(lag) else contents
```

저장되는 `PrefixCache.coveredTurns`는 `prefix.size`이고, 지문도 `prefix` 기준이다.
`lagEntries`에 몇 개를 물렸는지 남긴다.

`prefixCacheLagEntries`는 물리면 손해인 세 경우를 막는다.

| 조건 | 이유 |
|---|---|
| `!shrinkProne` | 고쳐 쓴 적 없는 방은 꼬리 값만 더 낸다 |
| `entryCount <= CACHE_LAG_ENTRIES` | 물리면 접두사가 안 남는다 |
| `laggedPrefixTokens < MINIMUM_CACHE_TOKENS`(4,600) | 캐시가 **아예 안 만들어진다** |

### 1.2 방 표시의 디스크 보존

같은 파일의 `readShrinkProneRooms` / `writeShrinkProneRooms` / `markShrinkProne`.
저장 위치는 `AIService.kt`의 `shrinkProneFile`이 정한다.

```
files/KakaoSapiens/shrink_prone_rooms.json
["<roomId>|<model>"]
```

**고치기 전에는 메모리에만 있었다.** 표시는 캐시가 한 번 깨져야 생기는데 프로세스는
하루에도 몇 번 새로 뜬다. 기기 계측에서 저녁~아침 사이 대화 5묶음·재시작 2회 동안
캐시가 끝까지 `lagEntries = 0`이었다. 커밋 `79f0b8c`.

### 1.3 재요청 판정 (`isRerollShrink`)

`AIServicePrefixCache.kt`, `isRerollShrink`. 현재 조건은 이렇다.

```kotlin
if (coveredTurns - newSize < 0) return false
if (cacheDigestCoveredTurns >= 0) return requestDigestCoveredTurns == cacheDigestCoveredTurns
return coveredTurns - newSize <= REROLL_SHRINK_MAX_ENTRIES
```

**이 첫 줄이 `< 1`이었고, 그 때문에 물림이 실사용에서 한 번도 켜지지 않았다.**

원인은 캐시를 찍는 시점이다. `AIServiceConversation.kt:225`가 답변이 아니라
**방금 보낸 요청의 `contents`**를 올린다(주석에도 그렇게 적혀 있다). 그래서
`coveredTurns`는 "사용자 메시지까지"의 길이다.

```
캐시 생성 63  →  답변 저장 64  →  답을 다시 받음 63
```

재요청은 길이를 **줄이는 것이 아니라 되돌린다.** 차이가 1이 아니라 0이다.
`usablePrefixCache`는 `contents.size <= cache.coveredTurns`로 잡으므로 `SHRUNK`까지는
가지만, `isRerollShrink`가 그 앞에서 걸러 `markShrinkProne`에 닿지 못했다.

`ConversationTurn.from`(`android/app/src/main/java/com/sapiens/gagaodok/model/Message.kt:109`)이
AI 응답의 말풍선 여럿을 `turnId`로 한 턴에 묶으므로, 재요청은 **언제나 정확히 1
엔트리**만 지운다. 말풍선이 셋이어도 마찬가지다.

커밋 `a1a9c6e`.

### 1.4 요약 접기와 재요청의 구분

같은 함수의 둘째 줄이다. 크기로 추측하지 않고 **부르는 쪽이 알려 준다.**
`AIServiceConversation.kt`의 두 호출부가 `plan.coveredTurns`를 넘긴다(`:96`, `:225`).

요약이 전진하면 `requestDigestCoveredTurns != cacheDigestCoveredTurns`가 되어 `false`다.
따라서 차이가 0이어도 **정상 압축을 재요청으로 오인하지 않는다.** 커밋 `7a0f9bb`.

### 1.5 회귀 검사

`android/app/src/test/java/com/sapiens/gagaodok/RerollShrinkFlowTest.kt`

`MessageResendLogic.truncateFrom`
(`android/app/src/main/java/com/sapiens/gagaodok/ui/screens/MessageResendLogic.kt`)
→ `ConversationTurn.from` → `isRerollShrink`를 실제 production 함수로 잇는다.

| 경우 | 길이 | 고치기 전 | 고친 뒤 |
|---|---|---|---|
| 일반 재생성 | 63 → 63 | 표시 안 됨 | 표시됨 |
| 같은 문구 재전송 | 63 → 63 | 표시 안 됨 | 표시됨 |
| 일부 수정 | 63 → 63 | 표시 안 됨 | 표시됨 |
| 전면 수정 | 63 → 63 | 표시 안 됨 | 표시됨 |
| 첨부 전용 재전송 | 63 → 63 | 표시 안 됨 | 표시됨 |
| 말풍선 3개짜리 답 재생성 | 63 → 63 | 표시 안 됨 | 표시됨 |
| 과거 메시지 수정 | 63 → 59 | 표시됨 | 표시됨 |

**길이 단언은 전후 동일하다.** 바뀐 것은 판정뿐이다. 고치기 전 이 검사는
`assertFalse`로 7/7 통과했고(결함을 기록한 상태), 조건을 고치자 정확히 여섯이 뒤집혔다.

`buildGeminiContents`는 `AIService` 확장이라 단위 검사에서 못 부른다.
`ConversationTurn.from(...).size`로 대신했다 — **이 한 가지만 근사**이고 나머지는 실제
함수다.

### 1.6 기존 단위 검사가 왜 못 잡았나

`android/app/src/test/java/com/sapiens/gagaodok/PrefixCacheLagTest.kt`

- `같은 흐름에서 답을 다시 받으면 표시된다`가 `coveredTurns=63, newSize=62`를
  **손으로 넣고** 있었다. 그 62가 어디서 오는지는 아무 검사도 하지 않았다.
- `줄지 않았으면 답을 다시 받은 것이 아니다`가 차이 0을 `false`로 **못박아**
  결함을 정답으로 고정하고 있었다.

두 검사를 뒤집고, 요약이 전진한 경우를 따로 고정했다.

### 1.7 요금 계산과 장부

| 무엇 | 파일 | 커밋 |
|---|---|---|
| `costUSD`에서 `cacheCreateTokens` 제거 | `data/TokenUsageStore.kt` | `fbfc2b4` |
| 환율 기본값 1,420 → **1,383** | `data/AppSettings.kt` (`DEFAULT_EXCHANGE_RATE`) | `fbfc2b4` |
| 설정 화면 표기 "(청구 안 됨)" | `ui/screens/SettingsScreen.kt` | `fbfc2b4` |
| `cacheLeaseTokenHours` 도입, `dropCache`도 정산 | `service/AIServicePrefixCache.kt` | `f45e307` |
| `recordCacheLeaseEnd` 인자 4→3개 | `data/TokenUsageStore.kt` | `f45e307` |
| `@JsonNames("finishReasons")` | `data/OptimizationMeasurementStore.kt` | `2088439` |

보관량에는 버그가 **둘** 있었고 서로를 가리고 있었다. `faa7429`가 `× tokenCount`를
빠뜨려 token-hours 자리에 hours를 적었고(약 27,000배 과소), `dropCache` 경로는 아예
정산하지 않았다(캐시 소멸의 85%). 장부가 청구의 65%로 읽혔는데 옛 과대값이 이를
가리고 있었다.

### 1.8 기각한 것 — 씨앗

`generationConfig.seed`는 문서화된 필드이고 400도 나지 않지만 **무동작**이다.
`docs/seed-probe.sh`를 대조군 있는 형태로 다시 만들어 확인했다.

- A(무씨앗) 5회 → 5개 모두 다름
- C(같은 씨앗 77) 2회 → **서로 다름**

`2082eb2`를 `6ddec38`로 되돌리고 `ChatSeedTest.kt`를 지웠다. 근거는
`AIServiceConversation.kt`의 `requestBody` 주석에 남겼다.

---

## 2. 기기 실측 결과

### 2.1 장부에서 읽은 값

`files/KakaoSapiens/optimization_measurements.json`의 `activeRun`(id 9).
계측 게이트는 `AIServiceConversation.kt:161`이다.

```kotlin
val shouldMeasure = !BuildConfig.TABLET_MENTOR && mode == ChatMode.COMPANION
```

`TABLET_MENTOR`는 **플레이버** 플래그라 폰이면 정식·실험판 모두 `true`가 아니다.
즉 정식 앱도 기록한다. 다만 정식 빌드는 `run-as`가 막혀 파일을 밖에서 못 꺼낸다 —
설정 화면의 공유 기능으로만 얻을 수 있다.

| 항목 | 09-15 15:11 | 09-16 (690턴) | 차이 |
|---|---:|---:|---:|
| CHAT 요청 | 423 | 467 | **+44** |
| 캐시 적중 | 368 | 407 | +39 |
| 입력 토큰 | 12,244,511 | 13,326,047 | +1,081,536 |
| 캐시 읽기 토큰 | 10,110,538 | 11,014,185 | +903,647 |
| 출력 토큰 | 150,146 | 162,228 | +12,082 |
| MEMORY 요청 | 3 | 4 | **+1** |

`CacheCreateReason` 분포:

| 사유 | 전 | 후 | 차이 |
|---|---:|---:|---:|
| `FIRST` | 10 | 11 | +1 |
| `EXPIRED` | 15 | 17 | +2 |
| **`SHRUNK`** | **40** | **41** | **+1** |
| `EXPIRING_SOON` | 6 | 7 | +1 |
| `TAIL_GREW` | 5 | 5 | 0 |

`CacheDecision` 분포:

| 판정 | 전 | 후 | 차이 |
|---|---:|---:|---:|
| `NOT_BURST` | 39 | 42 | +3 |
| `CREATE_SUCCESS` | 76 | 81 | +5 |
| `TAIL_TOO_SMALL` | 300 | 316 | +16 |
| **`CACHE_CURRENT`** | **4** | **24** | **+20** |

### 2.2 읽는 법

**`SHRUNK`이 44요청에서 1번뿐이고, 그 1번은 680턴 압축이다.**

압축이 돌면 요약이 원문을 접어 `contents`가 크게 줄고, `usablePrefixCache`의
`contents.size <= coveredTurns`에 걸린다. 정상이다. 같은 요청에서
`isRerollShrink`는 요약 전진을 보고 `false`를 돌려주므로 **잘못된 표시가 생기지
않는다.** 표시 파일은 이미 어제 만들어진 항목 하나뿐이다.

따라서 **재요청 때문에 깨진 캐시는 0건**이다.

**`CACHE_CURRENT` +20이 물림이 일한 직접 증거다.** 이 판정은
`refreshPrefixCache`의 이 조건에서 나온다.

```kotlin
if (previous.coveredTurns + previous.lagEntries >= contents.size &&
    previous.expiresAtMillis > now + 60_000) { observe(CACHE_CURRENT); return }
```

물린 2엔트리 덕에 재요청으로 길이가 돌아와도 캐시가 그대로 유효하다. 이전에는
423요청에서 4번뿐이었는데 **44요청에서 20번** 나왔다.

### 2.3 680턴 압축 (관찰 시점 ②)

압축 상수는 `service/ConversationCompactor.kt`에 있다.

```kotlin
const val THRESHOLD_TURNS = 80          // :55
const val VERBATIM_WINDOW_TURNS = 30    // :59
const val REFRESH_PERIOD_TURNS = 50     // :63
private const val REFRESH_TRIGGER_TURNS = VERBATIM_WINDOW_TURNS + REFRESH_PERIOD_TURNS  // :72
```

턴은 **사용자 발화 기준**이다(`:257`이 `sender == USER`만 센다). 화면 숫자와 같은
단위다. 압축은 `총 턴 − 요약된 턴 ≥ 80`일 때 걸린다.

| 확인 | 결과 |
|---|---|
| 요약 범위 | **600 → 650** 정확히 한 주기 전진 |
| `room_*_digest.json`의 구간 | …`lastTurn:550` / `600` / **`650`** |
| 기억 생성 | **4/4 성공**(`outcomeCounts: {COMMITTED: 4}`) |
| 새 캐시의 `digestCoveredTurns` | **650** — 옛 요약 캐시를 재사용하지 않음 |
| `lagEntries` | **2 유지** — 압축을 재요청으로 오인하지 않음 |
| 캐시 크기 | 33,738 → **22,930** 토큰 (−32%) |

현재 `files/KakaoSapiens/prefix_caches.json`:

```json
{"coveredTurns":77,"tokenCount":22930,"lagEntries":2,"digestCoveredTurns":650}
```

### 2.4 비용

사용자가 보고한 실제 차감은 **379원**이다. 토큰으로 계산하면 370.6원이고, 차이
약 8원이 보관료로 보인다.

| 항목 | 토큰 | 원 | 비중 |
|---|---:|---:|---:|
| **캐시 안 된 입력** | 177,889 | **184.5** | 49.8% |
| 캐시 읽기 | 903,647 | 93.7 | 25.3% |
| 출력 | 12,082 | 62.7 | 16.9% |
| 기억 요약 1회 | 24,667 + 790 | 29.7 | 8.0% |
| 합계 | | **370.6** | |

단가는 청구서에서 확인한 값이다. 입력 $0.75/M, 캐시 읽기 $0.075/M, 출력 $3.75/M,
보관 $0.50/M·시간, 환율 1,383.

| | 661턴 때 | 이번 |
|---|---:|---:|
| 메시지당 | 32.56원 | **22.3원** (−31%) |
| 요청당 | 약 15원 | **8.6원** (−43%) |
| 메시지당 요청 수 | 2.17 | 2.6 |

**재요청을 더 했는데도 메시지당 값이 내려갔다.** 횟수가 줄어서가 아니라 재요청 한
번의 값이 달라졌기 때문이다.

### 2.5 통계적 강도

이전 `SHRUNK` 39회 중 4회는 압축 탓이다(run 9에서 `coverageAdvanced`가 200 = 압축
4회). 재요청 탓은 **35 / 416 = 8.4%**다.

그 비율이 유지됐다면 44요청에서 0회가 나올 확률은 `(1 − 0.084)^44 ≈ 2.1%`다.
**표본이 작지만 우연으로 설명하기는 이미 어렵다.**

---

## 3. 앞으로 볼 시점

### ① 약 730턴 / 누적 150요청 — 재요청 건을 닫는다

**언제**: 현재 690턴. 메시지당 2.6요청 페이스면 40턴쯤 더 쓰면 약 150요청이 된다.

**왜 이 시점인가**: 8.4%가 유지됐다면 150요청에서 0회일 확률은 약 `0.916^150`,
즉 **0.0002%**다. 그 아래로는 더 봐도 얻는 게 없다. 지금(44요청, 2.1%)은
"거의 확실"이고 150요청이면 "확실"이 된다.

**볼 것**

| 확인 | 어디서 | 기대 |
|---|---|---|
| 재요청 탓 `SHRUNK` | `optimization_measurements.json`의 `createReasons.SHRUNK` 증가분에서 압축 횟수를 뺀 값 | **0** |
| 730턴 압축 | 같은 파일 `memory.lastCommittedCoverage` | 650 → **700** |
| `lagEntries` | `prefix_caches.json` | **2 유지** |
| `CACHE_CURRENT` 증가 | `decisionCounts` | 계속 늘어야 함 |

**주의**: `SHRUNK` 증가분에는 압축이 섞인다. `CacheDropReason`만으로는 갈라지지
않으므로(둘 다 `SHRUNK`) `memory.lastCommittedCoverage` 변화로 압축 횟수를 세서
빼야 한다. **이 구분이 계측에 없다는 것이 현재 한계다.**

### ② 9월 말 ~ 10월 초 — 청구서 대조

**언제**: 턴이 아니라 **달력**에 달렸다. Google Cloud 결제 보고서가 나오는 시점.

**왜 이것이 최종 확인인가**: 이번 작업에서 우리 장부가 세 번 틀렸다. 보관량은
청구의 65%밖에 세지 않았고, 화면 금액은 68% 부풀어 있었다. **장부가 맞다는 증거는
청구서뿐이다.**

**맞출 조건** — 총액만 보면 안 된다.

- 같은 모델, 같은 SKU
- **새 장부 run 시작 이후만.** 기존 보관 token-hours에는 단위 오류가 섞여 있다
- 사용자 턴 수와 재요청 수를 함께 기록
- 사용자 1턴당 / 재요청 1건당 **비캐시 입력** 비용
- 보관 token-hours를 장부와 **수량**으로 대조
- 채팅 · 기억 요약 · 출력을 분리
- 환율 효과와 실제 토큰 감소를 분리

**판정**: 추정은 월 약 5,100원 절감인데, 이는 물림이 켜지지 않은 상태의 `SHRUNK`
횟수로 뽑은 값이다. **실측으로 갈아 끼워야 한다.**

### ③ 미적중 정책 — 청구서 확인 뒤

**왜 다음 과제인가**: 고친 뒤에도 **비용의 절반(49.8%)이 캐시 안 된 입력**이고,
그 대부분은 재요청이 아니라 **미적중 5건**에서 나왔다.

| 사유 | 이번 44요청 | 코드 근거 |
|---|---:|---|
| `NOT_BURST` | +3 | `CACHE_BURST_WINDOW_MILLIS = 300_000L` — 캐시가 없을 때 직전 요청이 5분 밖이면 안 만든다 |
| `EXPIRED` | +2 | `CACHE_TTL_SECONDS = 1800` — 읽어도 연장되지 않는다 |

**판단이 필요한 것**

- 5분(`CACHE_BURST_WINDOW_MILLIS`)은 **근거 없이 정한 값**이다. 코드 주석에도
  "정한 값입니다. 실제 사용 기록을 보고 뽑은 값이 아닙니다"라고 적혀 있다.
- 캐시가 **없을 때만** 이 검사를 한다. 만료 임박(`CACHE_REFRESH_TTL_FLOOR_MILLIS`,
  4분) 갱신에는 같은 검사가 없다. **두 경우 다 미래를 거는 것인데 앞쪽만 엄격하다.**

**미측정**: `EXPIRING_SOON`으로 만든 캐시가 실제로 읽혔는지 알 수 없다. 캐시별 읽힌
횟수를 세지 않기 때문이다(`OptimizationMeasurementStore.observeCache`는 판정 개수만
센다). **최악값은 계산 가능하다** — 6개 전부 안 읽혔다고 해도 평균 27,644토큰 ×
0.5시간 × 6 = 82,932 token-hours ≈ **57원**. run 전체(약 13일) 기준이라 고칠 값어치가
없다.

### ④ `boundary:` 포화 — 느리게, 사건 기준으로

`service/ThreeLayerMemory.kt`

```kotlin
internal const val LOOP_RULE_LIMIT = 10   // :31
const val STATE_TOKEN_BUDGET = 3000       // :96
```

상한을 넘으면 `setAtTurn`이 오래된 `loop:`부터 버리고 `boundary:*`는 보호한다.
**`boundary`가 계속 늘면 결국 상한에 닿는다.**

현재 `droppedLoopRules`는 0이다. 급하지 않지만, 이것이 코덱스가 제안한
**M3/M4 분리**의 실질적 근거다. 정기 점검이 아니라 `droppedLoopRules`가 0이 아니게
되는 때가 신호다.

### ⑤ M2 성장 — 약 2,500~3,200턴 (3~5개월 뒤)

요약 밀도는 실측 **약 10.5토큰 / 원문 턴**이다. 현재 M1 평균이 26,572토큰이므로
M2가 M1을 넘어서는 지점이 이쯤이다. 월 600턴 페이스면 3~5개월 뒤다.

**지금 볼 것은 없다.** 다만 그 전에 계측을 갈라 둬야 한다(아래).

---

## 4. 계측이 없어서 못 보는 것

**턴을 더 쌓아도 답이 안 나오는 것들이다. 코드가 필요하다.**

| 못 보는 것 | 왜 | 어디를 고쳐야 하나 |
|---|---|---|
| M2와 M3 각각의 토큰 | `digestTokens` 하나에 합쳐져 있다 | `PromptTokenBreakdown` (`data/OptimizationMeasurementStore.kt`), 채우는 곳은 `AIServiceConversation.kt:83` 부근 |
| 압축 탓 `SHRUNK`과 재요청 탓 `SHRUNK` | 둘 다 같은 `CacheDropReason` | `CacheDropReason`에 구분을 넣거나, 압축 전환 요청을 표시 |
| `EXPIRING_SOON` 캐시가 읽혔는지 | 캐시별 읽힌 횟수를 안 센다 | `PrefixCache`에 읽기 횟수, `dropCache`에서 생성 사유와 함께 기록 |
| 검색(M5) 때문에 생긴 캐시 무효화 | 아직 기능이 없다 | 코덱스 5계층 Phase 1의 선결 조건 |

첫 줄이 가장 중요하다. **계층별 토큰 예산을 설계하려면 계층을 구분해 잴 수 있어야
한다.** 코덱스의 5계층 보고서도 Phase 1에서 이것을 첫 단계로 잡았다.

---

## 5. 지금 상태 요약

| 관찰 시점 | 상태 |
|---|---|
| ① 재요청 판정·영속화 | **통과** (09-15 15:06, `shrink_prone_rooms.json` 생성 + `lagEntries=2`) |
| ② 680턴 압축 | **통과** (09-16, 요약 600→650, 기억 4/4, `lagEntries` 유지) |
| ③ ~730턴 효과 측정 | 진행 중 — 44요청에서 재요청 탓 `SHRUNK` 0건 |
| ④ 청구서 대조 | 대기 — 9월 말 |
| ⑤ 미적중 정책 | 미착수 — ④ 이후 |

검사: `testPhoneClaudeLabUnitTest` **475개 통과**, `compileTabletMentorDebugKotlin` 성공.

설치: `claudeLab` 09-16 14:34, `release` 09-16 16:05(양쪽 데이터 보존, 크래시 0).
`release`는 동기화 시험 UI가 아직 들어 있다 — 동기화 작업이 끝난 뒤 정리한다.

---

## 6. 이 작업에서 남길 것

- **빌드 성공은 동작 확인이 아니다.** 물림은 단위 검사를 전부 통과한 채로 실사용에서
  한 번도 켜지지 않았다. 기기에서 `prefix_caches.json`을 열어 보고서야 알았다.
- **손으로 넣은 숫자를 검사하는 테스트는 그 숫자가 맞는지 검사하지 않는다.**
  `63 → 62`가 어디서 오는지 아무도 묻지 않았고, 그 사이 결함이 정답으로 굳었다.
- **금액이 아니라 개수로 판정하라.** 필터·환율·반올림의 영향을 안 받는다. 가장 오래
  막혀 있던 "캐시 생성이 청구되는가"는 입력 토큰 **수량** 대조 한 번으로 닫혔다.
- **두 오류가 상쇄되면 맞아 보인다.** 첫 월 추정치는 생성료를 포함하고(과대) 다른
  방을 빠뜨려(과소) 우연히 그럴듯했다. 그렇게 맞은 숫자가 가장 위험하다.
- **절감과 정정을 섞어 보고하지 마라.** 화면 금액이 68% 내려간 것은 돈을 아낀 것이
  아니라 계산을 고친 것이다. 실제 절감은 메시지당 32.56 → 22.3원이다.
