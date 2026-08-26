# 가가오독 크로스 디바이스 대화 동기화 제안서 (r2)

> **문서 상태:** 이 문서는 검토 과정의 중간 산출물로 동결되었다. 최종 기술 합의는 [CROSS_DEVICE_SYNC_AGREEMENT.md](CROSS_DEVICE_SYNC_AGREEMENT.md)를 따른다.

## 문서 상태

- 작성일: 2026-08-26
- 상태: **교차검증 완료 개정판 / 구현 승인 아님**
- 원본: [2026-08-26-cross-device-sync-proposal.md](2026-08-26-cross-device-sync-proposal.md) — 검토 요청 당시 문서로 보존하며, 이 문서가 이를 대체한다.
- 검토: Claude Code와 Codex가 여러 라운드에 걸쳐 상호 교차검증했다. 아래 내용은 양쪽이 합의한 결론이며, 코드 근거가 있는 항목은 파일·행을 명시했다.
- 판정: **조건부 승인, 구현 착수 보류.** Phase 0~4의 설계·합성 데이터·read-only prototype은 진행 가능하다. 실데이터 업로드와 양방향 동기화는 아래 게이트를 통과하기 전에는 시작하지 않는다.
- 이 문서를 작성하며 앱 코드, 로컬 대화 데이터, Cloudflare 리소스는 변경하지 않았다.

## 0. 원본에서 유지되는 것

원본의 다음 부분은 검토에서 타당성이 확인되었으며 그대로 유효하다.

- §2 사용자 요구사항 전체 (세 앱 경험 유지, 폰의 출처 탭, 기본 `폰` 탭, Mac·태블릿 방의 양방향, 폰 방의 비공개, 이름 자동 병합 금지, local-first, 무손상 우선)
- §4 설계 원칙 10개
- §6 폰 UI 제안 (고정 출처 탭, `전체` 탭 제외, 친구 탭은 1단계에서 폰 출처만)
- §13 Phase 0~7의 단계적 도입 순서
- §14 Rollback 원칙

원본 §8.4의 Cloudflare 무료 한도 서술은 아래 §3에서 보완한다.

## 1. r1 대비 무엇이 바뀌었나

| 영역 | r1 | r2 |
| --- | --- | --- |
| 메시지 식별자 | `(space_id, room_id, message_id)` | `(space_id, room_id, worldline_id?, turn_id, bubble_order, message_id)` |
| 첨부·아바타 | R2를 Phase 7 선택 기능으로 유보 | Phase 3 이전 확정 필수. 현재 구조로는 Shadow Upload가 실패한다 |
| checkpoint 버전 | `compactionVersion: 1` 단일 숫자 | `checkpointSchemaVersion` / `compactionProfileId` / `compactionContractFingerprint` 3단 분리 |
| 로컬 확정 | "로컬에 먼저 확정 후 outbox 기록" | durable journal 필요. 로컬 쓰기 성공이 관측 가능해야 함 |
| 필드 갱신 | "전체 room PUT 금지, patch 사용" | `base_revision` + 명시적 `set`/`clear` 연산. 기존 저장 codec은 건드리지 않음 |
| Shadow Upload 무해성 | "복사만 한다" | 일반 메시지 로더는 읽기만 해도 파일을 다시 쓴다. 전용 비파괴 importer 필요 |
| 세계선 | Phase 7 선택 기능 | 저장 스키마의 축. Phase 1 canonical schema에 nullable로 포함하거나 Phase 3에서 명시적으로 제외 |
| AI 생성 주체 | 미정의 | Phase 5 이전 확정 필수 |

## 2. 교차검증으로 확인된 코드 사실

아래는 설계 판단의 근거이며, 모두 현재 코드에서 확인했다.

### 2.1 플랫폼 간 모델 차이

Android에만 있고 Mac에는 없는 필드:

| 위치 | 필드 |
| --- | --- |
| [ChatRoom.kt:132](../android/app/src/main/java/com/sapiens/gagaodok/model/ChatRoom.kt) | `RoomProfile.baseAffection` |
| [ChatRoom.kt:158](../android/app/src/main/java/com/sapiens/gagaodok/model/ChatRoom.kt) | `ChatRoom.groupChat` |
| [ChatRoom.kt:48,50](../android/app/src/main/java/com/sapiens/gagaodok/model/ChatRoom.kt) | `PersonaStyle.suppressedExpressions`, `sampleEvidence` |
| [Message.kt:89-95](../android/app/src/main/java/com/sapiens/gagaodok/model/Message.kt) | `speakerRoomId`, `reactions`, `heartChanges` |

Swift `Codable`은 알 수 없는 키를 조용히 무시하고 디코딩하므로, Mac이 Android JSON을 읽고 다시 쓰면 위 필드는 실제로 소실된다. Android의 [Codec.kt](../android/app/src/main/java/com/sapiens/gagaodok/model/Codec.kt)도 `ignoreUnknownKeys = true`인데, 이는 보존이 아니라 **읽을 때 무시하고 다시 저장할 때 제거**한다는 뜻이다.

`MessageKind`(SPEECH/NARRATION)는 양쪽에 모두 있으므로 Android 전용이 아니다.

### 2.2 저장 구조

- 대화 저장의 실제 범위는 Android에서 `(roomId, worldlineId?)`이다. 파일명이 `room_<R>_worldline_<W>_messages.json`으로 갈린다. [ConversationScope.kt:5](../android/app/src/main/java/com/sapiens/gagaodok/data/ConversationScope.kt)
- 방 조회는 room UUID 단일 키다. [ChatStore.kt:79](../android/app/src/main/java/com/sapiens/gagaodok/data/ChatStore.kt), [ChatRoom.swift:416](../Sources/KakaoSapiens/Models/ChatRoom.swift)
- 캐시·검색 색인·토큰 사용량 장부도 room UUID만 키로 쓴다.

따라서 Phase 4의 read-only replica는 **별도 폴더·별도 store**에 두어야 안전하다. Phase 5에서 기존 `ChatStore`에 섞으려면 composite key 또는 space별 저장 루트가 필요하다.

### 2.3 저장 원자성

- 메시지 저장은 양쪽 모두 0.7초 모았다가 비동기로 기록한다. [ChatRoom.swift:466](../Sources/KakaoSapiens/Models/ChatRoom.swift), [ChatStore.kt:257](../android/app/src/main/java/com/sapiens/gagaodok/data/ChatStore.kt)
- **정상 종료 경로는 이미 처리되어 있다.** Mac은 [applicationWillTerminate](../Sources/KakaoSapiens/App/KakaoSapiensApp.swift), Android는 [onStop](../android/app/src/main/java/com/sapiens/gagaodok/MainActivity.kt)에서 flush한다.
- 따라서 위험은 크래시·강제 종료·전원 차단·저장 직전 프로세스 사망으로 좁혀진다. 그래도 양방향 동기화에는 durable journal이 필요하다.
- **쓰기 실패가 무음이다.** [ChatStore.kt:298,306,432](../android/app/src/main/java/com/sapiens/gagaodok/data/ChatStore.kt)의 `tmp.renameTo(file)`은 반환값을 버리고, `runCatching`은 예외만 잡는데 `renameTo`는 실패 시 예외 대신 `false`를 돌려준다. `.tmp`가 남고 원본은 옛 내용 그대로인데 호출자는 성공으로 믿는다.

### 2.4 읽기가 파일을 다시 쓴다

[ChatRoom.swift:449](../Sources/KakaoSapiens/Models/ChatRoom.swift)의 `loadMessagesForRoom`과 [ChatStore.kt:237](../android/app/src/main/java/com/sapiens/gagaodok/data/ChatStore.kt)의 `loadMessages`는 디코딩 후 `migrateLegacyTurns`를 실행하고, 변환이 발생하면 같은 파일을 다시 저장한다. 발동 조건은 **메시지 하나라도 `turnId == nil`인 경우**다.

정확한 표현은 "현재 코드로는 비파괴 읽기가 불가능하다"가 아니라 **"현재의 일반 메시지 로더를 비파괴 읽기 경로로 사용할 수 없다"**이다. 파일 URL은 접근 가능하므로 원시 바이트를 직접 읽는 전용 importer를 만들 수 있다.

### 2.5 턴과 말풍선

- 같은 AI 응답에서 갈라진 말풍선은 하나의 `turnId`를 공유하고, 분리 전 원문은 `canonicalText`에 담긴다. [Message.swift:184,186](../Sources/KakaoSapiens/Models/Message.swift), [Message.kt:82,84](../android/app/src/main/java/com/sapiens/gagaodok/model/Message.kt)
- **말풍선 순서를 담는 필드가 없다.** 순서는 오직 배열 위치로만 존재한다. 관계형 저장소는 행 순서를 보장하지 않으므로 명시적 순서 키를 새로 만들어야 한다.
- 턴 번호는 저장값이 아니라 읽을 때마다 재계산된다. digest의 `firstTurn`/`lastTurn`은 그 재계산된 위치 정수다. 메시지가 빠지거나 순서가 흔들리면 이후 모든 턴 번호가 밀려 **기존 digest가 조용히 엉뚱한 구간을 가리킨다.**
- 묶는 방식이 두 가지이고 서로 다르다.
  - [`ConversationTurn.from()`](../Sources/KakaoSapiens/Models/Message.swift): 인접성 **+ turnId 경계 검사** (양쪽이 모두 non-null이고 다를 때만 절단)
  - [`migrateLegacyTurns()`](../Sources/KakaoSapiens/Models/ChatRoom.swift): **순수 인접성만**, 그 범위 전체의 `turnId`를 무조건 덮어씀
- 따라서 nil과 유효값이 섞인 파일에서는 마이그레이션이 **유효했던 `turnId`를 파괴하고 `canonicalText`를 합칠 수 있다.**
- 마이그레이션이 부여하는 `turnId`는 [`UUID()`](../Sources/KakaoSapiens/Models/ChatRoom.swift) / [`UUID.randomUUID()`](../android/app/src/main/java/com/sapiens/gagaodok/data/ChatStore.kt)로 뽑는 무작위 값이다. 같은 옛 대화라도 기기마다 다른 값이 붙는다.
- **단톡방에서 화자가 바뀌어도 턴은 하나다.** [playGroupBubbles](../android/app/src/main/java/com/sapiens/gagaodok/ui/screens/ChatRoomViewModel.kt)는 `turnId`를 하나만 받아 모든 말풍선에 적용한다. `speakerRoomId`는 말풍선 메타데이터이지 턴 경계가 아니다.

### 2.6 엔진 분기

- `BuildConfig.TABLET_MENTOR`는 Android 소스 **9개 파일 16곳**에서 쓰인다. 서비스뿐 아니라 ViewModel과 UI에도 퍼져 있다.
- 호감도 활성 조건은 `personalAffectionEnabled = protocol == null && mode == COMPANION && model == GEMINI_37_FLASH && !TABLET_MENTOR`이며, 그 결과가 **실제 system prompt를 바꾼다.** [ChatRoomViewModel.kt:407](../android/app/src/main/java/com/sapiens/gagaodok/ui/screens/ChatRoomViewModel.kt) 즉 (flavor × mode × model) 세 입력의 함수인데, 그중 mode와 model은 동기화되고 flavor는 되지 않는다.
- `companionRepetitionControlEnabled`는 저장 필드가 아니라 [promptSection의 인자](../android/app/src/main/java/com/sapiens/gagaodok/model/ChatRoom.kt)이며 [매 호출마다 BuildConfig에서 계산](../android/app/src/main/java/com/sapiens/gagaodok/service/AIService.kt)해 넘긴다. 동기화할 대상 자체가 없다.

### 2.7 압축 정책이 플랫폼·모드마다 다르다

| | threshold | verbatim | refresh | segment budget | maxOutputTokens | 요약 지침 |
| --- | --- | --- | --- | --- | --- | --- |
| Mac 멘토 | 60 | 20 | 40 | 1200 | 2400 | Mac 멘토판 (소제목 7개, `교재 및 문서` 절 포함) |
| Mac 챗봇 | 80 | 30 | 50 | 1500 | 2700 | Mac 챗봇판 |
| Android 전 모드 | 80 | 30 | 50 | 1500 | 2700 | 모드로만 분기 (멘토판 소제목 6개, 사진 설명만) |

근거: [ConversationCompactor.swift:52-88](../Sources/KakaoSapiens/Services/ConversationCompactor.swift), [ConversationCompactor.kt:52-81](../android/app/src/main/java/com/sapiens/gagaodok/service/ConversationCompactor.kt), [GeminiService+Digest.swift:53](../Sources/KakaoSapiens/Services/GeminiService+Digest.swift), [AIServiceDigest.kt:82](../android/app/src/main/java/com/sapiens/gagaodok/service/AIServiceDigest.kt)

**Android 멘토는 "Mac 멘토 지침 + 챗봇 상수"가 아니라 지침 본문·상수·출력 한도가 모두 다른 독립 profile이다.** 모델과 thinking 설정(`thinkingLevel: low`)은 양쪽 동일하다.

또한 `ConversationDigest`/`ConversationSegment` 어디에도 **어떤 정책으로 만들어졌는지 기록하는 필드가 없다.** 그리고 상수는 과거에 이미 바뀐 적이 있다 — 양쪽 주석이 챗봇 threshold를 150에서 80으로 낮춘 이력을 남기고 있다.

### 2.8 Prefix cache

| | Mac | Android |
| --- | --- | --- |
| TTL | 900초 | 900초 |
| 최소 생성 토큰 | 1200 | 4600 |
| fingerprint | `.sortedKeys`로 정렬 후 SHA-256 | `JSONObject` 삽입 순서 그대로 SHA-256 |

근거: [GeminiService+PrefixCache.swift:80,83,265](../Sources/KakaoSapiens/Services/GeminiService+PrefixCache.swift), [AIServicePrefixCache.kt:33,37,263](../android/app/src/main/java/com/sapiens/gagaodok/service/AIServicePrefixCache.kt)

Android 쪽 코드 주석이 *"contents를 만드는 코드가 한 곳뿐이라 같은 대화면 같은 문자열이 나옵니다"*라고 적어 두었다 — **단일 구현 내에서만 유효한 지문임을 코드가 스스로 밝히고 있다.** 현재 구현은 교차 플랫폼 호환이 이미 깨져 있으므로, 새 계약의 구현 본으로 삼아서는 안 된다.

### 2.9 첨부와 아바타

- 첨부는 양쪽 모두 `dataBase64`로 JSON에 인라인 저장한다.
- Android는 12MB 상한이 있다. [ChatRoomInputBar.kt:591](../android/app/src/main/java/com/sapiens/gagaodok/ui/screens/ChatRoomInputBar.kt) base64 변환 후 약 16MB가 된다.
- **Mac에는 명시적 크기 상한이 없다.**
- 아바타는 JSON이 아니라 `avatar_<UUID>.png` 별도 파일이다. [ChatRoom.swift:334](../Sources/KakaoSapiens/Models/ChatRoom.swift) 파일 본문 없이 파일명만 동기화하면 폰 read-only 탭에 아바타가 뜨지 않는다.

## 3. Cloudflare 무료 한도 (보완)

원본 §8.4는 계정 총량만 적었다. 세 수치를 모두 기록한다.

- Workers Free: 100,000 requests/day, 10ms CPU/invocation
- D1 Free: **DB 하나당 500MB**, **계정 총 5GB**, **행·문자열·BLOB당 2MB**

첨부 문제는 총량이 아니라 **행당 2MB 한도에서 먼저 터진다.** 16MB 행은 어떤 합리적 한도도 넘는다.

## 4. 수정된 canonical 식별 계약

```text
message identity = (space_id, room_id, worldline_id?, turn_id, bubble_order, message_id)
```

- `worldline_id`는 nullable 축이다. 기능이 아니라 **저장 스키마의 차원**이므로, Phase 1 schema에 포함하거나 Phase 3 업로드 대상에서 명시적으로 차단해야 한다. 나중에 추가하면 이미 올라간 메시지의 기본키를 바꿔야 한다.
- `bubble_order`는 새로 만들어야 한다. 현재 순서는 배열 위치로만 존재한다.
- `speakerRoomId`는 bubble metadata로 보존하되 턴 경계로 사용하지 않는다.

### 4.1 legacy turn_id 결정적 계산 규칙

기기별 무작위 발급을 금지하고, importer에서 다음과 같이 계산한다. 원본 JSON은 수정하지 않는다.

1. `turnId`가 있으면 그 값을 최우선으로 보존하고, **정확히 같은 `turnId`끼리만** 묶는다.
2. `turnId == nil`인 AI 말풍선은 **연속된 nil 구간만** 묶는다. 유효 `turnId`가 나타나는 즉시 경계를 끊는다.
3. nil 구간의 결정적 ID는 첫 말풍선의 `message.id`로 계산한다.
4. `speakerRoomId`는 보존하되 턴 경계로 쓰지 않는다.
5. 사용자 메시지는 각각 자기 `message.id`를 legacy turn ID로 쓴다.

이 규칙은 이미 `ConversationTurn.from()`이 `turnId ?? first.id`로 동작하는 것과 일치하며, 반복 업로드가 항상 같은 결과를 낸다.

## 5. Checkpoint 버전 3단 분리

단일 `compactionVersion: 1`은 서로 다른 정책을 같은 번호로 덮어 호환성 판정을 불가능하게 만든다. 다음 셋으로 나눈다.

| 필드 | 성격 | 예 |
| --- | --- | --- |
| `checkpointSchemaVersion` | JSON 구조 버전 | `1` |
| `compactionProfileId` | 사람이 관리하는 정책 식별자 | `mac-mentor-v1`, `mac-companion-v1`, `android-mentor-v1` |
| `compactionContractFingerprint` | 자동 계산되는 기계 판정용 해시 | `sha256(...)` |

fingerprint 입력에 최소한 다음이 들어간다.

- 실제 런타임 summary instruction 본문
- threshold, verbatim window, refresh period
- segment token budget과 실제 `maxOutputTokens`
- transcript 포맷 버전
- 모델과 thinking 설정
- checkpoint 범위 계산 알고리즘 버전

**canonical serialization과 UTF-8·줄바꿈 규칙을 문서에 명시한다.** 현재 prefix cache 구현은 플랫폼 간 직렬화가 달라 이미 호환이 깨져 있으므로 개념적 선례로만 인용하고 구현을 재사용하지 않는다.

호환성 게이트에서는 **거짓 불일치(공유 안 함)가 거짓 일치(잘못된 공유)보다 안전**하므로, 공백 수정으로 fingerprint가 갈리는 것은 감수한다.

### 5.1 기존 무버전 digest

버전 없는 기존 digest는 현재 profile로 추정하지 않고 `legacy_unversioned`로 취급한다. 근거는 "과거에 상수가 바뀐 적이 있다"가 아니라 **"어느 digest가 어느 정책에서 나왔는지 구별할 방법이 없다"**이다. 다음 중 하나를 선택한다.

1. opaque summary로 읽기만 하고 새 segment는 덧붙이지 않는다
2. 원본 메시지에서 새 profile로 checkpoint를 재생성한다
3. 해당 source space의 원래 기기만 이어서 생성하게 제한한다

이 조건은 일반 메시지만 복사하는 Phase 3 자체를 막지 않는다. 다만 (1) 기존 digest를 canonical checkpoint로 업로드할 때 (2) 여러 기기가 checkpoint를 이어서 생성할 때 (3) Android 압축 상수를 통일하거나 변경할 때는 반드시 선행되어야 한다.

## 6. Patch 규격

전체 room/message PUT을 금지한다. 저장 codec은 그대로 두고 **동기화 전용 DTO**를 만든다.

```json
{
  "base_revision": 41,
  "set": { "statusMessage": "새 상태" },
  "clear": ["avatarImageFileName"]
}
```

- Android codec의 `explicitNulls = false`와 Swift의 `decodeIfPresent(...) ?? false` 때문에 **저장된 JSON만 봐서는 "값 없음"과 "명시적으로 비움"을 구별할 수 없다.** 따라서 RFC 7396식 merge patch(= `null`이 삭제 명령)는 쓸 수 없다.
- `clear` 연산은 기존 snapshot과 비교해 만들거나, 사용자가 값을 지우는 순간 outbox에 직접 기록한다. 어느 방식이든 충돌 검출을 위해 `base_revision`이 필요하다.
- 서버는 플랫폼이 모르는 확장 필드를 opaque extension으로 보존한다.

## 7. 기기별 상태와 canonical 상태 분리

다음은 canonical schema에서 제외하거나 `device_room_state`로 분리한다.

| 필드 | 성격 |
| --- | --- |
| `unreadCount`, `isUnread` | 기기별 상태 |
| `deliveryFailed` | 해당 기기의 전송 상태 |
| `lastMessageText`, `lastMessageTime` | 메시지에서 계산 가능한 파생값 |
| `isPinned` | 기기별 UI 설정 |
| `avatarImageFileName` | 파일 본문 없이는 의미 없음 |

## 8. Phase 0 inventory 지표

원문은 출력하지 않고 개수만 센다.

- `hasNilTurnId` 파일 수
- `hasValidTurnId` 파일 수
- 연속 AI 구간별 서로 다른 non-null `turnId` 수
- `hasNilTurnId && distinctValidTurnIdsInAiRun > 1`인 **즉시 위험 파일 수**
- `speakerRoomId` 포함 파일 수 (통계용, 턴 경계에는 사용하지 않음)
- 연속 AI 구간 내 최대 인접 timestamp 간격 — 임계값(예: 60초) 초과 건수
- 첨부 포함 메시지 수와 base64 크기 분포
- 세계선 파일 수와 단톡방 방 수

### 8.1 지표 해석 주의

**"서로 다른 유효 `turnId`가 0건이면 훼손된 적이 없다"는 판단은 성립하지 않는다.** 마이그레이션은 연속 AI 구간의 모든 `turnId`를 같은 값으로 덮으므로, 훼손이 일어난 뒤에는 오히려 0건이 되고 nil도 남지 않는다. 훼손이 자기 증거를 지운다.

- 2개 이상 남아 있음 → 현재는 구분이 **보존되어 있음**. 같은 파일에 nil도 있으면 다음 일반 로드에서 훼손될 위험이 있음
- 없음 → 정상적인 단일 응답 / 전체 legacy nil / 이미 덮어써진 파일을 구별할 수 없음

과거 훼손 여부는 마이그레이션 전 backup과 대조하지 않으면 `unknown`으로 분류한다.

timestamp 간격 지표는 마이그레이션이 timestamp를 건드리지 않는다는 점을 이용한다. 한 응답 안의 말풍선은 약 0.45초 간격으로 붙으므로, 연속 AI 구간 안의 큰 간격은 병합 흔적일 수 있다. 다만 지연된 정상 응답이 거짓 양성으로 잡히고 짧은 간격의 두 응답은 놓치므로, **훼손을 증명하는 용도가 아니라 `unknown` 집합을 좁혀 확인 대상을 추리는 용도**다.

연속 AI 구간에 서로 다른 `turnId`가 생길 수 있는 **코드 경로가 실제로 존재하는지**도 함께 기록한다. 그래야 위험 파일 0건이 "증거 소실"인지 "애초에 발생 불가"인지 구별된다.

## 9. 개정된 게이트

### 9.1 Phase 3 (실데이터 Shadow Upload) 이전 확정

1. **첨부·아바타 정책** — R2로 분리하거나, 초기에는 본문을 제외하고 해시·이름·크기·"이 기기에서 열 수 없음" 표시만 동기화한다. 아바타 파일도 함께 결정한다.
2. **식별 계약** — `(space, room, worldline?, turn, bubble order, message)`
3. **E2EE 적용 여부** — §10 참조
4. **그룹·세계선 포함 또는 명시적 제외 결정**

acceptance test:

- 비파괴 importer 검증: 원본 **바이트·mtime·hash가 전후 동일**
- legacy `turn_id` 결정적 계산 및 동결 규칙 (§4.1). 기기별 무작위 발급 금지
- Phase 0 혼합 세대 계수 (§8)

### 9.2 Phase 5 (양방향) 이전 확정

1. **durable outbox/journal** — 로컬 확정과 outbox 기록의 원자성. 시작 시 재조정 절차. D1 쓰기는 `operation`·`message`·`change_log`를 하나의 `batch()` 트랜잭션으로 처리
2. **로컬 commit 성공 관측** — `renameTo` 무음 실패를 포함해, 로컬 쓰기 실패가 호출자에게 전달되어야 한다
3. **AI 생성 담당 기기와 동시 작성 정책** — `base_turn_id`, 생성 권한 또는 방별 generation lease. 초기에는 "텍스트만 있는 멘토 테스트방 + 한 번에 한 기기만 작성 + 명시된 생성 담당 기기"로 제한
4. **local/canonical 필드 분류** (§7)
5. **삭제를 표현할 patch 규격** (§6)
6. **compactor·cache 교차 contract test**

### 9.3 동기화와 분리된 결정

**Android compaction 상수 통일 여부.** 동기화 구현 과정에서 슬쩍 통일하면 기존 Android 대화의 압축 시점·비용·기억 범위가 바뀐다. 별도 검증 없이 변경하지 않는다. 단, 통일을 결정하기 **전에** §5의 3단 버전 구조가 먼저 들어가야 한다. 지금 versioning이 없으면 통일 전후 digest를 사후에 구별할 방법이 사라진다.

## 10. 미결정 항목 (원본 §17)

제품 판단이 필요한 항목은 임의로 확정하지 않는다.

| # | 항목 | 권고 | 근거 | 결정 상태 | 연결 게이트 |
| --- | --- | --- | --- | --- | --- |
| 1 | 폰 전용 방도 D1에 backup할지 | backup하되 phone space 권한으로 숨김 | 저장과 노출은 분리된 정책. 기기 분실 시 복구 가치 | **결정 필요** | Phase 3 |
| 2 | Mac 방을 태블릿에서도 볼지 | 아니요 | 현재 요구사항에 없음. space 권한 표만 넓히면 됨 | 권고 유지 | — |
| 3 | 폰의 Mac·태블릿 탭에서 새 방 생성 허용 | 아니요, 이어가기만 | 새 방은 engine profile 결정 주체가 모호해짐 | 권고 유지 | Phase 5 |
| 4 | 친구 탭에도 출처 탭 추가 | 아니요 | 친구 목록·단톡방 참여자·즐겨찾기 동시 재설계를 피함 | 권고 유지 | — |
| 5 | shared room engine profile 동일 보장 수준 | capability 부족 시 읽기 전용. 조용한 fallback 금지 | flavor 분기가 9개 파일 16곳에 퍼져 있어 완전 재현은 큰 작업 (§2.6) | **결정 필요** | Phase 5 |
| 6 | shared room에 호감도 도입 | 아니요 (`relationshipPolicy = none`) | 폰만 아는 호감도가 prompt를 바꾸면 Mac·태블릿이 같은 방을 이어갈 때 행동이 달라짐 (§2.6) | 권고 유지 | Phase 5 |
| 7 | historical data 업로드 전 E2EE 적용 | — | 나중에 덧붙이면 기존 데이터를 재암호화해야 함. **원본은 이 결정을 §19 게이트와 Phase 7에 모순되게 배치했다** | **결정 필요 — Phase 3 차단** | Phase 3 |
| 8 | 세 기기가 동일 Gemini credential scope를 쓸지 | 실험으로 확인 | 키 문자열이 아니라 project·인증 identity·권한 범위가 기준 | **결정 필요** | Phase 7 |
| 9 | polling만으로 시작할지 WebSocket을 함께 넣을지 | polling으로 시작 | WebSocket은 알림용이며 데이터 원본이 아님. cursor 기반 pull로 복구 가능해야 함 | 권고 유지 | Phase 7 |
| 10 | message edit·delete 허용 phase | Phase 5에서는 비활성화, 별도 test room에서만 | revision 충돌과 tombstone 전파를 기본 sync와 분리 | 권고 유지 | Phase 5 |

### 10.1 E2EE 모순 (원본 결함)

원본 §19 게이트는 *historical data 업로드 전* 결정을 요구하는데 그 업로드는 Phase 3이고, 원본 Phase 7은 *"기본 sync 안정 후 별도 결정"*이라 Phase 6 뒤다. **결정 시점이 Phase 3 이전과 Phase 6 이후로 갈린다.** r2는 이를 Phase 3 게이트로 통일한다. 선택은 둘 중 하나여야 한다.

- **E2EE 사용**: Phase 1에서 암호화 envelope·키 버전·복구 정책을 설계하고 Shadow Upload도 암호화한다
- **E2EE 미사용**: Cloudflare에 평문 저장되는 위험을 명시적으로 승인한다

### 10.2 credential scope 실험 설계

키 값을 로그에 남기지 않고 다음 순서로 확인한다.

1. A credential로 cache 생성
2. cache name만 기록
3. B credential로 해당 cache name을 직접 `get` 또는 `generateContent`에 사용
4. 같은 project의 다른 key, 다른 project의 key를 각각 비교

**fingerprint 경로를 우회해 cache name을 직접 사용해야 한다.** 현재 구현은 플랫폼 간 지문이 먼저 어긋나므로(§2.8), 그대로 두면 project 공유 여부와 무관하게 항상 미스가 난다.

## 11. 별도 코드 결함

동기화 설계와 무관하게 이미 존재하는 결함이며, 별도 작업으로 처리한다. 다만 §9.2의 acceptance test와도 연결된다.

- **`renameTo` 무음 실패** — [ChatStore.kt:298,306,432](../android/app/src/main/java/com/sapiens/gagaodok/data/ChatStore.kt). 반환값 미확인
- **Android 멘토 압축 정책** — Mac 멘토와 지침·상수·출력 한도가 모두 다름 (§2.7). 의도인지 백포트 누락인지 확인 필요

## 12. 결론

r1의 방향(세 앱 통합이 아니라 출처 공간·공통 data contract·local-first sync·안전한 migration의 추가)은 유효하다. 설계 원칙도 코드 구조와 잘 맞는다.

바뀐 것은 **"무엇을 먼저 확정해야 하는가"**다. r1은 첨부·checkpoint 버전·세계선·생성 주체를 뒤 단계 선택 기능으로 미뤘는데, 이들은 모두 데이터를 한 번 올리고 나면 되돌리는 비용이 급격히 커지는 항목이다. r2는 이를 Phase 3·Phase 5 게이트로 끌어올렸다.

권장 순서는 유지한다.

1. Contract와 rollback을 먼저 설계한다
2. 합성 데이터로 server와 adapter를 검증한다
3. 실제 데이터는 **비파괴 importer로** Shadow Sync 복사만 한다
4. 폰에서 read-only 출처 탭을 검증한다
5. 새 test room 하나만, 생성 담당 기기를 지정해 양방향으로 연다
6. 기존 방은 사용자 opt-in으로 하나씩 확장한다
7. engine checkpoint, cache lease, 호감도는 검증된 필요에 따라 순차 추가한다

기능은 작은 범위로 시작하되 데이터 안전과 호환성 규칙은 축소하지 않는다는 r1의 핵심은 그대로다.
