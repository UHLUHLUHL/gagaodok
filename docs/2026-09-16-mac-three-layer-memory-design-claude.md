# 맥 앱 3계층 기억(M3) 도입 설계

작성: 2026-09-16 · 기준 커밋 `a972808` (worktree `~/Desktop/gagaodok-phone-30m-claude`, 브랜치 `claude/phone-30m-diagnostics`)
상태: **설계만 완료. 코드는 아직 한 줄도 바꾸지 않았다.** 아래 "착수 조건"이 채워지면 7장 순서대로 진행한다.

---

## 0. 다시 꺼냈을 때 먼저 할 것

1. 이 문서의 **3장 착수 조건** 네 가지를 9장 명령으로 확인한다.
2. 기준 커밋 이후 무엇이 바뀌었는지 본다.
   ```bash
   git -C ~/Desktop/gagaodok-phone-30m-claude log --oneline a972808..HEAD
   ```
   특히 `android/.../service/ThreeLayerMemory.kt`, `AIServicePhoneMemory.kt`,
   `Sources/KakaoSapiens/Services/ConversationCompactor.swift`,
   `GeminiService+Digest.swift`가 바뀌었으면 2장 표를 다시 맞춘다.
3. 메인 체크아웃(`~/Desktop/ClaudeCode`)의 미커밋 Swift 작업(말풍선·Mermaid)이 아직 남아 있는지 본다.
   맥 앱은 그 작업까지 합쳐 설치돼 있으므로, 설치할 때 같은 방식(10장)을 쓴다.
4. 결정이 필요한 곳은 **8장 열린 질문**에 모아 두었다. 착수 전에 사용자에게 확인한다.

---

## 1. 무엇을, 왜

### 1.1 계층

| 계층 | 담당 | 폰 | 맥 |
|---|---|---|---|
| M1 최근 원문 | 말투·직전 장면 | 있음 (30~80턴) | 있음 (같은 값) |
| M2 구간 요약 | 과거 사건 | 있음 (50턴 단위) | 있음 (같은 값) |
| **M3 현재 상태** | 관계·호칭·말투·장소·시간·참여자·진행 중 장면·최근 감정 변화, 지켜야 할 약속(`boundary:*`), 반복 금지 규칙(`loop:*`) | **있음** | **없음** |

맥에 옮긴다는 것은 사실상 **M3를 새로 만드는 일**이다.

### 1.2 왜 필요한가

코덱스의 검증 문서가 근거다 — `~/Desktop/ClaudeCode/docs/2026-09-04-three-layer-memory-validation.md`
(메인 체크아웃의 미추적 파일. 이 브랜치에는 없다).

요지: M2는 과거 사건은 잘 남기지만, 50턴 구간마다 그 시점의 관계·감정·장면이 요약 글 안에
계속 쌓인다. 렌더러가 서로 다른 시점의 상태를 모두 "지금도 유효"하다고 내보내므로, 긴 방에서
모델이 **최신 상태를 고르는 부담**과 **오래된 상태를 사실로 받아들일 위험**이 커진다.
M3는 상태를 따로 떼어 최신값 하나로 유지한다.

그 문서가 검증한 "실제 394턴 방"은 **맥의 `5E0B692E` 방**이다(사용자 턴 394, 2026-09-16 기준).

### 1.3 비용

**비용을 줄이는 기능이 아니다.** 같은 문서의 추정으로 M2 평균 1,000 + M3 279이면 고정 프롬프트가
2.3% 작아질 수 있다는 정도다. 목적은 기억의 질이다.

M3는 M2와 **같은 순간(50턴 압축)에만** 바뀐다. 캐시를 더 자주 깨지 않는다.

---

## 2. 현재 구현 대조

### 2.1 폰 (옮겨 올 원본)

| 구성 | 위치 | 요지 |
|---|---|---|
| 순수 규칙 | `android/.../service/ThreeLayerMemory.kt` | `MemoryItem`·`MemoryCheckpoint`·`MemoryOperation`·`MemoryDraft`, `reduce`(:101), `validPrefix`(:168), `parts`/`render`(:198), `hash`(:68) |
| 상한 | 같은 파일 | `STATE_TOKEN_BUDGET = 3000`(:96), `LOOP_RULE_LIMIT = 10`(:31). 넘으면 **가장 오래된 `loop:`부터 놓고** `boundary:`는 지킨다 |
| 생성 | `android/.../service/AIServicePhoneMemory.kt` `updatePhoneMemory`(:12) | 한 번의 호출로 M2 구간과 M3 변경을 함께 받는다. `responseSchema`(:226), 사고 `low`, 예산 `phoneMemoryOutputBudget` |
| 옛 기억 변환 | 같은 파일 :86~111, :205 | `memoryVersion == 0`이면 기존 구간 **전부를 다시 요약**하고, 결과가 원본보다 크면 거부(`MIGRATION_NOT_SMALLER`) |
| 결과 분류 | `android/.../service/PhoneMemoryOutcome.kt` | 14갈래, 유료 여부, 재시도 대기(15분→6시간) |
| 원자적 저장 | `android/.../data/ChatStore.kt` `commitPhoneMemory`(:354) | 메시지 쓰기 줄을 비운 뒤 ① 현재 요약이 기대값과 같은지 ② 원문 해시가 같은지 확인하고 ③ 첫 변환이면 `.legacy` 백업 ④ `AtomicFile`로 교체 |
| 사용 조건 | `android/.../service/AIServiceConversation.kt` :60~66, :249~255 | 폰·챗봇·1:1 방만. 저장된 `memoryVersion`이 0·2가 아니면 오류. 요청 전에 `validPrefix`로 무효 구간을 잘라 낸다 |
| 요약 보기 화면 | `android/.../ui/screens/ConversationDigestSheet.kt` (218줄) | 채팅방 메뉴의 "대화 요약" |
| 검사 | `android/app/src/test/.../ThreeLayerMemoryTest.kt`, `MemoryDegradationTest.kt`, `PhoneMemoryBudgetTest.kt`, `PhoneMemoryOutcomeTest.kt`, `DigestPartsAndGapTest.kt` | |

폰의 변경 이력: `02b5bf7`(09-07 도입) → `1429893`, `d6149f8`(결과 분류) → `c5de63f`(사고 수준 low) →
`8a848b5`, `19f37f9`(상태 포화 대처) → `5cde1a3`(M2/M3 토큰 분리 측정).

### 2.2 맥 (지금)

| 구성 | 위치 | 요지 |
|---|---|---|
| 자료형 | `Sources/KakaoSapiens/Services/ConversationCompactor.swift` :1~37 | `ConversationSegment`(id·firstTurn·lastTurn·text·createdAt), `ConversationDigest`(segments만). **`memoryVersion`·`revision`·`memory` 없음** |
| 계획 | 같은 파일 `plan`(:298) | 챗봇 80/30/50, 멘토 60/20/40. 렌더러를 바꿔 끼울 인자가 **없다**(폰은 `renderDigest`를 받는다) |
| 렌더 | 같은 파일 `render`(:336) | 한 층 |
| 생성 | `GeminiService+Digest.swift` `appendDigestSegment`(:22) | 한 구간씩 **글로** 요약. 챗봇은 사고 `low`, 멘토는 `high`(`2cba80a`). 실패 시 재시도 대기(`digestRetry`) |
| 결과 분류 | `OptimizationMeasurementStore.swift` `DigestOutcome` | 폰 이름 중 8갈래(`89f68f4`) |
| 저장 | `Models/ChatRoom.swift` `saveDigestForRoom`(:436) | `persistenceQueue`에서 **비동기** 원자 쓰기. **기대값 비교 없음** |
| 메시지 저장 | 같은 파일 `saveMessagesForRoom`(:469) | 0.7초 모아서 같은 큐에 씀(`pendingSaves`). 비우는 공개 함수 없음 |
| 사용 조건 | `GeminiService+Conversation.swift` `sendGeminiRequest`(:21), :193 | 챗봇·멘토 공통 경로 |
| 요약 화면 | 없음 | |
| 검사 | 요약 관련 없음 | |

### 2.3 맥 데이터 (2026-09-16 기준, 개수만 확인)

- 메시지 파일 13개, 그중 요약이 있는 방 2개.
  - `134C72B5`: 사용자 364턴, 요약 7구간·280턴까지, **미요약 84**(기준 80을 넘었는데 09-01 이후 전진 없음).
    요약 실패가 되풀이됐을 가능성이 높다(사고 `high` + 예산 2,700). `2cba80a`에서 고쳤고 결과는 측정으로 확인 예정.
  - `5E0B692E`: 사용자 394턴, 요약 7구간·350턴까지, 미요약 44.
- 동기화 코드는 요약 파일을 다루지 않는다(`SyncShadowReader.swift`는 자체 해시만 계산). **형식을 바꿔도 동기화에는 영향이 없다.**
- 맥 기본 모델은 3.8(사용자가 09-16에 변경). 측정은 설치 직후 시작 예정.

---

## 3. 착수 조건

| # | 조건 | 왜 | 확인 방법 |
|---|---|---|---|
| G1 | 맥 측정에서 **현재 한 층 요약이 성공하는지** 확인 — `COMMITTED` 3회 이상, `maxConsecutivePaidFailures` ≤ 1 | 기존 요약이 실패 중이면 원인이 따로 있다. 그 위에 M3를 얹으면 원인을 가릴 수 없다 | 9.1 |
| G2 | 폰 3계층이 **누적 10회 이상 성공**, 연속 유료 실패 ≤ 1 | 지금 폰은 수정 뒤 4회 성공뿐이다. 검증이 짧은 구조를 한 벌 더 만들지 않는다 | 9.2 |
| G3 | 8장 열린 질문에 대한 **사용자 결정** | 옛 기억 변환 방식은 되돌리기 어려운 선택이다 | — |
| G4 | 맥 데이터 폴더 **백업** | 실제 대화 기억을 다시 쓴다 | 9.3 |

G1이 실패로 나오면(예: `NOT_STOP` 연속) **M3보다 그 원인을 먼저 고친다.**

---

## 4. 설계

### 4.1 범위

- **대상**: 맥의 로컬 1:1 **챗봇** 방.
- **제외**: 수학 멘토(기존 한 층 경로 그대로), 원격·동기화 방(`RemoteChatRoomView`), OpenAI 모델을 쓰는 방.
- 폰과 규칙을 맞추되 **해시는 맥 자체 규칙**으로 한다. 폰 해시는 `sender.name`("USER")을, 맥은
  `rawValue`("user")를 쓰므로 서로 맞지 않는다. 요약 파일은 기기 사이를 오가지 않으므로 문제없다.
  나중에 요약을 동기화하게 되면 그때 한쪽으로 맞춘다(8장 Q5).

### 4.2 자료형 (`ConversationCompactor.swift`)

폰과 **같은 JSON 키**를 쓴다.

```swift
public struct ConversationSegment: Codable, Equatable, Identifiable {
    ... 기존 필드 ...
    public var memory: MemoryCheckpoint?          // 새 필드. 옛 파일에는 없음 → nil
}

public struct ConversationDigest: Codable, Equatable {
    public var segments: [ConversationSegment]
    public var memoryVersion: Int = 0             // 0: 한 층, 2: 3계층
    public var revision: Int = 0                  // 저장할 때마다 +1. 기대값 비교에 쓴다
}
```

- `ConversationDigest`는 지금 합성 `Codable`이라, 비옵셔널 새 필드를 넣으면 **옛 파일을 못 읽는다.**
  `init(from:)`을 직접 쓰고 `decodeIfPresent ?? 0`으로 읽는다.
- **되돌릴 때 중요한 성질**: 옛 앱 빌드는 모르는 키(`memory`, `memoryVersion`, `revision`)를
  무시하고 구간만 읽는다(Swift `JSONDecoder` 기본 동작). 백업 앱으로 되돌려도 파일이 깨지지 않는다.
  다만 옛 앱이 요약을 새로 저장하면 그 키들이 빠져 M3가 사라진다 — 손상은 아니고 한 층으로 돌아가는 것이다.

### 4.3 순수 규칙 (`Services/ThreeLayerMemory.swift`, 새 파일)

폰 `ThreeLayerMemory.kt`를 그대로 옮긴다. **네트워크·저장소·액터와 무관하게** 둔다 — 단독으로 검사하기 위해서다
(`GeminiCachePolicy.swift`와 같은 방식).

- `MemoryItem(key, text, evidenceTurnId, setAtTurn)`, `MemoryCheckpoint(throughTurnId, sourceHash, items, rendererVersion)`,
  `MemoryOperation(op, key, evidenceTurnId, text?)`, `MemoryDraft(segments, updates)`
- `fixedKeys` 8개, 키 패턴 `(boundary|loop):[A-Za-z0-9_-]{1,48}`
- `reduce(previous:updates:evidence:throughTurn:) throws -> (items, droppedLoops)` —
  폰의 `require` 여덟 개를 오류 사유 문자열과 함께 던진다(측정의 `failureDetails`로 간다).
- `stateTokenBudget = 3000`, `loopRuleLimit = 10`, 가득 차면 가장 오래된 `loop:`부터 놓는다.
- `validPrefix(digest:turns:)` — 체크포인트가 없는 구간은 **건너뛰고 유지**한다(폰과 같음. 4.7의 변환 방식 B가 이 성질에 기댄다).
- `parts(digest:)` / `render(digest:)` — 폰과 같은 머리글. `render`는 반드시 `parts`로 조립한다(측정 분리가 어긋나지 않게).
- `hash(turns:)` — 각 턴의 id·sender·text·첨부를 **길이 접두어 + UTF-8**로 이어 SHA-256. CryptoKit.

### 4.4 생성 경로 (`GeminiService+Memory.swift`, 새 파일)

폰 `updatePhoneMemory`를 옮긴다.

1. 재시도 대기 확인 → 같은 방 진행 중 확인(`summarizingRooms`) — 기존 `digestRetry`를 함께 쓴다.
2. 대상 구간: 일반 갱신은 `plan.pending`, 변환은 4.7.
3. `ConversationCompactor.slice`로 1~through 원문을 잘라 턴 수가 맞는지 확인(`SOURCE_TURN_MISMATCH`).
4. 지시문: **폰 문구를 그대로** 쓴다(`AIServicePhoneMemory.kt` :112~129). 바꾸면 두 앱의 성적을 견줄 수 없다.
5. 요청: `responseMimeType: application/json`, `responseSchema`(폰 :226과 같은 모양),
   `thinkingLevel: low`, `maxOutputTokens = outputBudget(구간수 × 1500 + 1000)`, 모델은 그 방의 모델.
6. 응답 검사 순서와 결과 이름(폰과 같게 `DigestOutcome`에 추가):
   `NO_CANDIDATE` → `NOT_STOP`(사유 기록) → `PARSE_FAILED` → `RANGE_MISMATCH` → `SEGMENT_TOO_LONG` →
   `STATE_REJECTED`(사유 기록) → (변환이면) `MIGRATION_NOT_SMALLER` → `COMMIT_REJECTED` / `COMMITTED`.
7. 측정: `observeDigest`에 `droppedLoops`를 더해 `droppedLoopRules`를 채운다(맥 장부에 필드는 이미 있다).
   요청 자체는 기존대로 `MEMORY` 작업으로 적는다.

**로그에 방 ID와 응답 본문을 남기지 않는다**(폰과 같음).

### 4.5 원자적 저장 (`ChatRoomManager.commitMemory`, 새 함수)

맥에는 "기대한 요약일 때만 교체"가 없다. 새로 만든다.

```swift
/// 성공하면 true. 기대값과 다르거나 원문이 바뀌었으면 아무것도 쓰지 않고 false.
func commitMemory(roomId: UUID, expected: ConversationDigest, replacement: ConversationDigest,
                  sourceHash: String, sourceThrough: Int) async -> Bool
```

순서:

1. **메인 액터에서** 그 방의 `pendingSaves` 작업을 즉시 실행하고 비운다(`flushPendingSave(roomId:)` 새 함수).
   안 하면 0.7초 안에 쓴 메시지가 아직 파일에 없어 해시가 틀린다.
2. `persistenceQueue.sync { ... }` 안에서 — 같은 직렬 큐라 앞서 예약된 요약·메시지 쓰기가 모두 끝난 뒤다:
   - 파일의 현재 요약을 읽어 `expected`와 같은지 비교(`revision`까지 같아야 한다).
   - 메시지 파일을 읽어 `ConversationTurn.from` → `slice(1...sourceThrough)` → 턴 수와 해시 확인.
   - 처음 3계층으로 쓰는 것이면(`expected.memoryVersion == 0`이고 파일이 있으면) `room_<id>_digest.json.legacy`로 **한 번만** 복사.
   - `data.write(to:options: .atomic)`.
3. 성공하면 메모리 상태를 갱신한다.

`saveDigestForRoom`(비동기)은 기존 한 층 경로와 멘토가 계속 쓴다. 3계층 방에서는 `commitMemory`만 쓴다.

### 4.6 요청 경로 (`GeminiService+Conversation.swift`)

```
eligible = mode == .companion && roomId != nil && (로컬 1:1 방) && model.isGemini
stored   = loadDigestForRoom
guard stored.memoryVersion ∈ {0, 2} else { throw "이 방의 기억 형식은 현재 앱에서 지원하지 않습니다" }
digest   = eligible ? ThreeLayerMemory.validPrefix(stored, conversation) : stored
plan     = ConversationCompactor.plan(..., renderDigest: eligible && digest.memoryVersion == 2 ? ThreeLayerMemory.render : nil)
...응답 후...
if eligible && (plan.pending != nil || (stored.memoryVersion == 0 && !stored.isEmpty))
    → updateMacMemory
else if let pending = plan.pending
    → 기존 appendDigestSegment   (멘토·비대상)
```

- `ConversationCompactor.plan`에 `renderDigest` 인자를 더한다(폰 `plan`과 같은 모양).
- **`plan`의 이른 반환 조건**: 맥은 `total < 80`이면 요약을 통째로 빼고 원문만 보낸다(:309). 폰은
  `total < 80 && covered == 0`일 때만 그렇게 한다. 3계층 방이 수정·삭제로 80턴 아래로 줄면 맥은
  M3까지 잃는다. 폰 방식으로 맞추는 것이 맞아 보이나 동작 변경이므로 8장 Q3에서 확인한다.
- 측정: `PromptTokenBreakdown`의 `digestEventTokens`·`digestStateTokens`·`digestOverheadTokens`를
  `ThreeLayerMemory.parts`로 채운다(폰 `AIServiceConversation.kt` :86~99와 같은 방식).
- 캐시: `digestCoveredTurns: plan.coveredTurns`는 이미 넘기고 있다. M3는 압축 때만 바뀌므로 추가 조치가 필요 없다.

### 4.7 옛 기억 변환 — **결정 필요**

맥에는 한 층 요약을 가진 방이 둘 있다(각 7구간).

**방식 A — 폰과 같이 전부 다시 요약**
기존 구간 글을 입력으로 넣어 한 번에 모든 구간을 3계층으로 다시 쓴다. 결과가 원본보다 크면 버린다.

- 장점: 폰과 같아 규칙이 하나다.
- 단점: 폰 코드가 스스로 **"반복 비용의 가장 유력한 후보"**라고 적어 둔 경로다
  (`AIServicePhoneMemory.kt` :199~209). M3 몫만큼 구간을 줄여내지 못하면 구조적으로 실패하고,
  입력이 같으니 다시 해도 같다. 원본 요약이 **다시 쓰여** 되돌리려면 `.legacy` 백업에 기대야 한다.

**방식 B — 기존 구간은 그대로 두고 M3만 새로 시작 (권장)**
기존 구간은 글자 하나 안 바꾸고 `memory` 없이 유지한다. `memoryVersion`만 2로 올리고, **다음 압축**
(`plan.pending`)에서 첫 체크포인트를 만든다. `validPrefix`는 체크포인트 없는 구간을 건너뛰고 유지하므로
그대로 동작한다.

- 장점: 원본 요약이 그대로라 **되돌리기가 쉽고**, 변환 실패라는 갈래 자체가 없다. 추가 호출이 없다.
- 단점: 첫 M3가 최근 50턴만 보고 만들어져, **오래전에 정한 약속(`boundary:`)을 놓칠 수 있다.**
  - 보완: 첫 체크포인트를 만들 때만 **기존 구간 글을 참고 자료로 함께 넣고**
    "`boundary:`와 지속되는 관계 설정만 추출하라"고 지시한다. 구간 글은 다시 쓰지 않는다.
    그 한 번은 입력이 수천 토큰 늘어난다(7구간 × 약 500토큰).

**권장: B + 보완.** 되돌릴 수 없는 선택을 피하는 쪽이다. 사용자 결정이 필요하다(Q1).

### 4.8 되돌리기

| 단계 | 방법 |
|---|---|
| 코드 | 기능 스위치 하나(`macThreeLayerMemoryEnabled`, 기본 켬)로 4.6의 `eligible`을 끈다. 끄면 3계층 방도 한 층 렌더러로 읽힌다(체크포인트 무시) |
| 파일 | `room_<id>_digest.json.legacy`로 되돌린다(방식 A에서만 필요) |
| 앱 | 백업 앱을 다시 설치해도 파일이 깨지지 않는다(4.2) |

### 4.9 요약 보기 화면 (선택, 나중)

폰에는 "대화 요약" 화면이 있다. 맥에도 있으면 M3가 무엇을 기억하는지 사용자가 직접 볼 수 있다.
기능 도입과 분리해 뒤에 한다.

---

## 5. 검사 계획

맥 검사는 필요한 소스만 `swiftc`로 묶는 단독 실행 파일이다(`Tests/KakaoSapiensTests/*.swift` 머리 주석 참고).

### 5.1 단위 (폰 검사를 옮김)

| 새 검사 | 원본 | 확인할 것 |
|---|---|---|
| `ThreeLayerMemoryTests.swift` | `ThreeLayerMemoryTest.kt` | 키 허용·중복 금지·근거 밖 ID 거부·set/clear, `validPrefix`가 수정된 구간부터 자름, 체크포인트 없는 구간 유지 |
| 같은 파일 | `MemoryDegradationTest.kt` | 가득 차면 가장 오래된 `loop:`부터, `boundary:`는 안 놓음, 놓은 수 |
| 같은 파일 | `DigestPartsAndGapTest.kt` | `parts(d).text == render(d)` 글자까지 |
| `MacMemoryBudgetTests.swift` | `PhoneMemoryBudgetTest.kt` | 출력 예산 |
| 같은 파일 | `PhoneMemoryOutcomeTest.kt` | 결과별 유료 여부, 대기 시간 |

### 5.2 맥 고유

- 옛 요약 파일(`memoryVersion` 없음)을 읽으면 0.
- 3계층 파일을 **옛 자료형**(`ConversationSegment` 필드만)으로 읽어도 성공 — 되돌리기 보장.
- `commitMemory`: 기대값이 다르면 거부, 메시지를 고쳐 해시가 달라지면 거부, 처음 한 번만 `.legacy`, 쓰기 뒤 다시 읽으면 같음.
- 변환 방식 B: 기존 구간 글이 바이트 단위로 그대로인지.
- 멘토 방은 3계층 경로에 들어가지 않는지.

### 5.3 실기기

1. **시험용 방**에서 먼저: 80턴을 넘기는 합성 대화를 만들 수는 없으므로, 실제 방 사본을 쓰지 않고
   짧은 시험 방에서 기준을 임시로 낮춘 빌드(`claudeLab`에 해당하는 맥 시험 빌드는 없다 — Q4)로 돌린다.
2. 실제 방은 G4 백업 뒤에만.
3. 확인: 요약 파일의 `memoryVersion`·체크포인트 생성, 측정의 `COMMITTED`, `digestStateTokens`,
   `MEMORY` 작업의 `thoughtsTokens` ÷ 예산 < 96%(폰 `high` 실측값), 캐시 `SHRUNK` 비율이 늘지 않는지.

---

## 6. 켠 뒤의 판정 기준

| 지표 | 통과 | 실패 시 |
|---|---|---|
| `memory.outcomeCounts.COMMITTED` ÷ `paidAttempts` | 80% 이상 | 가장 많은 실패 사유부터 |
| `maxConsecutivePaidFailures` | ≤ 1 | 같은 입력으로 같은 실패가 되풀이되는 것 |
| `NOT_STOP`의 `failureDetails` | `MAX_TOKENS` 0 | 사고 수준·예산 |
| `STATE_REJECTED` 사유 | 없음 | 지시문과 검증 규칙 |
| `requestsByWorkload.MEMORY.thoughtsTokensMax` ÷ 예산 | 96% 미만 | 사고 수준 |
| `prompt.digestStateTokens` 추이 | 3,000에 가까워지지 않음 | 규칙 누적 — `droppedLoopRules` 확인 |
| `droppedLoopRules` | 0 또는 드묾 | 상태·규칙 분리(5계층 검토의 M4) |
| 캐시 `SHRUNK`·`FINGERPRINT_CHANGED` | 켜기 전과 같음 | M3가 캐시를 흔드는지 |

---

## 7. 작업 순서

각 단계는 따로 커밋하고, 단계마다 `swift build`와 해당 검사를 돌린다.

- [ ] **1. 순수 규칙** — `ThreeLayerMemory.swift` + `ThreeLayerMemoryTests.swift`. 앱 동작 변화 없음.
- [ ] **2. 자료형** — `ConversationDigest`·`ConversationSegment` 확장, 옛 파일·옛 자료형 호환 검사. 동작 변화 없음.
- [ ] **3. 원자적 저장** — `ChatRoomManager.flushPendingSave`, `commitMemory` + 검사. 아직 부르는 곳 없음.
- [ ] **4. 계획 인자** — `ConversationCompactor.plan(renderDigest:)`. 기본값 nil이라 동작 변화 없음.
- [ ] **5. 결과 분류** — `DigestOutcome`에 폰 갈래 추가, `observeDigest(droppedLoops:)`.
- [ ] **6. 생성 경로** — `GeminiService+Memory.swift`. 기능 스위치 **꺼진 채로** 넣는다.
- [ ] **7. 요청 경로 연결** — 4.6. 스위치 꺼짐. 측정 분리(`parts`) 연결.
- [ ] **8. 변환** — Q1 결정대로.
- [ ] **9. 시험 빌드로 실기기 확인** — 5.3.
- [ ] **10. 스위치 켜기 + 설치** — 10장 방식. 커밋 메시지에 켠 시각을 적는다(측정 구간 구분용).
- [ ] **11. 판정** — 6장. 몇 차례 압축 뒤.
- [ ] (선택) 요약 보기 화면.

**SingleChatRoomView.swift는 건드리지 않는다**(메인 체크아웃에 미커밋 작업이 있다). 이 설계는 그 파일을 고칠 필요가 없다.

---

## 8. 열린 질문 (착수 전 사용자 확인)

| # | 질문 | 권장 |
|---|---|---|
| Q1 | 옛 기억 변환: A(전부 다시 요약) / B(그대로 두고 M3만 새로) | **B + 첫 체크포인트에 기존 구간 참고** |
| Q2 | 3계층을 맥의 **모든 챗봇 방**에 켤지, 먼저 **한 방**에만 켤지 | 한 방(`5E0B692E`)부터 |
| Q3 | 3계층 방이 80턴 아래로 줄면 요약을 유지할지(폰 방식) | 폰 방식으로 맞춤 |
| Q4 | 맥 시험용 빌드(다른 번들 ID로 나란히 설치)를 만들지 | 만든다. 실제 앱을 건드리지 않고 시험할 수단이 없다 |
| Q5 | 요약을 나중에 기기 사이에 동기화할 계획이 있는지 | 있으면 해시 규칙을 지금 폰과 맞춘다 |

---

## 9. 확인 명령

### 9.1 맥 측정 (G1)

```bash
F="$HOME/Library/Application Support/KakaoSapiens/optimization_measurements.json"
grep -o '"memory":{[^}]*"outcomeCounts":{[^}]*}' "$F" | head -3
grep -o '"maxConsecutivePaidFailures":[0-9]*' "$F"
grep -o '"failureDetails":{[^}]*}' "$F"
```

### 9.2 폰 측정 (G2)

무선 디버깅 연결 뒤(`adb mdns services` → `adb connect <주소>`):

```bash
adb shell "run-as com.sapiens.gagaodok.claude cat files/KakaoSapiens/optimization_measurements.json" \
  | grep -o '"committed":[0-9]*\|"maxConsecutivePaidFailures":[0-9]*'
```

`committed`는 회차마다 있으므로 09-10 이후 회차의 합을 본다(run 9에서 4).

### 9.3 맥 데이터 백업 (G4)

```bash
ditto "$HOME/Library/Application Support/KakaoSapiens" \
  "$HOME/Desktop/KakaoSapiens-data-backup-$(date +%Y%m%d-%H%M)"
```

---

## 10. 맥 설치 방식 (현재)

메인 체크아웃에 커밋되지 않은 말풍선·Mermaid 작업이 있고, 설치된 맥 앱은 그것까지 포함한다.
이 브랜치로만 빌드하면 그 작업이 빠진다. 그래서:

1. 메인 체크아웃을 임시 폴더로 복사(`.build`·`.git`·`android`·`cloudflare`·`reference`·`docs`·`node_modules` 제외).
2. `git -C ~/Desktop/gagaodok-phone-30m-claude diff 9e92468 <HEAD> -- Sources Tests`를 적용.
3. 그 폴더에서 `swift build -c release` → 앱 정상 종료(`osascript ... quit`) → `bash build_app.sh`.
4. `codesign --verify --deep --strict /Applications/가가오독.app`, 실행 파일에 새 문자열이 있는지, Mermaid 리소스가 있는지.
5. **실행 여부는 영문 경로로 확인한다** — `pgrep -f "Contents/MacOS/KakaoSapiens"`.
   macOS가 한글 경로를 자모 분리형으로 넘겨서 한글로 검색하면 못 찾는다(09-16에 이것 때문에 앱을 두 번 띄웠다).

그 작업이 커밋되면 이 방식은 필요 없다.

---

## 11. 관련 기록

| 커밋 | 내용 |
|---|---|
| `2cba80a` | 맥: 고른 모델로 대화, 요약 사고 low·재시도 대기, 요금 계산 |
| `89f68f4` | 맥: 측정 장부(폰과 같은 형식) |
| `d0bbf6c` | 폰·맥: 요청 간격 15분 경계 |
| `a972808` | 맥: 재생성 보호 |
| `3f02c0f` | 폰: 측정 기록 잠금 복구 |

| 문서 | 내용 |
|---|---|
| `docs/2026-09-16-cache-result-and-watchpoints-claude.md` | 폰 캐시 작업 실측과 관찰 시점 |
| `docs/2026-09-15-cache-preservation-handoff-claude.md` | 폰 캐시 작업 전체와 청구서 분석 |
| `~/Desktop/ClaudeCode/docs/2026-09-04-three-layer-memory-validation.md` | 3계층 효율 검증(코덱스, 미추적) |
| `docs/2026-09-15-five-layer-memory-local-retrieval-review.md` | 5계층 검토(코덱스, 미추적). M3/M4 분리는 그 뒤 단계 |
