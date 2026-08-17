# 안드로이드에서 고친 것 중 맥 판에 옮길 것

맥 판이 먼저 만들어졌지만, 안드로이드를 만들면서 고친 것들이 맥으로 돌아오지 않았습니다.
이 문서는 **무엇이 갈라졌고, 그중 무엇을 옮겨야 하며, 무엇은 옮기지 않아도 되는지**를 정리한 것입니다.

## 갈라진 지점

`Sources/`를 마지막으로 건드린 커밋은 `8a6880e`입니다. 그 뒤 7개 커밋은 전부 `android/`만 바꿨습니다.

```
2c87068  Give companion rooms their own digest, and stop paying for caches nobody reads
af4a93c  Size photos to the tile grid and think less in companion mode
6c97a14  Add a profile screen and stop the token ledger from under-counting
b28e2b3  Match the long-press menu and message editing to KakaoTalk
addf3e7  Fix components that clash with their neighbours
ac4c61e  Match the Android UI to measured KakaoTalk screenshots
4f288dc  Add the Android build of the app
──────── 여기까지가 안드로이드 전용 ────────
8a6880e  Relax Gemini response filtering in companion mode   ← 맥 판은 여기서 멈춰 있습니다
```

`TokenEstimator`, `StreamingBubbleBuffer`, `RoleplayParser`, `MathExpression`은 양쪽이 아직 같습니다.
갈라진 것은 **요금·장부·기억·화면** 네 갈래입니다.

아래 항목은 모두 실제 소스를 읽고 확인한 것입니다.

## 진행 상황

**전부 반영했습니다.** 각 항목 제목 옆에 무엇으로 확인했는지 적었습니다.

| | 항목 | 확인 |
|---|---|---|
| A-1 | 캐시 매 턴 재생성 | 코드 |
| A-2 | 안 읽을 캐시 생성 | 코드 |
| A-3 | 안 쓰는 캐시 보관료 | 코드 |
| A-4 | 사진 원본 크기 | **실측** — 아래 참고 |
| A-5 | 소용없는 재시도 | 코드 |
| A-6 | 챗봇도 medium 사고 | 코드 |
| A-7 | 요청 본문이 두 벌 *(작업 중 발견)* | 코드 |
| B-1 | 대화 외 요청 누락 | 코드 |
| B-2 | 캐시 생성 토큰 누락 | 코드 |
| B-3 | 중도 취소분 누락 | 코드 |
| C-1 | 챗봇 방을 과외로 요약 | 코드 |
| D-1 | 다크 모드 입력창 | **실측 + 실제 화면** |
| D-2 | 말투 조사 진행 표시 | **실제 화면** |
| D-3 | 미리보기 3건 동시 발사 | **실제 화면** |
| D-4 | 미리보기에 안전 설정 누락 *(작업 중 발견)* | 코드 |
| E-1 | OpenAI `store: true` | **미결정 — 사용자 판단 필요** |

"코드"는 소스를 고치고 디버그·릴리스 빌드가 모두 통과한 것까지입니다.
요금 항목은 **실제 청구액으로 확인해야 끝납니다.**

커밋은 **같이 컴파일되는 단위로** 나눴습니다. 항목별로 더 잘게 쪼개려 했지만
A·B·C가 `GeminiService.swift`의 같은 함수들을 함께 건드려서, 억지로 나누면
중간 커밋이 빌드되지 않습니다. 빌드 안 되는 커밋을 남기는 것보다 낫다고 봤습니다.

- 장부·캐시·요약·사고량·재시도 (A-1·2·3·5·6·7, B-1·2·3, C-1, D-2·3·4)
- 사진 (A-4)
- 다크 모드 입력창 (D-1)
- 이 문서

---

## A. 돈이 새는 곳

요금 순으로 놓았습니다. A-1이 가장 크고, A-1만 고쳐도 대부분이 잡힙니다.

### A-1. 캐시를 매 턴 통째로 다시 만듭니다 ★가장 큼

**지금 맥 판** — `GeminiService.swift:762`

```swift
if let roomId {
    Task { await self.refreshPrefixCache(roomId: roomId, contents: contents, system: system, apiKey: apiKey) }
}
```

답변을 받을 때마다 조건 없이 부릅니다. `refreshPrefixCache`(:923) 안의 유일한 방어는
"이미 같은 구간을 덮는 캐시가 있으면 돌아간다"(:930-935)인데, 새 턴이 붙은 뒤라 이 조건은 **항상 거짓**입니다.

그래서 매 턴마다:

1. 대화 접두사 **전체**를 `cachedContents`로 새로 올리고 (:951-956)
2. 직전 캐시를 지웁니다 (:990)

100턴짜리 방이라면 5만 토큰쯤을 **한 턴 아끼자고 매 턴 다시 올리는** 셈입니다.
캐시를 안 만들고 넘어갔을 때 더 내는 값은 **새로 붙은 꼬리만큼**뿐인데도요.

**안드로이드가 고친 방식** — `AIService.kt:474-493`

꼬리가 캐시의 5분의 1보다 커졌을 때만 새로 만듭니다. 그 아래에서는 만드는 값이 아끼는 값보다 큽니다.

```kotlin
val tail = estimateTokens(contents.drop(previous.coveredTurns))
val worthIt = tail >= maxOf(CACHE_REFRESH_MIN_TAIL_TOKENS, previous.tokenCount / 5)
val expiringSoon = previous.expiresAtMillis <= now + CACHE_REFRESH_TTL_FLOOR_MILLIS
if (!worthIt && !expiringSoon) return
```

- `CACHE_REFRESH_MIN_TAIL_TOKENS = 2000` — 짧은 대화에서 몇 마디 붙었다고 다시 만들지 않게 하는 바닥값
- `CACHE_REFRESH_TTL_FLOOR_MILLIS = 240_000` — TTL이 4분도 안 남았으면 꼬리가 짧아도 새로 만듭니다.
  그대로 두면 곧 만료되어 다음 요청이 통째로 전액이 됩니다.

이걸 하려면 `PrefixCache`에 `tokenCount`가 있어야 합니다(안드로이드는 `AIService.kt:99`).
맥 판 `PrefixCache`(:553-558)에는 없으니 필드를 추가하고, **옛 파일에도 기본값이 들어가도록**
`Codable`의 `decodeIfPresent`로 읽어야 합니다.

**확인 방법** — 한 방에서 메시지를 5번 연속 보내고, 사용량 화면의 요청 수가 몇 개 늘었는지 봅니다.
고치기 전에는 10건(대화 5 + 캐시 생성 5)이 나갔고 그중 5건이 장부에 아예 안 잡혔습니다(B-2 참고).
고친 뒤에는 캐시 생성이 꼬리가 쌓였을 때만 일어나고, 일어날 때는 요청 수에 잡힙니다.

### A-2. 아무도 안 읽을 캐시를 만듭니다

**지금 맥 판** — 캐시가 아예 없는 방에서도, 한 마디 던지면 그 뒤에 대화 전체를 캐시로 올립니다.
사용자가 바로 앱을 닫으면 그 캐시는 **한 번도 안 읽히고 TTL(15분) 내내 보관료만 먹습니다.**
올리는 값까지 치면 그 한 마디의 요금을 두 배로 낸 셈입니다.

메신저는 몰아서 쓰고 한참 쉽니다. 이 패턴에서 특히 손해입니다.

**안드로이드가 고친 방식** — `AIService.kt:456-472`

직전 요청이 5분 안이면 "대화 중"으로 보고, 그때만 첫 캐시를 만듭니다.
대신 한 묶음의 두 번째 메시지까지는 캐시 없이 갑니다 — 안 쓸 캐시를 만드는 것보다 낫습니다.

```kotlin
if (previous == null) {
    val ongoing = previousRequestAt != null &&
        now - previousRequestAt <= CACHE_BURST_WINDOW_MILLIS
    if (!ongoing) return
}
```

방마다 직전 요청 시각을 메모리에 들고 있다가, **읽기 전에** 꺼내 갱신합니다(`markRequest`, :427).
읽고 나서 갱신하면 항상 자기 자신을 보게 되어 조건이 무의미해집니다.

> `CACHE_BURST_WINDOW_MILLIS = 5분`은 **정한 값입니다.** 실제 사용 기록에서 뽑은 값이 아닙니다.
> 맥은 쓰는 리듬이 다를 수 있으니(창을 띄워 두고 오래 쓰는 편) 그대로 옮기기 전에 한번 재 보는 편이 좋습니다.

### A-3. 안 쓰는 캐시의 보관료를 계속 냅니다

**지금 맥 판** — `GeminiService.swift:908-921`

```swift
guard contents.count > cache.coveredTurns else { return nil }        // :915
guard fingerprint(...) == cache.fingerprint else {
    prefixCaches[roomId] = nil                                        // :917 — 로컬만 지웁니다
    return nil
}
```

두 가지 문제가 겹쳐 있습니다.

**첫째, :915는 아무것도 지우지 않고 `nil`만 돌려줍니다.**
메시지를 하나 고치거나 지워서 대화가 짧아지면 이 조건에 걸립니다. 그러면 캐시를 안 쓰는데,
갱신하는 쪽은 "이미 더 많이 덮는 캐시가 있다"(:931)며 그냥 돌아갑니다.
결과적으로 그 방은 대화가 예전 길이를 되찾거나 TTL이 다할 때까지 **캐시 없이 전액을 내면서
쓰지도 않는 캐시의 보관료는 계속 냅니다.**

맥 판은 메시지 수정이 있는 앱입니다(`SingleChatRoomView.swift:365`). 실제로 밟히는 경로입니다.

**둘째, :917과 :730은 서버 쪽 캐시를 안 지웁니다.**
로컬 기록만 비우므로 서버의 캐시는 TTL이 다할 때까지 남아 보관료를 먹습니다.

:730은 **캐시가 만료돼 캐시 없이 다시 보내는 자리**입니다. 그 자리야말로 캐시가
못 쓰게 됐다는 것이 확실한 곳인데, 거기서도 로컬만 지웠습니다. 고치면서 이 자리도
서버 삭제를 걸었습니다.

**안드로이드가 고친 방식** — `AIService.kt:396-416`

지울 것이면 서버 쪽도 함께 지웁니다. 만료된 것은 서버에도 없으므로 로컬만 지웁니다.

```kotlin
if (contents.size <= cache.coveredTurns) {
    dropCache(key, deleteRemote = true, apiKey = apiKey)   // 버리고 다시 만듭니다
    return null
}
if (fingerprint(contents.take(cache.coveredTurns), system) != cache.fingerprint) {
    dropCache(key, deleteRemote = true, apiKey = apiKey)
    return null
}
```

### A-4. 사진을 원본 크기 그대로 보냅니다

**지금 맥 판** — `Message.swift:106`

`imageAttachment(data:contentType:)`는 받은 데이터를 **그대로** base64로 만듭니다.
붙여넣기(:77)든 파일 열기(:52)든 축소가 한 군데도 없습니다.

**요금은 화소 수가 아니라 타일 수에 비례합니다.** Gemini는 사진을 768×768 타일로 잘라 읽고
타일 하나가 258토큰입니다. 레티나 맥에서 찍은 스크린샷 한 장(3024×1964)이면
`ceil(3024/768) × ceil(1964/768) = 4 × 3 = 12타일 = 3,096토큰`입니다.

그리고 **사진은 대화에 남아 있는 한 요청마다 다시 실립니다.** 한 번이 아니라 그 사진이
대화창에 있는 내내 매 턴 3,096토큰입니다. 맥은 스크린샷을 붙여넣기 가장 쉬운 환경이라
안드로이드보다 이 문제가 큽니다.

**안드로이드가 고친 방식** — `service/ImageBudget.kt` (전체 100줄, 그대로 옮길 만합니다)

타일 격자를 먼저 고르고 거기 꽉 차게 줄입니다. 화소를 조금 줄이는 것은 대개 한 푼도 못 줄이고,
**타일 하나를 없앨 때만 258토큰이 통째로 빠집니다.**

같은 4:3 사진이 2×1 격자의 1024×768이 되어 2타일 = 516토큰입니다. 3분의 1 값입니다.

```kotlin
fun plan(width: Int, height: Int): Plan   // 격자 열거 → 긴 변 ≥ 900 → 타일 최소, 동률이면 면적 큰 쪽
```

옮기면서 정한 것:

- `Sources/KakaoSapiens/Services/ImageBudget.swift`로 옮겼고, `shrink(_:)`가
  `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceThumbnailMaxPixelSize`로
  **디코드하면서** 줄입니다. 안드로이드의 `inSampleSize`와 같은 일입니다.
- 붙여넣기(`Message.swift:106`)와 파일 열기(`:52`) 양쪽에 걸었습니다.
- 줄인 결과가 원본보다 크면 원본을 씁니다. 아주 작은 png에서 그럴 수 있습니다.
- **이미 저장된 사진은 그대로 남습니다.** 앞으로 올리는 것만 달라집니다.

**실측 (2026-08-17)** — 실제 화소로 돌려 확인했습니다.

| 원본 | 결과 | 타일 | 토큰 |
|---|---|---|---|
| 4032×3024 (폰 사진) | 1024×768 | 6 → 2 | 1,548 → 516 |
| 3024×1964 (레티나 캡처) | 1182×768 | 12 → 2 | 3,096 → 516 |
| 2000×2000 | 1536×1536 | 9 → 4 | 2,322 → 1,032 |
| 640×480 | 그대로 | 1 | 258 |

`shrink()`도 실제 JPEG로 돌려 2,957KB / 48타일 → 270KB / 2타일을 확인했고,
계획한 타일 수와 줄인 뒤 실제 타일 수가 일치했습니다.

**남은 위험 (아직 확인 못 함)** — `MIN_LONG_SIDE = 900`은 **정한 값입니다.**
안드로이드에서 문제지 **세로** 사진을 기준으로 잡은 값인데, 맥에 붙여넣는 것은 대개
**가로로 긴 화면 캡처**입니다. 위 표에서 3024×1964가 세로 768까지 줄어드는데,
레티나 캡처라면 화면에서 보던 크기의 0.78배쯤입니다. 작은 글씨가 뭉갤 수 있습니다.

실제로 안 읽히는 사진이 나오면 `ImageBudget.minimumLongSide`를 **1200으로** 올리면 됩니다.
같은 캡처가 1536×997(4타일, 1,032토큰)이 되어 화면에서 보던 크기 그대로가 됩니다.
여전히 원본의 3분의 1입니다. 이 값은 소스 주석에도 적어 뒀습니다.

### A-5. 다시 보내도 소용없는 실패를 두 번 더 보냅니다

**지금 맥 판** — `SingleChatRoomView.swift:551`

```swift
if !alreadyShown, attempt < Self.silentRetryCount {
```

어떤 실패든 조용히 두 번 더 보냅니다. 그런데 키가 틀렸거나(401) 요청이 잘못됐거나(400)
안전 필터에 걸린 요청은 몇 번을 보내도 똑같이 실패합니다.
그 두 번은 **화면에 아무것도 남기지 않으면서 요금만 세 배로 냅니다.**

안전 필터에 걸린 경우가 특히 그렇습니다. 서버는 입력을 다 읽고 답을 만들다 멈춘 것이라 요금은 그대로 나갑니다.

**안드로이드가 고친 방식** — `AIService.kt:44`, `ChatRoomViewModel.kt:193`

```kotlin
class AIServiceException(message: String, val retryable: Boolean = false) : Exception(message)

private fun retryable(code: Int): Boolean = code == 429 || code >= 500
```

429는 잠깐 몰린 것이고 5xx는 저쪽 사정이라 다시 보낼 값어치가 있습니다.
서비스가 아닌 곳에서 온 예외(주로 네트워크)는 기본값 참으로 두어 계속 재시도합니다.

맥에서는 `serviceError(_:)`(:1278)가 `NSError`를 만드니, `userInfo`에 `retryable` 플래그를 넣거나
전용 `Error` 타입으로 바꾸면 됩니다.

### A-6. 챗봇 방에서도 medium으로 생각합니다

**지금 맥 판** — `GeminiService.swift:850`, `:888` 두 곳에 `"medium"`이 박혀 있습니다.

사고 토큰은 화면에 한 글자도 안 보이지만 **출력 단가로 청구됩니다.** 출력 단가는 입력의 다섯 배입니다.
(모델이 생각을 안 하는 것이 아닙니다 — Gemini가 사고한 *내용*을 안 돌려줄 뿐이고,
`thoughtsTokenCount`로 몇 토큰 썼는지는 옵니다.)

멘토는 계산이 틀리면 그대로 틀린 것을 가르치게 되므로 생각할 값어치가 있습니다.
챗봇은 다릅니다. 여기서 필요한 것은 정답이 아니라 그 인물다운 말씨와 빠른 대꾸이고,
그건 오래 생각한다고 좋아지는 종류가 아닙니다. 오히려 답이 늦어집니다.

**안드로이드가 고친 방식** — `ChatMode.kt:60`

```kotlin
val geminiThinkingLevel: String
    get() = when (this) {
        MATH_MENTOR -> "medium"
        COMPANION -> "low"
    }
```

`ChatMode.swift`에 같은 프로퍼티를 넣고 두 자리를 `mode.geminiThinkingLevel`로 바꾸면 됩니다.
요금과 지연이 함께 줄어듭니다.

### A-7. 요청 본문이 두 벌이라 한쪽만 고쳐진다 *(작업 중 발견)*

A-6을 고치려는데 `"medium"`이 **두 곳**에 박혀 있었습니다. 왜 두 곳인지 보니
`streamBody(...)`(:846)와 `performGeminiRequest(...)`(:885)가 **같은 요청 본문을 각각
따로 조립하고 있었습니다.** 안전 설정, 캐시 분기, `maxOutputTokens`까지 전부 두 벌입니다.

이건 그 자체로 결함입니다. 한쪽만 고치면 다른 쪽이 조용히 옛 설정으로 나갑니다.
실제로 A-6이 정확히 그 모양이었습니다 — 스트리밍만 고쳤다면, 스트리밍을 안 쓰는
경로(Luna로 바꿨다가 돌아오는 경우 등)는 계속 medium으로 나갔을 것입니다.

**증거는 셋의 값이 실제로 같아야 한다는 점입니다.** 두 함수가 만드는 본문은 캐시
분기까지 한 글자도 다르지 않았습니다. 다를 이유가 없는데 두 벌인 것이라,
`requestBody(contents:system:cache:mode:)` 하나로 합쳤습니다.

**고친 방식** — 한 함수로 합치고 양쪽이 그것을 부릅니다. 사고량은 이제 한 곳에만 있습니다.

---

## B. 장부가 틀린 곳

"앱 안의 요금 계산이 단단히 과소평가되고 있다"는 관찰의 실체입니다. 셋 다 **실제로 청구되는데 화면에 안 잡히는** 것입니다.

### B-1. 대화 말고는 아무것도 안 세고 있습니다

**지금 맥 판** — 사용량을 적는 곳은 `sendGeminiRequest`(:735-749)와 `sendOpenAIRequest`(:1070-1086) 둘뿐입니다.

`URLSession.shared.data`로 직접 나가는 아래 요청들은 **한 건도 장부에 안 적힙니다.**

| 함수 | 줄 | 무게 |
|---|---|---|
| `lookupPersona` | :233 | 검색 그라운딩 + URL 읽기 + `thinkingLevel: medium`. **가장 무겁습니다.** |
| `previewPersona` | :357 | 미리보기 한 칸마다 한 건. 맥은 열 때 3건을 동시에 던집니다(:544) |
| `refinePersonaStyle` | :433 | |
| `analyzePersonaStyle` | :504 | |
| `postGemini` (구간 요약) | :530 | 150턴 넘은 방에서 50턴마다 |

말투 조사는 앱 화면에서 **공짜처럼 보입니다.** 요금이 과소평가되던 가장 큰 이유입니다.

**안드로이드가 고친 방식** — `AIService.kt:1039`

`postGemini` 한 곳에 사용량 기록을 넣고, 위 함수들이 전부 그 문을 지나가게 했습니다.
스트리밍으로 나가는 말투 조사는 `streamGeminiText`(:1082)가 같은 일을 합니다.

```kotlin
usage.recordUsage(
    roomId, model,
    // 검색 그라운딩을 쓰면 도구가 쓴 입력이 따로 옵니다. 이것도 청구됩니다.
    inputTokens = reported.optInt("promptTokenCount") + reported.optInt("toolUsePromptTokenCount"),
    outputTokens = reported.optInt("candidatesTokenCount") + reported.optInt("thoughtsTokenCount"),
    cachedInputTokens = reported.optInt("cachedContentTokenCount")
)
```

맥 판에는 `toolUsePromptTokenCount`도 빠져 있습니다(:738). 말투 조사가 쓰는 검색 도구의 입력이 이쪽으로 옵니다.

> 옮기려면 이 함수들에 `roomId`가 필요합니다. 안드로이드도 그래서 전부 `roomId`를 받도록 시그니처를 바꿨습니다.

### B-2. 캐시를 만드느라 올린 토큰을 안 셉니다

**지금 맥 판** — `GeminiService.swift:978-987`은 보관료(`tokenHours`)만 적습니다.
`cachedContents`로 올린 토큰 자체는 어디에도 안 잡힙니다.
이건 별개의 요청이라 어떤 `promptTokenCount`에도 안 들어갑니다.

A-1과 겹치면 최악입니다. **매 턴 수만 토큰을 다시 올리면서, 그 비용이 화면에서 통째로 사라져 있습니다.**
그리고 캐시를 만드는 것도 API 요청 한 건인데 횟수에도 안 잡혀서, "메시지 수보다 요청이 적은" 장부가 나옵니다.

**안드로이드가 고친 방식** — `TokenUsageStore.kt:26-32`, `:131`

```kotlin
/// Gemini식 명시적 캐시를 **새로 만드느라 올린** 토큰입니다.
/// 이건 별개의 요청(`cachedContents` POST)이라 어떤 `promptTokenCount`에도
/// 잡히지 않습니다. 그래서 덜어 내지 않고 그대로 더합니다.
val cacheCreateTokens: Int = 0
```

`recordCacheCreation(roomId, model, tokens, tokenHours)`가 토큰·보관량·요청 횟수를 함께 적습니다.

> **입력 단가로 칩니다.** 캐시 생성 요청이 청구되는지 문서로 확인하지는 못했습니다.
> 확실하지 않을 때는 비싼 쪽으로 잡습니다 — 화면의 숫자가 실제보다 적은 것이 많은 것보다 나쁩니다.

### B-3. 도중에 멈춘 답변의 요금이 사라집니다

**지금 맥 판** — `GeminiService.swift:735`

```swift
if !result.usage.isEmpty, let roomId {
```

스트림이 **정상적으로 끝난 뒤에만** 적습니다. 그런데:

- 사용자가 답변을 도중에 멈추면 `Task`가 취소되면서 이 자리를 건너뜁니다.
  서버는 이미 입력을 다 읽고 답을 만들고 있었으므로 요금은 그대로 나갑니다.
- 캐시가 만료돼 첫 시도가 실패하고 캐시 없이 다시 보내는 경로(:726-733)에서는,
  **첫 시도의 사용량이 통째로 버려집니다.**

사용량 조각은 SSE의 매 청크에 실려 오기 때문에, 도중에 멈춰도 그때까지 받은 값은 손에 있습니다.

**안드로이드가 고친 방식** — `AIService.kt:198-218`

```kotlin
val outcome = StreamOutcome()
try {
    streamGemini(outcome, ...)
    sink.finish()
} finally {
    val reported = outcome.usage
    if (reported != null) { usage.recordUsage(...) }
    else { usage.recordUnreportedRequest(roomId, model) }   // 숫자를 지어내지 않고 건수만 남깁니다
}
```

`unreportedRequests`는 "청구서에는 있고 여기에는 없는" 요청 수입니다.
0이 아니면 화면의 요금이 실제보다 적다는 뜻이고, 설정 화면에 그렇게 적어 둡니다.

**고친 방식** — `StreamOutcome`을 구조체에서 **참조 타입으로** 바꿔 밖에서 만들어 넘깁니다.
값으로 돌려주면 예외로 빠져나갈 때 함께 사라지지만, 상자를 넘기면 그 안에 담긴 것은
부르는 쪽 손에 남습니다. 그리고 `defer`에서 적습니다 — Swift의 `defer`는 취소로 인한
언와인딩에서도 돕니다.

**작업 중 알게 된 것 하나** — 캐시 없이 다시 보내는 경로(:726)는 **첫 시도의 사용량을
두 번째 시도가 덮어써서** 통째로 없앨 수 있었습니다. 그래서 재시도로 넘어가기 전에
먼저 적고 상자를 비웁니다.

**미보고 건수를 세는 기준도 좁혔습니다.** 처음에는 "사용량을 못 받았으면 무조건 한 건"으로
잡았는데, 그러면 400·429·5xx처럼 **생성이 시작되기도 전에 거절당한** 요청까지 세게 됩니다.
그건 청구되지 않으므로, 세면 "요금이 실제보다 적다"는 경고가 부풀어 믿을 수 없게 됩니다.
지금은 서버가 답을 만들기 시작한 뒤(2xx를 받은 뒤)에만 셉니다 — `StreamOutcome.serverResponded`.

---

## C. 기억이 망가지는 곳

### C-1. 챗봇 방을 과외 기록으로 요약합니다 ★되돌릴 수 없음

**지금 맥 판** — `ConversationCompactor.swift:67`의 `summaryInstruction`은 **과외용 하나뿐**입니다.
`GeminiService.swift:631`이 모드와 무관하게 그것을 씁니다. `transcript(for:startingTurn:)`(:131)도
누구를 "학습자/답변자"로 고정해 부릅니다.

챗봇 방이 150턴을 넘으면 캐릭터 대화 50턴이
`■ 상황 / ■ 흐름 / ■ 틀린 지점 / ■ 이해가 뚫린 순간 / ■ 미해결 / ■ 지도 참고`
로 정리됩니다. 여기에 **관계도, 서로 부르는 법도, 주고받은 약속도, 감정의 결도 한 줄 안 남습니다.**
압축이 기억을 *줄이는* 것이 아니라 *버리는* 것이 됩니다.

**그리고 요약은 한 번 쓰면 다시 안 만듭니다.** 나중에 지침을 고쳐도 이미 쓰인 구간은 그대로 남습니다.
**이 항목만은 지금 고치는 값어치가 시간에 비례해 커집니다.**

**안드로이드가 고친 방식** — `ConversationCompactor.kt:70`

```kotlin
fun summaryInstruction(mode: ChatMode): String = when (mode) {
    ChatMode.MATH_MENTOR -> MENTOR_SUMMARY_INSTRUCTION
    ChatMode.COMPANION -> COMPANION_SUMMARY_INSTRUCTION
}
```

챗봇용 소제목은 `■ 관계 / ■ 있었던 일 / ■ 주고받은 것 / ■ 감정의 결 / ■ 사용자에 대해 / ■ 이어서`입니다.
뼈대는 같지만 남길 것이 완전히 다릅니다. 여기서 기억이란 무엇을 배웠는지가 아니라
**둘 사이에 무슨 일이 있었는지**입니다.

함께 바뀌는 것:

- `transcript(turns, startingTurn, mode)` — 챗봇 방은 `사용자`/`상대`로 부릅니다.
  "학습자/답변자"로 옮겨 놓으면 요약하는 쪽이 그걸 수업 기록으로 읽습니다.
- `render(digest, mode)` — 요약을 앞에 붙일 때의 안내문도 갈라집니다.
  ("관계와 약속, 아직 안 끝난 이야기는 지금도 그대로인 것으로 간주한다")
- `plan(conversation, digest, mode)`

**양쪽 지침 모두 "답변자 자신의 정체성은 적지 말라"는 규칙을 갖습니다.**
이름도 말투도 방의 말투 설정에서 매번 새로 정해집니다. 옛 요약에 그게 남아 있으면 지금 설정과 싸웁니다.
챗봇 방에서 더 중요합니다.

맥 판에도 시험이 있다면 `android/.../DigestByModeTest.kt`를 그대로 옮길 만합니다.
"챗봇 지침에 '틀린 지점'이 없다" 같은, 재발을 막는 시험입니다.

> 임계값(`thresholdTurns` 150, `verbatimWindowTurns` 20, `refreshPeriodTurns` 50)은
> **건드리지 않습니다.** 낮추면 요금이 잠깐 줄고 기억은 영영 줄어듭니다.

---

## D. 화면

요금·기억 항목을 다 옮긴 뒤에 봐도 되는 것들입니다.

### D-1. 다크 모드에서 입력창 글씨가 안 보입니다 ★버그로 의심됨

**지금 맥 판** — `ChatInputView.swift:253`

```swift
textView.textColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
textView.insertionPointColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.85)
```

입력창 바탕은 `KakaoTheme.surface`(:193)이고 다크에서 `#1A1A1A`입니다.
글자색은 `#1A1A1A`에 고정돼 있습니다. **같은 색입니다.**

바로 옆의 플레이스홀더는 동적 색(`KakaoTheme.textTertiary`)을 써서 잘 보이므로,
"입력하기 전엔 보이는데 치기 시작하면 사라진다"로 나타날 것입니다.

**고친 방식** — `KakaoTheme.nsDynamic(light:dark:)`을 만들고 `nsTextPrimary`·`nsCaret`을
거기 태웠습니다. 커서는 알파를 나중에 씌우지 않고 양쪽 값에 미리 넣었습니다 —
동적 `NSColor`에 `withAlphaComponent`를 걸면 그 자리에서 한쪽으로 굳을 수 있습니다.

**실측 (2026-08-17)** — 같은 `NSTextView` 설정으로 실제로 그려 화소를 찍었습니다.

| | 글자 | 바탕 | 명암비 |
|---|---|---|---|
| 고치기 전 (다크) | #1A1A1A | #1A1A1A | **1.01:1** — 사실상 안 보임 |
| 고친 뒤 (다크) | #EBEBEB | #191919 | 14.7:1 |
| 고친 뒤 (라이트) | #191919 | #FFFEFF | 17.4:1 |

빌드해서 설치하고 다크 모드로 실제 화면도 확인했습니다. 친 글자가 그대로 보입니다.

> 이것만은 안드로이드에서 온 것이 아니라 이번에 소스를 읽다 발견한 것입니다.

### D-2. 말투 조사에 진행 상황이 없습니다

**지금 맥 판** — `PersonaEditorView.swift:252`는 "찾는 중"과 스피너만 보여줍니다.
이 요청은 검색 → 읽기 → 정리로 오래 걸리는데, 화면만 봐서는 멈춘 것인지 되고 있는 것인지 알 수 없습니다.

**안드로이드가 고친 방식** — `AIService.kt:1421`

**진행률을 흉내 내지 않습니다.** 한 번에 받지 않고 흘려 받으면서, 답변에 실제로 도착한 절을 그대로 알려 줍니다.

```kotlin
fun lookupProgressLabel(soFar: String): String = when {
    soFar.contains("[말투]") -> "말투 규칙을 적고 있습니다…"
    soFar.contains("[대사]") -> { /* 몇 줄까지 왔는지 함께 셉니다 */ }
    soFar.contains("[확신도]") -> "찾은 자료를 살펴보고 있습니다…"
    else -> "자료를 찾고 있습니다…"
}
```

시간을 재서 지어낸 단계가 아니라 방금 받은 글자가 근거입니다.
대사 줄 수가 늘어나는 것이 보여야 멈춘 것이 아님을 알 수 있습니다.

맥은 `URLSession.bytes(for:)`로 이미 SSE를 읽고 있으니(:813) 같은 구조를 쓸 수 있습니다.
**B-1(사용량 기록)과 같은 함수를 건드리므로 함께 하는 편이 좋습니다.**

### D-3. 미리보기를 열자마자 3건을 던집니다

**지금 맥 판** — `PersonaEditorView.swift:544`는 `withTaskGroup`으로 세 질문을 동시에 보냅니다.
셋 다 장부에 안 잡히고(B-1), 사용자가 하나만 보고 싶어도 셋 값을 냅니다.

**고친 방식** — 세 상황을 항상 펼쳐 두고 각각에 "물어보기" 버튼을 뒀습니다. 누른 것만
보냅니다. 직접 쓴 질문을 던지는 칸도 함께 뒀습니다. 한 번에 하나만 나가도록 막아
연달아 눌러도 겹치지 않습니다.

빌드해서 실제 화면으로 확인했습니다. 챗봇 방에서 열었을 때 챗봇용 질문
(말 걸었을 때 / 속마음을 물을 때 / 기분이 안 좋을 때)이 나오고, 아무것도 안 누르면
요청이 한 건도 안 나갑니다.

### D-4. 미리보기만 안전 필터가 켜져 있었다 *(작업 중 발견)*

B-1을 하느라 `previewPersona`(:326)를 들여다보다 찾았습니다.
**이 함수만 `safetySettings`를 안 보냅니다.**

실제 대화는 챗봇 방에서 필터를 내립니다(`ChatMode.geminiSafetySettings`,
`GeminiService.swift:854`, `:892`). 그런데 미리보기는 안 내립니다.
같은 시스템 지침, 같은 모델, 같은 말투인데 **조건이 하나 다릅니다.**

그래서 챗봇 방에서 미리보기만 답이 통째로 잘려 나올 수 있습니다.
사용자는 실제 대화에서는 멀쩡히 나올 말투를 보고 "말투가 잘못됐다"고 판단하게 됩니다.
미리보기의 존재 이유가 "여기서 보이는 결이 채팅방에서도 그대로 나온다"는 것인데,
그 전제가 깨져 있었습니다.

**근거** — 함수 주석에 이미 "실제 대화와 똑같은 시스템 지침을 쓰므로, 여기서 보이는 결이
채팅방에서도 그대로 나옵니다"라고 적혀 있습니다. 지침만 같고 안전 설정은 달랐습니다.
안드로이드판에는 이 줄이 있습니다(`AIService.kt:783`).

**고친 방식** — 미리보기에도 같은 `safetySettings`를 실어 보냅니다.

### D-4. 옮기지 않아도 되는 것

확인해 보니 맥 판에 이미 있거나, 맥에는 해당하지 않는 것들입니다. 다시 들추지 않도록 적어 둡니다.

| 안드로이드에서 한 일 | 맥은 왜 안 해도 되는지 |
|---|---|
| 입력창 곡률 고정 (여러 줄에서 글씨가 창 밖으로) | 맥 입력창은 높이 58 고정에 스크롤(`ChatInputView.swift:98`)이라 늘어나지 않습니다 |
| 수정 모드에서 변한 것 없어도 전송 | 맥은 이미 비어 있지만 않으면 재전송합니다 (`SingleChatRoomView.swift:424`) |
| 프로필을 눌러서 보기 | 맥은 이미 아바타 클릭(`MessageBubbleView.swift:280`)과 친구 행 클릭(`KakaoMainWindowView.swift:462`)으로 카드를 엽니다 |
| 카카오톡식 액션 카드 메뉴 | 맥은 데스크톱 컨텍스트 메뉴가 맞습니다. 모바일 바텀시트를 옮길 이유가 없습니다 |
| 키 저장 실패를 화면에 알리기 | 맥은 이미 알립니다 (`KakaoUsageSettingsView.swift:374`). 키체인은 `EncryptedSharedPreferences`처럼 깨지지 않습니다 |
| 모드별 미리보기 질문 | 맥에 이미 있습니다 (`GeminiService.swift:307`) |
| `TokenEstimator`의 타일 계산 | 양쪽이 같습니다 |

---

## E. 덤 — 옮기는 김에 볼 것

안드로이드에서 갈라진 것 중 **어느 쪽이 맞는지 정하지 않은** 항목입니다. 결정이 필요합니다.

### E-1. OpenAI에 대화를 남길 것인가

- 맥 (`GeminiService.swift:1055-1056`): `"background": true, "store": true`
- 안드로이드 (`AIService.kt:910`): `"store": false`

맥은 `background: true`로 서버에서 생성을 계속시키고 짧은 조회로 완료를 확인합니다.
긴 수학 답변 도중 연결이 한 번 끊겨도 같은 응답을 다시 조회할 수 있어 **중복 과금을 피합니다.**
그런데 `background`는 `store: true`를 요구하고, 그러면 **대화 내용이 OpenAI에 보관됩니다.**

안드로이드는 그 경로를 통째로 버리고 한 번에 받습니다. 대신 연결이 끊기면 그 요청은 날아갑니다.

둘 다 근거가 있습니다. 맥은 긴 답변을 받는 자리라 지금 방식이 맞을 수 있고,
보관이 걸린다면 `store: false` + 재시도로 바꾸는 쪽이 맞습니다. **정해야 할 값입니다.**

---

## 남은 일

코드로 할 수 있는 것은 끝났습니다. 남은 것은 **확인**과 **결정**입니다.

1. **요금이 실제로 줄었는지 청구액으로 확인.** 앱 화면의 숫자는 이제 예전보다 크게 나옵니다 —
   전보다 많이 쓴 것이 아니라 **안 세던 것을 세기 시작해서** 그렇습니다. 비교하려면
   고친 뒤끼리 비교해야 합니다.
2. **사진이 여전히 읽히는지.** A-4의 "남은 위험"입니다. 문제지 캡처를 보내 답이 엉뚱하면
   `ImageBudget.minimumLongSide`를 1200으로 올립니다.
3. **E-1을 정할 것.** OpenAI에 대화를 남길지 말지. 코드가 아니라 판단입니다.
4. **시험이 없습니다.** 맥 판에는 테스트 타깃이 아예 없습니다(안드로이드는 61개).
   특히 C-1은 **한 번 잘못 쓰면 되돌릴 수 없는** 항목이라,
   `android/.../DigestByModeTest.kt`에 해당하는 시험이 있는 편이 좋습니다.
   `Package.swift`에 라이브러리 타깃을 나누는 작업이 필요해 이번에는 하지 않았습니다.

## 옮기면서 지킨 것

**"왜 그렇게 했는지"를 주석째 옮겼습니다.** 코드만 옮기고 주석을 버리면 다음 사람이
같은 자리를 원래대로 되돌립니다. 특히 아래 자리들은 겉보기에 불필요해 보이는 조건이라,
근거가 없으면 "간단히 하려고" 지워지기 쉽습니다.

- `GeminiService.swift` — 안 읽을 캐시를 안 만드는 이유 (`refreshPrefixCache`)
- 같은 파일 — 매 턴 다시 만들지 않는 셈 (꼬리 대 캐시의 5분의 1)
- 같은 파일 — `defer`에 적는 이유, `null`만 돌려주면 안 되는 이유
- `ImageBudget.swift` — 타일 격자가 왜 화소가 아닌지
- `ConversationCompactor.swift` — 모드별 지침이 왜 필요한지

**정한 값과 잰 값을 구분해 적었습니다.** 아래는 실측이 아니라 **정한 값**이고,
소스 주석에도 그렇게 적혀 있습니다. 안 적으면 나중에 실측값으로 오해받아 지워집니다.

| 값 | 어디 | 근거 |
|---|---|---|
| `minimumLongSide = 900` | `ImageBudget.swift` | 정한 값. 세로 사진 기준이라 가로 캡처에서 위험 |
| `cacheBurstWindow = 300초` | `GeminiService.swift` | 정한 값. 사용 기록에서 뽑지 않음 |
| `cacheRefreshMinTailTokens = 2000` | 같은 파일 | 정한 값 |
| `cacheRefreshTTLFloor = 240초` | 같은 파일 | 정한 값 |
| `tokensPerImageTile = 258` | `TokenEstimator.swift` | **잰 값.** 사용량 장부에서 연립해 풀었음 |

**임계값은 건드리지 않았습니다.** `thresholdTurns` 150, `verbatimWindowTurns` 20,
`refreshPeriodTurns` 50은 그대로입니다. 낮추면 요금이 잠깐 줄고 기억은 영영 줄어듭니다.
