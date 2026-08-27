# 가가오독 크로스 디바이스 대화 동기화 제안서

## 문서 상태

- 작성일: 2026-08-26
- 상태: **검토 요청용 제안서 / 구현 승인 아님**
- 저장소: `/Users/dlgksdnf/Desktop/ClaudeCode`
- 대상: macOS 앱, Android phone flavor, Android tablet flavor, Cloudflare Workers·D1
- 목적: 기존 가가오독을 만든 다른 AI 에이전트가 요구사항 해석, 호환성 위험, 구현 범위와 단계적 도입 계획을 검토할 수 있게 한다.
- 이 문서를 작성하며 앱 코드, 로컬 대화 데이터, Cloudflare 리소스는 변경하지 않았다.

## 1. 한 문장 요약

세 앱을 하나로 합치지 않고 기존 로컬 저장을 유지한 채, 폰 앱에서 `폰 · Mac · 태블릿` 출처 탭으로 채팅방을 분리해 보여 주며, Mac·태블릿 출처의 채팅방은 폰과 원본 기기 사이에서 양방향 동기화하고 폰 출처 채팅방은 폰에만 노출하는 local-first 동기화 계층을 추가한다.

## 2. 사용자 요구사항: 현재 합의된 내용

### 2.1 제품 목표

1. macOS 앱, Android 폰 앱, Android 태블릿 앱은 계속 별도 앱 경험을 유지한다.
2. 앱을 하나로 합치거나 모든 플랫폼의 UI를 같게 만들지 않는다.
3. 폰 앱의 채팅 화면 상단에 카카오톡의 채팅 분류 탭과 유사한 출처 탭을 둔다.
   - 기본 탭: `폰`
   - 추가 탭: `Mac`, `태블릿`
4. `폰` 탭에는 폰에서 생성된 채팅방만 보인다.
5. `Mac` 탭에는 Mac에서 생성·관리되는 채팅방만 보인다.
6. `태블릿` 탭에는 태블릿에서 생성·관리되는 채팅방만 보인다.
7. 같은 이름의 캐릭터가 여러 출처에 존재해도 서로 다른 캐릭터로 취급한다.
   - 폰의 `마린`과 Mac의 `마린`은 병합하지 않는다.
   - 이름, 아바타, 말투가 같아도 자동으로 같은 캐릭터라고 추정하지 않는다.
8. Mac 채팅방을 폰에서 열고 이어서 대화하면 폰의 새 메시지와 AI 답변이 같은 Mac 채팅방에 들어가며 Mac에서도 동기화되어 보여야 한다.
9. 태블릿 채팅방도 8번과 동일하게 폰과 태블릿 사이에서 양방향 동기화한다.
10. 폰에서 새로 만든 폰 출처 채팅방은 Mac과 태블릿에 표시할 필요가 없다.
11. 네트워크가 없어도 각 앱은 기존 로컬 데이터로 계속 동작해야 한다.
12. 기존 세 기기의 로컬 데이터가 프로토타입이나 최초 migration 때문에 손상되어서는 안 된다.
13. Cloudflare 무료 요금제를 우선 사용한다.

### 2.2 동기화 방향을 정확히 표현한 표

| 채팅방 출처 | 폰에서 보기 | 폰에서 쓰기 | 원본 기기에서 폰의 새 내용 보기 | 다른 비원본 기기에서 보기 |
| --- | --- | --- | --- | --- |
| 폰 | 예 | 예 | 해당 없음 | 아니요 |
| Mac | 예 | 예 | Mac에서 예 | 태블릿에서는 기본적으로 아니요 |
| 태블릿 | 예 | 예 | 태블릿에서 예 | Mac에서는 기본적으로 아니요 |

향후 명시적인 `모든 기기` 공간을 추가할 수는 있지만 현재 요구사항에는 포함하지 않는다.

## 3. 현재 프로젝트에서 확인한 구조

### 3.1 코드베이스 수

겉으로는 세 버전이지만 실제 앱 코드는 두 코드베이스다.

- macOS Swift: `/Users/dlgksdnf/Desktop/ClaudeCode/Sources/KakaoSapiens`
- Android Kotlin: `/Users/dlgksdnf/Desktop/ClaudeCode/android/app/src/main/java/com/sapiens/gagaodok`
- Android 폰과 태블릿은 `/Users/dlgksdnf/Desktop/ClaudeCode/android/app/build.gradle.kts`의 product flavor와 `BuildConfig.TABLET_MENTOR`로 나뉜다.

따라서 동기화 client 구현은 Swift 1개와 Kotlin 1개가 기본이며, 폰 전용 출처 탭 UI와 flavor별 capability 차이가 추가된다.

### 3.2 현재 로컬 저장

- macOS는 Application Support의 JSON 파일에 방, 메시지, 대화 요약, 명시적 cache metadata를 저장한다.
- Android도 앱 files directory 아래 `KakaoSapiens` 폴더에 Mac과 호환되는 파일명·JSON 형식을 사용한다.
- UUID와 Swift 기준시 날짜 형식을 Android codec이 의도적으로 맞추고 있다.
- API key는 Mac Keychain과 Android 암호화 저장소에 따로 보관한다.

기존 저장을 제거하고 D1-only 구조로 교체하는 것은 이 제안의 범위가 아니며 권장하지 않는다.

### 3.3 플랫폼별 중요한 차이

Android에는 Mac 모델에 없는 데이터가 있다.

- 단체 대화와 참여자
- 세계선과 세계선별 대화·요약
- 개인·참여자 호감도
- 메시지 화자 ID, 반응, 호감도 변화
- 말투 억제 표현과 출처 evidence
- 일부 반복 표현 제어 정보

Mac이 Android JSON을 읽고 다시 encode하면 Mac이 모르는 필드를 제거할 수 있으므로 원본 JSON 파일 전체를 공유 드라이브처럼 동기화해서는 안 된다.

### 3.4 대화 엔진 차이

다음 구현이 Mac과 Android에 각각 존재하며 세 flavor에서 일부 조건이 다르다.

- 대화 request와 system prompt
- 멘토·챗봇 mode 분기
- 말투 조사·정제·미리보기
- 대화 압축과 구간 요약
- Gemini explicit prefix cache 생성·갱신·삭제
- 폰 전용 호감도·단톡방·세계선 로직

관련 중심 파일:

- `/Users/dlgksdnf/Desktop/ClaudeCode/Sources/KakaoSapiens/Services/GeminiService+Conversation.swift`
- `/Users/dlgksdnf/Desktop/ClaudeCode/Sources/KakaoSapiens/Services/ConversationCompactor.swift`
- `/Users/dlgksdnf/Desktop/ClaudeCode/Sources/KakaoSapiens/Services/GeminiService+PrefixCache.swift`
- `/Users/dlgksdnf/Desktop/ClaudeCode/Sources/KakaoSapiens/Services/GeminiService+Persona.swift`
- `/Users/dlgksdnf/Desktop/ClaudeCode/android/app/src/main/java/com/sapiens/gagaodok/service/AIServiceConversation.kt`
- `/Users/dlgksdnf/Desktop/ClaudeCode/android/app/src/main/java/com/sapiens/gagaodok/service/ConversationCompactor.kt`
- `/Users/dlgksdnf/Desktop/ClaudeCode/android/app/src/main/java/com/sapiens/gagaodok/service/AIServicePrefixCache.kt`
- `/Users/dlgksdnf/Desktop/ClaudeCode/android/app/src/main/java/com/sapiens/gagaodok/service/AIServicePersona.kt`

`BuildConfig.TABLET_MENTOR`가 AI service와 ViewModel 안에 직접 사용되는 부분은 폰 build가 태블릿 방의 동작을 runtime에 재현하는 것을 막는다. 완전한 동작 호환이 필요하다면 이 분기를 방별 engine profile로 옮겨야 한다.

### 3.5 실제 폰 UI 확인

2026-08-26 실제 Galaxy 기기에서 현재 phone 앱의 채팅 화면을 실행해 확인했다.

- 상단: `채팅` 제목, 검색, 새 채팅
- 본문: 아바타·이름·마지막 메시지·시각으로 구성된 채팅방 목록
- 하단: 친구·채팅·설정 navigation
- 같은 이름의 캐릭터가 이미 여러 행으로 존재할 수 있다.

출처별 구역을 이름 badge로 매 행에 표시하는 것보다, 제목 아래에 고정 출처 탭을 두는 것이 현재 UI와 사용자 요구에 더 잘 맞는다.

## 4. 설계 원칙

1. **Local-first**: 사용자 조작은 로컬에 먼저 확정하고 cloud sync는 후속 작업으로 처리한다.
2. **Cloud는 대체 저장소가 아니라 복제본·순서 조정자**다.
3. **이름으로 병합하지 않는다.** 식별자는 출처 공간과 UUID다.
4. **원본 메시지가 최종 사실**이다. 요약과 provider cache는 파생 상태다.
5. **모르는 필드를 제거하지 않는다.** 전체 객체 교체보다 versioned patch를 사용한다.
6. **기능 범위는 작게 시작하되 데이터 안전은 첫날부터 완성형으로 둔다.**
7. **지원하지 않는 동작을 조용히 다른 로직으로 실행하지 않는다.** capability가 부족하면 읽기 전용 또는 명시적 fallback을 사용한다.
8. **API key와 민감한 credential은 동기화하지 않는다.**
9. **삭제는 즉시 물리 삭제하지 않는다.** tombstone과 유예 기간을 둔다.
10. **migration 전 rollback을 먼저 증명한다.**

## 5. 핵심 도메인 모델

### 5.1 Source Space

출처별 독립 namespace를 둔다.

```text
PHONE_SPACE
MAC_SPACE
TABLET_SPACE
```

실제 schema에서는 enum 하나만 두기보다 `space_id`와 `space_kind`를 분리해 향후 Mac이나 태블릿이 여러 대가 되는 경우를 수용하는 편이 안전하다.

권한 기본값:

| 기기 | PHONE_SPACE | MAC_SPACE | TABLET_SPACE |
| --- | --- | --- | --- |
| 폰 | 읽기·쓰기 | 읽기·쓰기 | 읽기·쓰기 |
| Mac | 접근 없음 | 읽기·쓰기 | 접근 없음 |
| 태블릿 | 접근 없음 | 접근 없음 | 읽기·쓰기 |

### 5.2 방과 캐릭터 식별

- 방 식별: `(space_id, room_id)`
- 캐릭터 식별: `(space_id, character_id)` 또는 방 profile의 독립 UUID
- `display_name`은 표시용이며 식별에 사용하지 않는다.

예시:

```text
(MAC_SPACE, marin-A)   != (PHONE_SPACE, marin-B)
```

두 캐릭터는 모두 화면에 `마린`으로 표시될 수 있지만 아바타, 말투, 대화, 호감도와 cache는 완전히 독립적이다.

### 5.3 방별 동작 규격: Engine Profile

공유 방에서 기기를 바꿔도 AI 동작이 갑자기 달라지는 것을 방지하려면 다음 metadata가 필요하다.

```json
{
  "mode": "mentor | companion",
  "engineFamily": "mac | tablet | phone",
  "promptVersion": 1,
  "personaSchemaVersion": 1,
  "compactionVersion": 1,
  "cachePolicyVersion": 1,
  "features": ["persona", "attachments"]
}
```

전체 Swift·Kotlin 구현을 한 코드로 합칠 필요는 없다. 대신 같은 engine profile을 두 구현이 같은 의미로 해석하도록 contract test를 둔다.

지원하지 않는 profile의 방은 잘못된 로직으로 답변을 만들지 않고 다음 중 하나로 처리한다.

1. 읽기 전용
2. 사용자가 승인한 명시적 fallback
3. 향후 server-side engine

첫 버전에서 조용한 fallback은 허용하지 않는 방향을 권장한다.

## 6. 폰 UI 제안

### 6.1 채팅 출처 탭

폰의 `채팅` 제목과 채팅방 목록 사이에 다음 고정 탭을 둔다.

```text
[ 폰 ]  [ Mac ]  [ 태블릿 ]
```

- 기본 선택은 `폰`이다.
- 선택한 space의 방만 목록에 표시한다.
- 검색은 기본적으로 선택된 space 안에서만 수행한다.
- `전체` 탭은 섞임 방지 요구와 충돌하므로 초기 범위에서 제외한다.
- 동일한 행 디자인을 유지하고 source badge를 매 행에 반복하지 않는다.
- 연결 실패 시 기존 cloud replica를 보여 주되 `마지막 동기화 시각`과 offline 상태를 표시한다.
- Mac·태블릿 탭에서 새 방 생성은 첫 단계에서 비활성화하고 기존 방 이어가기만 허용하는 안을 권장한다.

### 6.2 친구 탭

첫 단계 권장안:

- 친구 탭은 폰 출처 캐릭터만 유지한다.
- Mac·태블릿 캐릭터 profile은 해당 출처 채팅방에서 열 수 있다.
- 필요가 확인되면 친구 탭에도 같은 출처 분류를 추가한다.

이렇게 하면 동기화 첫 단계에서 친구 목록, 단톡방 참여자, 즐겨찾기까지 동시에 재설계하지 않아도 된다.

## 7. 저장 위치와 데이터 분류

| 데이터 | 각 기기 로컬 | D1 | 다른 기기 공개 |
| --- | --- | --- | --- |
| 방 metadata | 예 | 예 | space 권한에 따름 |
| 원본 메시지 | 예 | 예 | space 권한에 따름 |
| 캐릭터 profile·말투 snapshot | 예 | 예 | space 권한에 따름 |
| 장기 context checkpoint | 예 | 예 | space 권한에 따름 |
| Gemini explicit cache metadata | 예 | 조건부 권장 | 재사용 조건을 만족할 때만 |
| Gemini 실제 cachedContents payload | Gemini 서버 | 아니요 | 해당 provider credential 범위에 따름 |
| 폰 호감도 | 폰 | 폰 space에 backup 가능 | Mac·태블릿에는 기본 비공개 |
| API key | 보안 저장소 | 금지 | 금지 |
| Gemini cache용 credential | 보안 저장소 | 금지 | 금지 |
| UI 설정·검색 index·render cache | 예 | 아니요 | 아니요 |
| token 사용량 장부 | 기기별 | 초기에는 아니요 | 아니요 |
| sync cursor·outbox | 예 | server change log와 대응 | 아니요 |

Cloud에 저장되는지와 다른 기기에서 보이는지는 분리된 정책이다. 폰 전용 방을 D1에 backup하더라도 Mac·태블릿 token에는 그 space를 반환하지 않을 수 있다.

## 8. Cloudflare 권장 구조

```text
Mac local JSON ─ Swift Sync Adapter ─┐
                                      ├─ Worker API ─ D1
Android local JSON ─ Kotlin Adapter ──┘       │
                                              └─ Durable Object/WebSocket notifier (선택)
```

### 8.1 Workers

역할:

- 기기 인증과 권한 확인
- payload schema validation
- idempotency 확인
- D1 transaction 실행
- server sequence 발급
- 변경 알림 발행

### 8.2 D1

권장 table 초안:

- `devices`
- `spaces`
- `device_space_permissions`
- `rooms`
- `room_profiles`
- `persona_versions`
- `messages`
- `message_revisions`
- `context_checkpoints`
- `provider_cache_leases`
- `change_log`
- `sync_cursors`
- `import_batches`
- `tombstones`

정확한 정규화 수준은 query 계획을 보고 조정하되, 초기부터 모든 플랫폼 model을 하나의 거대한 JSON blob으로 저장하는 방식은 피한다. 플랫폼 확장 필드는 versioned extension JSON으로 보존할 수 있다.

### 8.3 실시간 알림

권장 순서:

1. 앱 시작·foreground·메시지 저장 직후 즉시 sync
2. 채팅 화면이 열린 동안 짧은 polling fallback
3. 실제 즉시성이 필요하면 Durable Object + WebSocket으로 `변경 있음` 신호만 전송
4. 메시지 본문은 항상 Worker sync endpoint에서 sequence 기준으로 pull

WebSocket 자체를 데이터 원본으로 사용하지 않는다. 앱이 종료되거나 socket이 끊겨도 cursor 기반 pull로 복구되어야 한다.

### 8.4 Free plan 적합성

2026-08-26 공식 문서 기준:

- [Workers Free](https://developers.cloudflare.com/workers/platform/pricing/): 100,000 requests/day, 10ms CPU/invocation
- [D1 Free](https://developers.cloudflare.com/d1/platform/pricing/): 5M rows read/day, 100K rows written/day, 5GB total storage

개인 사용자 1명의 text 중심 sync에는 충분할 가능성이 높지만, full scan을 피하도록 `space_id`, `server_seq`, `room_id`, `updated_revision` index를 설계해야 한다. 실제 historical data의 건수·크기를 inventory한 뒤 quota를 다시 계산한다.

## 9. 인증과 개인정보

### 9.1 기기 인증

고정 token을 앱 binary에 포함하지 않는다.

권장 흐름:

1. 최초 연결 시 일회용 pairing code 또는 QR 생성
2. Worker가 기기별 random token 발급
3. Mac은 Keychain, Android는 암호화 저장소에 보관
4. D1에는 token 원문이 아닌 검증용 hash 저장
5. 분실 기기 token만 개별 폐기 가능

### 9.2 대화 암호화

HTTPS는 전송 중 암호화만 제공한다. Cloudflare 관리면에서도 대화 평문을 숨겨야 한다면 historical data upload 전에 client-side encryption 정책을 결정해야 한다.

검토안:

- metadata 중 routing에 필요한 `space_id`, ID, sequence, revision만 평문
- profile·persona·message body·context summary는 client-side authenticated encryption
- 기기 pairing 과정에서 공통 sync key 전달
- key 분실 시 복구 정책을 사전에 결정

End-to-end encryption은 나중에 덧붙이면 기존 데이터를 재암호화해야 하므로 실제 데이터를 올리기 전에 채택 여부를 결정하는 편이 낫다.

## 10. Sync protocol

### 10.1 Local commit first

1. 사용자가 메시지를 보낸다.
2. 현재 앱의 기존 로컬 저장에 먼저 확정한다.
3. 별도 sync outbox에 idempotent operation을 기록한다.
4. Worker로 push한다.
5. server sequence와 revision을 받으면 outbox operation을 완료 처리한다.

Cloudflare 장애가 앱의 로컬 저장 성공을 막아서는 안 된다.

### 10.2 Pull

1. 기기가 space별 마지막 `server_seq`를 보낸다.
2. Worker는 이후 변경만 반환한다.
3. client는 임시 snapshot에 decode·validation한다.
4. ID, revision, message count, 지원 schema를 확인한다.
5. 검증 성공 후에만 로컬 파일을 atomic replace하거나 append한다.
6. 실패하면 기존 로컬 파일과 cursor를 유지한다.

### 10.3 Idempotency

- operation마다 `operation_id`를 둔다.
- 메시지는 `(space_id, room_id, message_id)` unique다.
- 같은 operation 재전송은 성공 결과를 재사용하고 중복 message를 만들지 않는다.
- client timestamp가 아니라 server sequence로 순서를 확정한다.

### 10.4 수정·삭제

- message 수정은 새 revision으로 기록한다.
- 동시 수정 시 `base_revision` 불일치를 conflict로 반환한다.
- 삭제는 tombstone으로 먼저 전파한다.
- 최초 migration과 pilot에서는 원격 삭제를 실제 로컬 삭제로 자동 적용하지 않는 안을 권장한다.

### 10.5 Field ownership

플랫폼이 이해하지 못하는 필드를 제거하지 않도록 전체 room PUT을 금지하고 영역별 patch를 사용한다.

예:

- 공통 profile patch
- persona common patch
- Android phone extension patch
- group/worldline extension patch
- affection event append

## 11. 대화 로직 호환 전략

### 11.1 전체 로직 통일은 필수가 아니다

UI와 구현 언어는 계속 다를 수 있다. 다만 공유 방의 다음 AI 입력에 영향을 주는 데이터 계약은 통일해야 한다.

- mode
- model
- system prompt version
- persona snapshot
- context checkpoint
- relationship state 사용 여부
- feature flags

### 11.2 멘토·챗봇 mode

- mode는 room metadata로 동기화한다.
- 태블릿 출처 방은 현재 capability에 맞춰 mentor로 제한할 수 있다.
- phone이 Mac·태블릿 방을 열 때 자기 기본 mode로 조용히 바꾸지 않는다.
- 해당 engine profile을 phone이 지원하지 않으면 처음에는 읽기 전용으로 막는 것이 안전하다.

### 11.3 Context compaction

원본 messages를 canonical source of truth로 둔다.

공통 checkpoint 최소 필드:

```json
{
  "spaceId": "...",
  "roomId": "...",
  "throughServerSeq": 1234,
  "segments": [],
  "summaryText": "...",
  "compactionVersion": 1,
  "promptVersion": 1,
  "createdByDevice": "...",
  "revision": 1
}
```

규칙:

1. 어떤 메시지 범위를 덮는지 명시한다.
2. 동일 범위의 checkpoint를 여러 기기가 중복 생성하지 않도록 compare-and-set한다.
3. 다른 기기는 유효한 checkpoint를 다시 요약하지 않고 opaque summary로 사용할 수 있어야 한다.
4. compaction algorithm이 호환되지 않으면 새 checkpoint 생성 권한을 제한한다.
5. 원본 메시지는 checkpoint 생성 후에도 즉시 삭제하지 않는다.

### 11.4 Persona

동기화 대상은 말투를 만드는 과정 전체가 아니라 확정된 persona snapshot이다.

공통 필드:

- 설명
- 실제 대사 예시
- style guide
- 활성 여부
- snapshot version

Android 확장 필드:

- suppressed expressions
- sample evidence
- 반복 제어 metadata

Mac은 Android 확장을 이해하지 않아도 server에서 보존해야 하며 공통 필드 patch가 확장을 삭제해서는 안 된다.

### 11.5 호감도

첫 단계 권장 정책:

- `PHONE_SPACE` 방: 기존 phone 호감도 사용 및 phone extension으로 backup 가능
- `MAC_SPACE` 방을 phone에서 열었을 때: 호감도 계산·prompt 반영 비활성화
- `TABLET_SPACE` 방을 phone에서 열었을 때: 호감도 계산·prompt 반영 비활성화

이유: phone만 아는 호감도가 AI prompt에 영향을 주면 Mac·태블릿이 같은 방을 이어갈 때 행동이 달라진다.

향후 공유 방에도 호감도를 적용하려면:

1. 관계 상태와 event를 canonical data로 승격
2. Mac·태블릿도 값을 최소한 읽고 보존
3. UI에 하트를 표시하지 않더라도 AI prompt에는 같은 상태 반영
4. 어느 기기에서 계산해도 동일한 bounded rule 사용

### 11.6 단톡방·세계선

초기 sync 범위에서는 phone 전용으로 유지하는 것이 안전하다. Mac·태블릿이 group/worldline schema와 prompt semantics를 지원하기 전까지 다른 space로 노출하지 않는다.

## 12. Cache 정책

`cache`라는 이름의 데이터를 모두 같은 것으로 취급하지 않는다.

### 12.1 반드시 동기화할 것

Context checkpoint는 단순 cache가 아니라 장기 대화 기억이므로 D1에 저장한다.

### 12.2 조건부 동기화할 것: Gemini explicit cache metadata

현재 Mac과 Android는 다음을 로컬 `prefix_caches.json`에 저장한다.

- `cachedContents/...` resource name
- covered turns
- prefix fingerprint
- expiresAt
- tokenCount

현재 TTL은 15분이다. 기기 전환 직후 비용을 줄이려면 metadata를 D1의 짧은 cache lease로 공유할 수 있다.

최소 필드:

```text
space_id
room_id
provider
model
engine_profile_version
cache_name
covered_through_seq
fingerprint
expires_at
credential_scope
owner_device
generation
```

재사용 조건:

- 동일 provider credential scope
- 동일 model
- 동일 system prompt·persona fingerprint
- 동일 message prefix
- 동일 engine profile
- 충분한 TTL 잔여 시간

조건 하나라도 다르면 cache lease를 무시하고 로컬에서 새 cache를 만든다. API key 자체는 D1에 저장하지 않는다.

### 12.3 로컬에만 둘 것

- thumbnail
- Markdown·수식 render cache
- 검색 index
- 화면 높이
- 메모리 object cache
- OpenAI implicit cache metadata

Provider cache는 비용 최적화 수단일 뿐 유일한 기억이 되어서는 안 된다. 만료·삭제·credential 불일치 시 원본 메시지와 context checkpoint로 복구한다.

## 13. 무손상 migration과 rollout

### Phase 0: Inventory와 rollback 증명

- 세 기기의 현재 방·메시지·persona·digest·attachment·cache metadata 수와 파일 크기를 수집한다.
- 실제 대화 원문은 로그에 출력하지 않는다.
- 기기별 전체 export archive를 만든다.
- hash manifest를 만든다.
- archive에서 별도 test 위치로 restore되는지 검증한다.
- restore가 검증되기 전에는 실제 sync를 켜지 않는다.

### Phase 1: Contract와 fixture

- canonical schema v1 작성
- Swift·Kotlin DTO와 validator 작성
- 실제 대화가 아닌 합성 fixture 사용
- 같은 이름의 서로 다른 캐릭터 fixture 포함
- unknown extension preservation test
- 날짜·UUID·revision·tombstone round-trip test
- engine capability matrix 작성

### Phase 2: Cloudflare test namespace

- production data와 분리된 D1 test database 사용
- Worker auth·validation·idempotency 구현
- synthetic data만 push/pull
- quota와 query row scan 측정

### Phase 3: Shadow upload

- 각 기기 로컬에서 D1로 **복사만** 한다.
- D1 데이터를 다시 로컬에 적용하지 않는다.
- 각 upload를 immutable `import_batch_id`로 묶는다.
- name 기반 merge와 delete를 금지한다.
- local count·hash와 D1 count·hash를 비교한다.

### Phase 4: 폰 read-only 출처 탭

- `폰 · Mac · 태블릿` 탭 UI 추가
- Mac·태블릿 탭은 D1 replica를 read-only로 표시
- 원본 로컬 파일에 write-back하지 않는다.
- 실제 기기에서 이름 중복, 검색, 정렬, avatar, 긴 preview, offline cache를 확인한다.

### Phase 5: Test room 1개 양방향

- 새 `동기화 테스트` 방만 opt-in
- Mac → phone → Mac 검증
- tablet → phone → tablet 검증
- offline, 재연결, 중복 push, 앱 강제 종료, socket 단절, Worker 오류 검증
- edit·delete는 처음에는 비활성화하거나 별도 test room에서만 검증

### Phase 6: 기존 방 opt-in

- 사용자가 방별로 sync를 켠다.
- 중요한 기존 방을 일괄 migration하지 않는다.
- 각 방 활성화 전에 preview와 count를 보여 준다.
- 일정 기간 원본 backup과 import batch를 유지한다.

### Phase 7: 선택 기능

다음은 기본 sync 안정 후 별도 결정한다.

- shared context checkpoint 생성
- explicit cache lease 공유
- 공유 방 호감도
- 단톡방·세계선
- 첨부 파일용 R2
- WebSocket notifier
- end-to-end encryption

## 14. Rollback 원칙

1. sync를 꺼도 기존 로컬 앱이 즉시 정상 동작해야 한다.
2. Shadow 단계에서는 rollback이 `sync off + cloud test data 폐기`만으로 끝나야 한다.
3. 기존 로컬 JSON schema를 파괴적으로 migration하지 않는다.
4. incoming apply 전 local snapshot을 남긴다.
5. remote delete는 유예 기간 동안 tombstone으로만 존재한다.
6. import batch 단위로 cloud 데이터를 식별하고 되돌릴 수 있어야 한다.
7. rollback 절차는 실제 방을 활성화하기 전에 합성 데이터로 실행해 본다.

## 15. 검증 계획

### 15.1 Contract

- Swift가 만든 canonical JSON을 Kotlin이 decode·encode한다.
- Kotlin이 만든 canonical JSON을 Swift가 decode·encode한다.
- 모르는 extension 필드가 server round-trip 뒤에도 유지된다.
- 같은 이름·다른 UUID·다른 space의 방이 병합되지 않는다.

### 15.2 Sync

- 같은 operation을 반복 전송해도 message가 한 번만 생긴다.
- client clock이 틀려도 server sequence 순서가 유지된다.
- offline outbox가 재연결 후 순서대로 비워진다.
- 지원하지 않는 schema는 적용하지 않고 오류 상태로 남는다.
- partial file write나 decode 실패 시 기존 로컬 파일이 유지된다.

### 15.3 실제 사용자 흐름

1. Mac 방에 메시지 작성 → 폰 Mac 탭에 표시
2. 폰 Mac 탭에서 답장 → Mac 같은 방에 표시
3. 태블릿 방에 메시지 작성 → 폰 태블릿 탭에 표시
4. 폰 태블릿 탭에서 답장 → 태블릿 같은 방에 표시
5. 폰 탭에서 새 방 생성 → Mac·태블릿에는 표시되지 않음
6. Mac 마린과 폰 마린이 별도 탭에서 독립적으로 유지됨
7. 앱과 Cloudflare가 offline이어도 기존 로컬 대화가 열림

### 15.4 대화 엔진

- mentor와 companion fixture를 따로 둔다.
- 같은 persona snapshot이 양 플랫폼에서 같은 system prompt 의미를 만드는지 비교한다.
- checkpoint 범위가 중복·누락되지 않는다.
- cache fingerprint가 다르면 cache를 재사용하지 않는다.
- phone-only affection이 Mac·태블릿 방 prompt에 들어가지 않는다.

### 15.5 보안

- API key와 실제 대화 원문이 log, URL, analytics에 나타나지 않는다.
- phone token으로 허용되지 않은 space를 읽을 수 없다.
- 폐기한 device token으로 access할 수 없다.
- lock screen·오류 화면에 민감한 원문을 불필요하게 노출하지 않는다.

## 16. 주요 위험과 완화책

| 위험 | 결과 | 완화책 |
| --- | --- | --- |
| 이름 기반 병합 | 서로 다른 마린의 데이터 혼합 | `(space_id, UUID)`만 식별자로 사용 |
| Mac re-encode | Android 확장 필드 소실 | field patch·extension 보존 |
| cloud-first 전환 | 장애 시 앱 사용 불가 | local-first·outbox·cursor |
| 두 기기 동시 수정 | profile·message split-brain | revision compare-and-set |
| client clock 오차 | 메시지 순서 오류 | server sequence |
| compaction 차이 | 요약 중복·문맥 변화 | 범위가 명시된 canonical checkpoint |
| phone 호감도 누출 | Mac과 phone의 캐릭터 행동 불일치 | 공유 방에서 비활성화 또는 canonical 승격 |
| cache metadata 오용 | 404·잘못된 context·비용 증가 | TTL·fingerprint·model·credential scope 검증 |
| Free quota 초과 | sync 일시 중단 | index·delta pull·사용량 경보·local 계속 사용 |
| migration 오류 | 기존 데이터 손상 | backup restore test·Shadow Sync·방별 opt-in |
| 민감한 평문 저장 | 개인정보 노출 | 최소 로그·기기 token·E2EE 결정 |

## 17. 확정 사항과 미결정 사항

### 확정된 요구

- 세 앱 경험 유지
- phone UI 출처 탭
- 기본 `폰` 탭
- Mac·태블릿 방은 phone과 양방향
- phone 방은 Mac·태블릿에 기본 비공개
- 같은 이름 자동 병합 금지
- local-first
- 기존 데이터 무손상 우선

### 구현 전 결정 필요

1. 폰 전용 방도 D1에 backup할지, 완전 local-only로 둘지
   - 권장: D1 backup은 하되 phone space 권한으로 숨김
2. Mac 방을 태블릿에서도 볼 수 있게 할지
   - 현재 기본: 아니요
3. phone의 Mac·태블릿 탭에서 새 방 생성을 허용할지
   - 초기 권장: 아니요, 기존 방 이어가기만
4. 친구 탭에도 출처 탭을 추가할지
   - 초기 권장: 아니요
5. shared room에서 engine profile을 어느 수준까지 동일하게 보장할지
6. shared room에 호감도를 도입할지
   - 초기 권장: 아니요
7. historical data를 올리기 전에 end-to-end encryption을 적용할지
8. 세 기기가 동일 Gemini credential scope를 사용할지
9. polling만으로 시작할지 WebSocket notifier를 함께 넣을지
10. message edit·delete를 어느 rollout phase에 허용할지

## 18. 다른 AI 에이전트에게 요청하는 검토 항목

이 프로젝트를 만든 에이전트는 다음을 근거와 함께 검토해 주기 바란다.

1. Android phone과 tablet의 실제 data·engine 차이가 이 문서에 정확히 반영됐는가?
2. Mac Codable round-trip에서 사라질 Android 전용 필드가 더 있는가?
3. `(space_id, room_id)` namespace가 기존 UUID·file naming과 충돌하지 않는가?
4. phone이 Mac·태블릿 방을 쓸 때 필요한 최소 engine compatibility 범위는 어디까지인가?
5. `BuildConfig.TABLET_MENTOR`를 runtime engine profile로 옮겨야 하는 정확한 call site는 어디인가?
6. canonical checkpoint를 opaque summary로 공유해도 기존 compactor invariant를 지킬 수 있는가?
7. current prefix cache가 동일 provider credential scope에서 다른 기기로 재사용 가능한가?
8. cache invalidation·delete race를 막기 위한 lease generation이 충분한가?
9. phone-only affection을 shared room에서 비활성화할 때 기존 UI·prompt 경로가 안전한가?
10. Shadow Sync와 방별 opt-in이 기존 JSON 데이터에 write하지 않는다는 것을 어떻게 증명할 것인가?
11. Worker 10ms CPU 제한 안에서 validation·D1 query·암호화 routing을 처리할 수 있는가?
12. 이 제안보다 더 작은 변경으로 동일한 사용자 경험과 데이터 안전을 달성할 수 있는가?

## 19. 구현 착수 gate

다음 조건을 충족하기 전에는 실제 historical data를 D1에 올리거나 기존 로컬 파일에 remote data를 적용하지 않는다.

- 다른 에이전트의 architecture review 완료
- canonical schema v1 승인
- source space와 권한 정책 승인
- backup·restore 실제 검증
- synthetic round-trip contract test 통과
- Shadow Sync의 non-destructive 성질 검증
- E2EE 적용 여부 결정
- 한 test room의 rollback 절차 검증

## 20. 제안 결론

이 기능은 세 앱을 하나로 통합하는 프로젝트가 아니라, 기존 앱 위에 **출처 공간, 공통 data contract, local-first sync, 안전한 migration**을 추가하는 프로젝트로 정의해야 한다.

완성형을 한 번에 구현하면 범위가 지나치게 커진다. 반대로 cache·compaction·persona·호감도를 무시한 가벼운 파일 복사 prototype은 기존 데이터를 위험하게 만들 수 있다. 따라서 권장 순서는 다음과 같다.

1. Contract와 rollback을 먼저 설계한다.
2. 합성 데이터로 server와 adapter를 검증한다.
3. 실제 데이터는 Shadow Sync로 복사만 한다.
4. phone에서 read-only 출처 탭을 검증한다.
5. 새 test room 하나만 양방향으로 연다.
6. 기존 방은 사용자 opt-in으로 하나씩 확장한다.
7. engine checkpoint, cache lease, 호감도는 검증된 필요에 따라 순차 추가한다.

기능은 작은 범위로 시작하되 데이터 안전과 호환성 규칙은 축소하지 않는 것이 이 제안의 핵심이다.
