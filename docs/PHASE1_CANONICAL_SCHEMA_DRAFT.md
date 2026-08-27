# Phase 1 Canonical Sync Schema 초안

## 문서 상태

- 작성일: 2026-08-27
- 작성: Claude Code (Codex 배정 작업)
- 상태: **초안 / Codex 통합 검토 대기 / 확정 아님 / 구현 승인 아님**
- 이 문서는 **Cloudflare 리소스 생성, 앱 코드 구현, Phase 3 실데이터 업로드를 승인하지 않는다.**
- 작성 중 앱 코드·Cloudflare 리소스·실제 대화 archive를 열거나 변경하지 않았다. Phase 0 수치는 저장소 안 보고서의 집계값만 인용했다.

### 근거 문서

| 문서 | 이 초안에서 쓰는 것 |
| --- | --- |
| [기술 합의문](CROSS_DEVICE_SYNC_AGREEMENT.md) | identity 계층, 필드 ownership, patch·tombstone 계약, checkpoint 계약 |
| [사용자 결정 기록](CROSS_DEVICE_SYNC_USER_DECISIONS.md) | 17개 제품 결정 |
| [Phase 0 조사 결과](2026-08-27-phase0-inventory-result.md) | 실제 데이터 규모, legacy turn 분포, 첨부·avatar 최대값 |
| [Phase 0 조사 계획](PHASE0_INVENTORY_PLAN.md) | 비파괴 원칙, raw read 경로 |
| [E2EE 제안서](2026-08-27-sync-encryption-proposal.md) | 암호화 경계와 평문 metadata 목록 — **참조만 하며 이 문서에서 암호 규격을 새로 만들지 않는다** |

## 0. 표기 규약

### 0.1 합성 데이터 규약

**이 문서의 모든 예시는 완전한 합성 데이터다.** 실제 대화·실제 UUID·실제 방 이름을 쓰지 않았다.

예시 UUID는 사람이 진짜와 구분할 수 있도록 다음 규칙을 따른다.

```text
X0000000-0000-4000-8000-0000000000NN
└ 첫 자리로 entity 종류를 구분하고 나머지는 0으로 채운다
  1 = room, 2 = worldline, 3 = turn, 4 = message,
  5 = persona snapshot, 6 = checkpoint, 7 = attachment,
  8 = device, 9 = operation, a = account, b = character,
  c = engine profile
```

`00000000-0000-4000-8000-000000000000`(전부 0)은 §14.2의 기본 세계선 sentinel 후보이며 다른 entity에 쓰지 않는다.

실제 구현은 표준 random UUID v4를 쓴다. 위 규칙은 문서 예시 전용이다.

### 0.2 암호화 표기

E2EE 제안서 §8이 정한 경계에 따라, **내용 필드는 봉투 base64로 저장하고 metadata만 평문으로 둔다.** 이 문서는 어느 필드가 어느 쪽인지만 표시하고 암호 규격은 정의하지 않는다.

- 🔒 = E2EE 제안서 §8.2의 암호화 대상. D1에는 봉투 base64 문자열로 들어간다.
- ⬜ = E2EE 제안서 §8.3의 평문 metadata.

예시 JSON의 봉투 값은 `"ENC(...)"` 형태의 **자리표시자**다. 실제 봉투 byte 형식은 E2EE 제안서 §7.1에 있다.

> **Codex 통합 결정 필요:** 암호화 필드의 D1 컬럼 명명 규칙(`title` vs `title_enc`)이 아직 정해지지 않았다. 이 문서는 읽기 쉽도록 평문 이름을 쓰고 🔒로 표시했다. 컬럼 접미사를 붙일지 확정해야 한다.

### 0.3 시각과 순서

- ⬜ `created_at`·`updated_at`은 RFC 3339 UTC 문자열이다.
- ⬜ `server_seq`는 Worker가 매기는 단조 증가 정수이며 정렬의 권위 원본이다.
- 클라이언트 timestamp는 표시·정렬 보조에만 쓰고 순서 판정에 쓰지 않는다.

---

## 1. Identity 계층

```text
account_id
  └ device_id                       (계정에 연결된 기기)
  └ space_id                        (출처 space, 고정 enum)
       └ room_id
            └ worldline_id?         (nullable storage axis)
                 └ turn_id
                      └ (bubble_order, message_id)
```

| Entity | 키 | 비고 |
| --- | --- | --- |
| account | ⬜ `account_id` (UUID) | E2EE 계정 1개 = 동기화 계정 1개 |
| device | ⬜ `device_id` (UUID) | `(account_id, device_id)`로 유효성 판정 |
| space | ⬜ `space_id` (enum 문자열) | `MAC_SPACE`·`PHONE_SPACE`·`TABLET_SPACE` |
| room | ⬜ `room_id` (UUID) | 기존 방 UUID를 그대로 유지한다 |
| worldline | ⬜ `worldline_id` (UUID, nullable) | null이면 방의 기본 세계선 |
| turn | ⬜ `turn_id` (UUID) | 논리적 turn |
| bubble | ⬜ `message_id` (UUID) + ⬜ `bubble_order` | 화면 말풍선 |

```text
conversation_scope = (space_id, room_id, worldline_id?)
turn_identity      = (conversation_scope, turn_id)
bubble_identity    = (conversation_scope, turn_id, bubble_order, message_id)
```

### 1.1 space는 고정 enum이다

Phase 0에서 세 source space를 모두 조사했다. `space_id`는 자유 문자열이 아니라 아래 세 값만 허용한다.

| `space_id` | 기기 | Phase 0 관측 |
| --- | --- | ---: |
| `MAC_SPACE` | macOS | 방 6, 메시지 파일 13 |
| `PHONE_SPACE` | Android phone | 방 10, 단톡방 2, worldline 2 |
| `TABLET_SPACE` | Android tablet | 방 2, 메시지 파일 2 |

**`space_id`는 build flavor에서 추론하지 않고 기기 등록 시 확정해 저장한다.** 합의문이 지적한 대로 flavor는 동기화되지 않는다.

### 1.2 device

```json
{
  "account_id": "a0000000-0000-4000-8000-000000000001",
  "device_id": "80000000-0000-4000-8000-000000000001",
  "space_id": "MAC_SPACE",
  "display_name": "ENC(device label)",
  "platform": "macos",
  "linked_at": "2026-08-27T00:00:00Z",
  "revoked_at": null,
  "key_generation": 1
}
```

- ⬜ `platform`은 `macos`·`android_phone`·`android_tablet` 중 하나다.
- 🔒 `display_name`은 사용자가 붙인 기기 이름이므로 암호화한다.
- ⬜ `revoked_at`이 null이 아니면 해당 device token을 거부한다.

> **Codex 통합 결정 필요:** 한 `space_id`에 기기가 둘 이상 연결될 수 있는지. 현재 사용자 결정은 Mac 1대·phone 1대·tablet 1대를 전제하지만 schema가 이를 강제할지 정해야 한다. 강제하면 기기 교체 시 마이그레이션이 필요하고, 강제하지 않으면 같은 space에서 동시 write가 가능해진다.

---

## 2. `bubble_order` 규칙

합의문의 확정 규칙을 schema 관점으로 옮긴다.

1. ⬜ `bubble_order`는 부호 없는 정수이며 **최초 canonical import에서 원본 JSON 배열 index로 확정**한다.
2. 확정된 mapping은 `(conversation_scope, message_id)`에 대해 **불변**이다. 같은 원본을 다시 import해도 같은 값을 낸다.
3. **빈 번호를 허용한다.** 삭제로 번호가 듬성듬성해지는 것은 정상이며, 빠진 번호를 누락 데이터나 삭제 증거로 해석하지 않는다.
4. 삭제·정렬·재동기화 뒤에도 기존 bubble을 재번호 매기지 않는다.
5. 새 bubble은 해당 scope의 현재 최대값보다 큰 값을 받는다. 기존 순서를 바꾸지 않는다.

`bubble_order`는 E2EE 제안서 §7.2의 AAD field 10에 포함되므로, **확정 후 값을 바꾸면 기존 암호문을 복호화할 수 없다.** 이 문서의 불변 규칙은 표시 순서 문제가 아니라 복호화 가능성 문제다.

중간 삽입이 필요한 기능(메시지 편집 등)은 별도 stable ordering 규격을 먼저 정한 뒤에 연다.

> **Codex 통합 결정 필요:** `bubble_order`의 폭. E2EE AAD는 UInt64BE로 잡혀 있고 D1은 `INTEGER`(64bit signed)다. 두 표현의 경계값 처리와 새 bubble 증가 폭(1씩인지 간격을 둘지)을 확정해야 한다.

---

## 3. Room과 room profile

### 3.1 canonical 필드와 local-only 필드

합의문의 필드 ownership 표를 schema로 확정한다. **local-only 필드는 D1에 올리지 않는다.**

| 필드 | 구분 | 근거 |
| --- | --- | --- |
| `room_id`, `space_id`, `worldline_id` | ⬜ canonical | identity |
| `title` | 🔒 canonical | 방 이름 |
| `status_message` | 🔒 canonical | |
| `music_title`, `music_artist` | 🔒 canonical | |
| `engine_profile` | canonical (§4) | |
| `persona_snapshot_ref` | canonical (§5) | |
| `avatar_ref` | canonical (§7) | R2 참조 |
| `revision` | ⬜ canonical | CAS |
| `unread_count`, `is_unread` | **local-only** | 기기별 상태 |
| `delivery_failed` | **local-only** | 기기별 전송 상태 |
| `is_pinned` | **local-only** | 기기별 UI 상태 |
| `last_message_text`, `last_message_time` | **파생** | canonical message에서 계산 |
| render·search·object cache | **local-only** | |
| `avatar_image_file_name` | **local-only** | 파일 payload 없는 local pointer |

`last_message_time`은 E2EE 제안서 §8.5에 따라 **평문 timestamp의 최대값으로 계산**하며 별도 평문 콘텐츠 필드를 만들지 않는다.

### 3.2 whole-room PUT 금지

**room·message 전체를 통째로 올리는 `PUT`을 금지한다.** 이유는 편의 문제가 아니라 데이터 소실이다.

Mac 모델에는 `baseAffection`·`groupChat`·`suppressedExpressions`·`sampleEvidence`·`speakerRoomId`·`reactions`·`heartChanges` 같은 Android 전용 필드의 정의가 없다. Mac이 room 레코드를 통째로 받아 Codable로 round-trip하면 **모르는 필드가 조용히 사라진 채 다시 올라간다.** Phase 0에서 phone의 `speakerRoomId` 메시지 411개, heart change 237개, group participant 참조 4개를 확인했으므로 이는 가상의 위험이 아니다.

따라서 모든 room·profile 변경은 §8의 field patch로만 수행한다. 서버는 자신이 모르는 필드를 opaque extension으로 보존하며, 공통 필드 patch가 이를 삭제해서는 안 된다.

### 3.3 room 예시

```json
{
  "account_id": "a0000000-0000-4000-8000-000000000001",
  "space_id": "PHONE_SPACE",
  "room_id": "10000000-0000-4000-8000-000000000001",
  "worldline_id": null,
  "title": "ENC(room title)",
  "status_message": "ENC(status)",
  "music_title": null,
  "music_artist": null,
  "avatar_ref": {
    "attachment_id": "70000000-0000-4000-8000-000000000009",
    "byte_size": 274146
  },
  "engine_profile_ref": {
    "engine_profile_id": "c0000000-0000-4000-8000-0000000000e1",
    "profile_revision": 3
  },
  "persona_snapshot_ref": {
    "persona_snapshot_id": "50000000-0000-4000-8000-000000000001",
    "snapshot_revision": 2
  },
  "revision": 41,
  "server_seq": 10427,
  "updated_at": "2026-08-27T00:00:00Z",
  "extensions": {
    "android.baseAffection": "ENC(opaque extension)"
  }
}
```

`extensions`는 **다른 플랫폼이 모르는 필드를 그대로 보존하는 자리**다. 키는 소유 플랫폼을 접두사로 붙여 충돌을 막는다.

> **Codex 통합 결정 필요:** `extensions` 키 명명 규칙(`android.` 접두사 방식)과, 값 전체를 하나의 봉투로 암호화할지 키마다 개별 봉투를 둘지. 개별 봉투는 per-field patch와 잘 맞고, 통째 봉투는 unknown field 보존이 단순하다.

---

## 4. `engineProfile`과 `relationshipPolicy`

`engine_profile`은 **방을 어느 기기에서 열어도 같은 AI 동작 계약을 해석하기 위한 room-level canonical profile**이다. Provider credential이나 API key를 담지 않는다.

| 필드 | 의미 |
| --- | --- |
| 🔒 `mode` | `mentor`·`companion` 등 대화 동작 모드 |
| 🔒 `model_capability` | 제품명 fallback이 아니라 필요한 capability와 generation 동작 |
| 🔒 `prompt_profile_id`, `prompt_profile_version` | system/persona prompt 계약과 version |
| 🔒 `relationship_policy` | 관계·호감도 동작 계약 |
| 🔒 `compaction_profile_id` | 사람이 관리하는 압축 정책 이름 |
| 🔒 `compaction_contract_fingerprint` | 기계 판정용 압축 fingerprint |
| 🔒 `cache_policy` | provider cache 생성·재사용 호환성 계약 |
| 🔒 `repetition_policy` | runtime 반복 제어 동작과 prompt version |
| ⬜ `profile_revision` | CAS |
| ⬜ `compaction_compat_tag` | 서버가 equality만 비교하는 keyed 태그 |

`relationship_policy`의 허용값은 `none`·`personal`·`group` 세 가지다.

`mode`·`model_capability`·`compaction_profile_id`·`compaction_contract_fingerprint`는 E2EE 제안서 §8.2의 암호화 대상이다. 서버가 호환성 equality만 판정해야 하는 경우 실제 값 대신 §8.4의 `compaction_compat_tag`(평문)를 쓴다.

**반복 제어는 persona extension으로 가장하지 않고 여기 `repetition_policy`에서 계약한다.** Android의 `companionRepetitionControlEnabled`는 저장 필드가 아니라 method 인자이고 `repetitionAdviceFromConversation`은 runtime 계산 결과이므로 canonical 저장 대상이 아니다.

지원하지 않는 profile을 만난 기기는 **read-only로 열고 조용한 fallback을 하지 않는다**(사용자 결정 8).

```json
{
  "engine_profile_id": "c0000000-0000-4000-8000-0000000000e1",
  "profile_revision": 3,
  "mode": "ENC(mentor)",
  "model_capability": "ENC(capability profile)",
  "prompt_profile_id": "ENC(prompt profile id)",
  "prompt_profile_version": "ENC(3)",
  "relationship_policy": "ENC(none)",
  "compaction_profile_id": "ENC(profile name)",
  "compaction_contract_fingerprint": "ENC(fingerprint)",
  "cache_policy": "ENC(cache policy)",
  "repetition_policy": "ENC(repetition policy)",
  "compaction_compat_tag": "6f5c2b1ad0e94f3182c7a6d5e4b39c81",
  "server_seq": 10402
}
```

> **Codex 통합 결정 필요:** `engine_profile`을 room에 인라인할지 별도 entity로 참조할지. 이 초안은 별도 entity + `engine_profile_ref` 참조로 그렸다. 여러 방이 같은 profile을 공유할 수 있으면 참조가 낫고, 방마다 다르면 인라인이 단순하다. Phase 0은 이 질문에 답할 데이터를 수집하지 않았다.

> **Codex 통합 결정 필요:** `relationship_policy = group`을 `PHONE_SPACE` 밖에서 만들 수 있는지. 사용자 결정 9에 따르면 호감도는 폰 전용이므로 다른 space가 이 값을 쓰는 것은 오류일 가능성이 높다.

---

## 5. Persona snapshot

동기화 대상은 persona를 추출·편집한 과정 전체가 아니라 **사용자가 확정한 versioned snapshot**이다.

```text
persona_snapshot_identity = (space_id, persona_snapshot_id, snapshot_revision)
```

| 필드 집합 | 내용 |
| --- | --- |
| Identity | ⬜ `space_id`, ⬜ `persona_snapshot_id`, ⬜ `snapshot_revision` |
| 내용 | 🔒 `description`, 🔒 `samples`, 🔒 `style_guide`, 🔒 `is_enabled` |
| Provenance | ⬜ `owner_space_id`, ⬜ `created_by_device_id`, ⬜ `created_at` |
| Compatibility | ⬜ `persona_schema_version`, 🔒 `content_fingerprint` |
| Extension | 🔒 `extensions` — `suppressedExpressions`, `sampleEvidence` 등 |

### 5.1 revision·ownership·extension 규칙

1. **snapshot 변경은 기존 revision을 덮어쓰지 않고 새 revision을 만든다.** 갱신은 `base_revision` CAS로 직렬화한다.
2. room profile은 AI request에 실제로 쓴 `persona_snapshot_id`와 `snapshot_revision`을 정확히 참조한다.
3. **write 권한은 `owner_space_id`가 결정한다.** `created_by_device_id`는 provenance이며 단독 권한 근거가 아니다.
4. **다른 플랫폼이 모르는 extension은 서버가 보존하며, 공통 필드 patch가 이를 삭제하면 안 된다.**

Android `PersonaStyle`의 저장 필드는 `description`·`samples`·`styleGuide`·`isEnabled`·`suppressedExpressions`·`sampleEvidence` 여섯 개다. 앞 넷은 canonical 공통 필드, 뒤 둘은 extension으로 옮긴다.

**Mac에 이 필드를 추가할 때는 `init(from:)`을 직접 구현해 `decodeIfPresent(...) ?? []`로 읽어야 한다.** Swift의 자동 합성 디코더는 프로퍼티 기본값을 적용하지 않으므로 옛 JSON에서 `keyNotFound`가 난다(E2EE 제안서 §1.3). 이는 schema가 아니라 구현 주의사항이지만 Phase 1 계약 test에 포함한다.

```json
{
  "space_id": "PHONE_SPACE",
  "persona_snapshot_id": "50000000-0000-4000-8000-000000000001",
  "snapshot_revision": 2,
  "owner_space_id": "PHONE_SPACE",
  "created_by_device_id": "80000000-0000-4000-8000-000000000002",
  "created_at": "2026-08-27T00:00:00Z",
  "persona_schema_version": 1,
  "description": "ENC(description)",
  "samples": "ENC(sample lines)",
  "style_guide": "ENC(style guide)",
  "is_enabled": "ENC(true)",
  "content_fingerprint": "ENC(fingerprint)",
  "extensions": {
    "android.suppressedExpressions": "ENC(opaque)",
    "android.sampleEvidence": "ENC(opaque)"
  },
  "server_seq": 10310
}
```

---

## 6. Context checkpoint

Context checkpoint는 provider cache가 아니라 **장기 대화 기억**이다.

```text
checkpoint_identity = (conversation_scope, checkpoint_id)
```

| 필드 집합 | 내용 |
| --- | --- |
| Identity | ⬜ `conversation_scope`, ⬜ `checkpoint_id` |
| Coverage | ⬜ `first_turn_id`, ⬜ `last_turn_id`, ⬜ `through_server_seq` |
| Payload | 🔒 `segments`, 🔒 `summary_text` |
| Compatibility | ⬜ `checkpoint_schema_version`, 🔒 `compaction_profile_id`, 🔒 `compaction_contract_fingerprint`, ⬜ `compaction_compat_tag` |
| Provenance | ⬜ `owner_space_id`, ⬜ `created_by_device_id`, ⬜ `created_at` |
| Concurrency | ⬜ `revision`, 갱신 요청의 `base_revision` |

### 6.1 generation authority 규칙

1. **원본 canonical message가 source of truth다.** checkpoint 생성 뒤에도 원본을 즉시 삭제하지 않는다.
2. 같은 범위 checkpoint의 생성·연장은 `base_revision` CAS로 직렬화한다.
3. **write 권한은 `owner_space_id`와 현재 generation authority가 결정한다.**
4. **호환 fingerprint가 다른 기기는 opaque summary로 읽을 수는 있어도 재요약하거나 연장하지 않는다.** 조용한 fallback을 금지한다.
5. provider cache lease와 checkpoint는 **별도 entity**다. cache 만료·삭제·credential 불일치가 장기 기억을 지우면 안 된다.

### 6.2 세 개의 호환성 필드

숫자 하나로는 부족하므로 세 필드를 분리한다.

| 필드 | 목적 |
| --- | --- |
| ⬜ `checkpoint_schema_version` | 직렬화된 checkpoint 구조의 version |
| 🔒 `compaction_profile_id` | 사람이 관리하는 정책 이름 |
| 🔒 `compaction_contract_fingerprint` | 기계가 계산하는 compatibility fingerprint |

fingerprint 입력은 합의문이 정한 대로 summary instruction 본문, threshold·verbatim window·refresh period·segment token budget, 실제 `maxOutputTokens`, transcript format version, model·thinking 설정, checkpoint range algorithm version이다. **canonical UTF-8·line ending·field order·직렬화 규칙이 두 플랫폼에서 같아야 한다.**

현재 prefix-cache fingerprint 구현은 Swift가 JSON key를 정렬하고 Android가 삽입 순서 JSON을 hash하므로 **재사용하지 않는다.**

### 6.3 `legacy_unversioned`

Phase 0에서 발견한 digest는 Mac 1개, phone 3개이며 **모두 policy 식별자가 없다.** tablet에는 없었다.

- version 정보가 없는 기존 digest는 ⬜ `compaction_profile_id = "legacy_unversioned"`로 격리한다.
- **현재 profile과 같다고 추정하지 않는다.**
- cross-device continuation 전에 (a) opaque read-only summary로만 소비, (b) 원본 message에서 재생성, (c) source-space owner만 이어쓰기 중 하나를 고른다.

> **Codex 통합 결정 필요:** 위 (a)·(b)·(c) 중 v1 선택. 대상이 4개뿐이므로 (b) 재생성 비용이 크지 않을 수 있으나, 재생성은 model 호출이므로 비용·결과 변화가 따른다.

```json
{
  "space_id": "MAC_SPACE",
  "room_id": "10000000-0000-4000-8000-000000000002",
  "worldline_id": null,
  "checkpoint_id": "60000000-0000-4000-8000-000000000001",
  "first_turn_id": "30000000-0000-4000-8000-000000000010",
  "last_turn_id": "30000000-0000-4000-8000-000000000042",
  "through_server_seq": 10390,
  "segments": "ENC(segments)",
  "summary_text": "ENC(summary)",
  "checkpoint_schema_version": 1,
  "compaction_profile_id": "ENC(legacy_unversioned)",
  "compaction_contract_fingerprint": null,
  "compaction_compat_tag": "0000000000000000000000000000legacy",
  "owner_space_id": "MAC_SPACE",
  "created_by_device_id": "80000000-0000-4000-8000-000000000001",
  "created_at": "2026-08-27T00:00:00Z",
  "revision": 1,
  "server_seq": 10391
}
```

---

## 7. Attachment와 avatar

### 7.1 R2 object metadata

첨부와 avatar는 **payload를 D1에 넣지 않고 R2에 두며, D1에는 metadata와 감싼 키만 둔다**(사용자 결정 2). D1의 행·문자열·BLOB당 2MB 한도 때문에 inline base64는 불가능하다.

| 필드 | 구분 |
| --- | --- |
| ⬜ `attachment_id` | identity |
| ⬜ `r2_object_key` | 내용과 무관한 난수 UUID 경로 |
| ⬜ `byte_size` | R2 객체 크기에서 어차피 드러난다 |
| ⬜ `kind` | `attachment` 또는 `avatar` |
| 🔒 `file_name` | |
| 🔒 `mime_type` | |
| 🔒 `wrapped_file_key` | scope 하위 키로 감싼 file key |
| ⬜ `created_at`, ⬜ `server_seq` | |

**R2 객체에 공개 접근 경로를 만들지 않는다.** 앱이 첨부를 요청하면 Worker가 device token을 검증한 뒤에만 단기 유효 경로를 발급하거나 중계한다. 기기 종속이 아니라 **계정에 속한 기기임이 증명되면 어느 기기에서든 접근 가능**하다.

### 7.2 12MB v1 상한

Phase 0 실측값이다.

| 항목 | Mac | phone | tablet |
| --- | ---: | ---: | ---: |
| 최대 첨부 | 2,618,357 | 157,678 | 174,199 |
| 최대 avatar | 1,391,214 | 6,593,776 | 274,146 |

**세 space의 관측값이 모두 12MB 미만이지만 이것은 영구적인 전체 상한의 증명이 아니다.** Mac 앱 자체에 첨부 상한이 없으므로 관측 최대값은 "지금까지 넣은 것 중 가장 큰 것"일 뿐이다.

따라서 상한은 관측값이 아니라 **규격으로** 정한다.

1. **v1은 양 플랫폼 공통 12MB 상한을 규격으로 둔다.** Mac 입력 경로에도 실제로 적용해야 하며, 상한 없는 현재 동작을 두고 문서에만 적는 것은 안 된다.
2. 상한 초과 파일은 **명시적으로 제외하고 사용자에게 알린다.** 방 전체를 조용히 누락하거나 업로드 중 실패하는 것은 금지한다.
3. **avatar도 첨부와 같은 경로·같은 상한·같은 시험 대상이다.** phone의 최대 avatar 6.59MB가 관측된 최대 첨부 2.6MB보다 2.5배 크므로, avatar를 "작은 이미지"로 가정하면 가장 큰 실제 payload를 놓친다.

```json
{
  "attachment_id": "70000000-0000-4000-8000-000000000001",
  "kind": "attachment",
  "r2_object_key": "obj/70000000-0000-4000-8000-0000000000ff",
  "byte_size": 2618357,
  "file_name": "ENC(file name)",
  "mime_type": "ENC(image/png)",
  "wrapped_file_key": "ENC(wrapped file key)",
  "created_at": "2026-08-27T00:00:00Z",
  "server_seq": 10420
}
```

---

## 8. Field patch

기존 room·message·profile의 필드 변경은 RFC 7396 merge patch가 아니라 **동기화 전용 patch envelope**를 쓴다.

```json
{
  "operation_id": "90000000-0000-4000-8000-000000000001",
  "op": "patch_room",
  "target": {
    "space_id": "MAC_SPACE",
    "room_id": "10000000-0000-4000-8000-000000000002",
    "worldline_id": null
  },
  "base_revision": 41,
  "set": {
    "status_message": "ENC(new status)"
  },
  "clear": [
    "music_title"
  ]
}
```

### 8.1 규칙

- ⬜ `base_revision`은 **필수**다. 서버는 현재 revision과 다르면 거부한다(§14 CAS).
- `set`은 값을 넣고, `clear`는 값을 비운다. **둘은 별개의 명시적 연산이다.**
- `clear`의 field path는 서버가 무엇을 지울지 알아야 하므로 **평문이다.** 값은 새지 않지만 어떤 필드가 언제 변경됐는지는 서버에 보인다(E2EE 제안서 §8.5).
- **whole-room·whole-message `PUT`을 금지한다**(§3.2).
- 현재 Swift·Kotlin storage codec은 바꾸지 않는다.

### 8.2 RFC 7396을 쓰지 않는 이유

Android codec은 `explicitNulls = false`이고 Swift의 여러 필드는 `decodeIfPresent(...) ?? false` 방식으로 읽힌다. **따라서 현재 저장 JSON만으로는 "필드 부재"와 "명시적으로 값을 비움"을 안정적으로 구별할 수 없다.** `null`을 삭제 명령으로 쓰는 merge patch로 되돌리지 않고 `set`/`clear`를 명시적으로 유지한다.

---

## 9. Tombstone

필드 clear와 entity 삭제는 **서로 다른 protocol**이다.

| Operation | 의미 |
| --- | --- |
| `delete_bubble` | 논리적 turn은 유지하고 화면 bubble 하나를 tombstone 처리 |
| `delete_turn` | 논리적 turn과 모든 child bubble을 tombstone 처리 |

**receiver는 배열 원소가 없다는 이유로 삭제를 추론하지 않는다.** tombstone에는 target identity, `operation_id`, `base_revision`, actor/device, server ordering을 담는다.

```json
{
  "operation_id": "90000000-0000-4000-8000-000000000002",
  "op": "delete_turn",
  "target": {
    "space_id": "PHONE_SPACE",
    "room_id": "10000000-0000-4000-8000-000000000001",
    "worldline_id": "20000000-0000-4000-8000-000000000001",
    "turn_id": "30000000-0000-4000-8000-000000000007"
  },
  "base_revision": 12,
  "actor_device_id": "80000000-0000-4000-8000-000000000002",
  "reverts_heart_changes": true,
  "created_at": "2026-08-27T00:00:00Z"
}
```

### 9.1 플랫폼 삭제 의미가 다르다

- Mac은 선택한 message와 같은 `turnId`를 공유하는 **모든 bubble**을 지운다.
- Android는 선택한 `message.id` **하나**만 지운다.

Android의 bubble 삭제는 turn과 현재 호감도 값은 남긴 채 첫 bubble의 `canonicalText` 또는 마지막 bubble의 `heartChanges` 근거만 없앨 수 있다. **따라서 canonical turn entity가 local bubble anchor와 독립적으로 이 값을 소유해야 한다.**

### 9.2 사용자 결정 반영

- 결정 10: **AI 답변은 턴 전체를 삭제한다.** 최초 활성화 버전은 `delete_turn`을 기본으로 한다.
- 결정 11: **하트도 되돌린다.** 단 되돌릴 `heart_changes` 기록이 없으면 삭제만 하고 하트는 건드리지 않는다(`reverts_heart_changes = false`).
- 결정 15: **수정·삭제는 첫 테스트에서 막아둔다.** 즉 이 절의 operation은 schema에 정의하되 Phase 5 초기에는 전송·수용하지 않는다.

`delete_turn`이 단톡방에서 실행되면 여러 화자의 bubble과 여러 참여자의 하트 변화가 **함께 원자적으로** 되돌아간다(결정 4·10·11 조합).

> **Codex 통합 결정 필요:** 마지막 bubble 삭제를 `delete_turn`으로 승격할지 headless turn을 만들지. 그리고 canonical 데이터를 local JSON으로 투영할 때 turn-level 필드(`canonical_text`·`heart_changes`)를 어느 bubble에 다시 anchor할지. 합의문이 미결로 남긴 항목이며 삭제 기능 활성화 전에 정해야 한다.

---

## 10. Durable outbox event envelope

모든 local 변경은 **local content와 outbox record가 하나의 복구 가능한 operation으로 durable해진 뒤** 업로드된다.

```json
{
  "operation_id": "90000000-0000-4000-8000-000000000003",
  "account_id": "a0000000-0000-4000-8000-000000000001",
  "device_id": "80000000-0000-4000-8000-000000000001",
  "op": "patch_room",
  "target_scope": {
    "space_id": "MAC_SPACE",
    "room_id": "10000000-0000-4000-8000-000000000002",
    "worldline_id": null
  },
  "base_revision": 41,
  "payload_ciphertext": "ENC(patch envelope)",
  "ciphertext_hash": "5f2c9a41b7e3d8460a1c2e5f7b9d0c3a4e6f8b1d2c4a6e8f0b3d5a7c9e1f2b40",
  "created_at": "2026-08-27T00:00:00Z",
  "attempt_count": 0,
  "committed_local": true,
  "server_seq": null
}
```

### 10.1 규칙

1. ⬜ `operation_id`는 **idempotency 키**다. 모든 remote write는 이 키 기준으로 idempotent해야 한다.
2. 시작 시 reconciliation은 **outbox record 없는 local content**와 **commit된 local content 없는 outbox record**를 모두 탐지해야 한다.
3. local write 성공을 호출자가 관측할 수 있어야 한다. **Android의 `renameTo(...) == false`를 성공으로 취급하면 안 된다.**
4. 정상 lifecycle flush는 위험을 줄일 뿐 crash·force-kill·전원 차단·persistence 전 process death를 보장하지 않는다.
5. D1은 operation·canonical row·change log를 **하나의 transaction**으로 적용한다. D1 `batch()`는 transactional하다.

### 10.2 재시도 시 암호문을 다시 만들지 않는다

랜덤 nonce 때문에 **같은 평문을 다시 암호화한 결과끼리 비교하면 안 된다.** outbox에 최초 생성한 ciphertext와 nonce를 저장하고, 같은 `operation_id`의 재시도는 **그 byte를 그대로 재사용**한다. ⬜ `ciphertext_hash`는 업로드·다운로드 byte 동일성 검사에만 쓴다(E2EE 제안서 §14).

---

## 11. Group과 worldline의 범위

**`worldline_id`는 nullable canonical storage axis이며 나중에 덧붙일 선택 기능이 아니다.** 단톡방과 세계선은 처음부터 canonical scope와 D1 백업 대상에 포함한다(사용자 결정 4).

**그러나 이것은 Mac·tablet이 group/worldline semantics를 이해하도록 만든다는 뜻이 아니다.**

근거는 코드다.

- Mac 모델에 `affection`·`heartChange`·`GroupChat`·`worldline` 정의가 **0건**이다.
- tablet flavor는 `ChatsScreen.kt`의 `BuildConfig.TABLET_MENTOR` 분기에서 "새 단톡방" 메뉴를 노출하지 않는다.
- `WorldlineState.participantHearts`는 Android 폰 전용 group state 안에 있다.

Phase 0 실측도 이와 일치한다. 단톡방·worldline은 `PHONE_SPACE`에만 있고(각 2개), Mac·tablet은 0개다.

따라서 범위는 다음과 같다.

| 항목 | 범위 |
| --- | --- |
| canonical schema | `worldline_id` 축과 group 필드를 **포함한다** |
| D1 백업 | phone 단톡방·세계선을 **포함한다** |
| Mac·tablet 표시 | **포함하지 않는다.** 폰 방은 다른 space에 숨긴다(결정 3) |
| Mac·tablet의 group semantics 구현 | **범위 밖** |
| 여러 기기의 호감도 공유 | **하지 않는다.** 하트는 `PHONE_SPACE` 백업 안에만 둔다(결정 9) |

결정 9는 **추가 조치가 필요 없다.** 하트가 `PHONE_SPACE` 안에만 존재하고 결정 3이 폰 방을 다른 space에서 숨기므로 자동으로 비공개가 된다.

---

## 12. 결정적인 legacy `turn_id`

Importer는 **기존 random-ID migration을 호출하거나 원본 JSON을 쓰면 안 된다.**

1. **기존 non-null `turnId`는 모두 보존한다.**
2. 기존 `turnId`가 정확히 같은 bubble끼리만 묶는다.
3. AI bubble의 연속 구간은 **모두 `turnId == nil`인 동안에만** 묶고 non-null ID 직전에 끊는다.
4. nil AI 구간의 canonical `turn_id`는 **첫 `message.id`**에서 결정한다.
5. nil 사용자 메시지의 canonical `turn_id`는 **자기 `message.id`**에서 결정한다.
6. `speakerRoomId`는 bubble metadata로 보존하고 **turn 경계로 사용하지 않는다.**

같은 원본을 반복 import해도 같은 결과를 내며 원본 파일은 바뀌지 않는다.

### 12.1 Phase 0 실측 분포

| 항목 | Mac | phone | tablet |
| --- | ---: | ---: | ---: |
| `turnId == nil`이 있는 파일 | 3 | 0 | 0 |
| non-null `turnId`가 있는 파일 | 7 | 10 | 2 |
| nil과 non-null 공존 파일 | 0 | 0 | 0 |
| AI 구간의 서로 다른 non-null turn ID `2+` | 1 | 0 | 0 |
| nil 파일과 `2+` 구간이 겹치는 파일 | **0** | 0 | 0 |

legacy nil은 **Mac에만, 3개 파일에** 있다. 위험 조합이 겹치는 파일은 0개다. 다만 **이 파일들을 `known safe`로 부르지 않고 `unknown`으로 유지한다.**

### 12.2 구현 경고

**Mac의 `loadMessagesForRoom(roomId:)`와 Android의 `loadMessages(...)`는 단순 read API가 아니다.** 두 함수 모두 내부에서 `migrateLegacyTurns`를 실행하고 변경이 감지되면 같은 원본 파일을 다시 쓴다.

importer는 이 일반 loader를 호출하지 말고 **raw bytes 전용 read/decode 경로**를 사용해야 한다. Phase 0 조사도 같은 이유로 이 함수들을 호출하지 않았다.

---

## 13. `character_id` 도입 시 이전해야 할 다섯 참조

초기 Phase 0~5는 **room 중심 동기화**이므로 standalone character entity를 노출하지 않아도 된다. 이 동안 room profile과 persona snapshot은 `conversation_scope`에 종속되며, **표시 이름이 같은 profile을 같은 캐릭터로 추론하지 않는다.**

```text
character_identity = (space_id, character_id)
```

친구 탭의 출처 공유, 여러 room에서 같은 profile 재사용, standalone profile 편집, room 밖 group participant 공유를 활성화하려면 먼저 아래를 확정해야 한다.

### 13.1 이전 대상 다섯 참조

`character_id`를 도입할 때 다음 **다섯 개**의 room UUID 참조를 **같은 mapping으로 결정적으로 이전한다.**

| # | 참조 | 잃으면 안 되는 것 |
| ---: | --- | --- |
| 1 | `GroupParticipant.roomId` | 참여자 귀속 |
| 2 | `ParticipantHeart.participantRoomId` | 현재 호감도 귀속 |
| 3 | `ChatMessage.speakerRoomId` | 화자 귀속 |
| 4 | `MessageReaction.participantRoomId` | 반응 귀속 |
| 5 | `MessageHeartChange.participantRoomId` | 호감도 변화 기록 귀속 |

**다섯 참조의 부분 migration은 금지한다.** 화자·반응·현재 호감도·호감도 변화 기록의 귀속이 모두 보존되는 fixture·rollback test를 통과해야 한다.

Phase 0 실측 규모: phone에서 group participant 참조 4개, `speakerRoomId` 메시지 411개, reaction 2개, heart change 237개.

### 13.2 이전 대상이 아닌 것

| 항목 | 이유 |
| --- | --- |
| `GroupChatState.participantRoomIds` | `participants`에서 계산되는 **파생값** |
| `GroupParticipantSeed` | **비영속** 생성 입력 |
| `ConversationScope.roomId` | 방 자체의 identity |
| `InkDocument.roomId` | 방 자체의 identity |

`display_name`은 표시용이며 identity가 아니다. `character_id`는 room UUID와 별도로 유지되는 stable ID다.

이 계약은 **초기 room-only Shadow Upload의 blocker는 아니지만** 친구·독립 profile 공유 기능의 선행 gate다.

---

## 14. D1 schema — primary key, unique key, CAS

> **Codex 통합 결정 필요:** 아래는 초안이며 실제 `CREATE TABLE`은 Phase 1 확정 후에 만든다. 이 문서는 Cloudflare 리소스를 만들지 않는다.

### 14.1 키 설계

| 테이블 | Primary key | Unique key | 비고 |
| --- | --- | --- | --- |
| `account` | `account_id` | — | |
| `device` | `device_id` | `(account_id, device_id)` | `revoked_at`으로 무효화 |
| `room` | `(account_id, space_id, room_id)` | — | `space_id`를 키에 넣어 space 간 UUID 충돌을 막는다 |
| `worldline` | `(account_id, space_id, room_id, worldline_id)` | — | |
| `turn` | `(account_id, space_id, room_id, worldline_id, turn_id)` | — | `worldline_id`는 null 대신 sentinel 사용(아래) |
| `bubble` | `(…scope…, turn_id, message_id)` | `(…scope…, message_id)` | `bubble_order`는 unique가 **아니다** |
| `persona_snapshot` | `(space_id, persona_snapshot_id, snapshot_revision)` | — | revision마다 행이 늘어난다 |
| `checkpoint` | `(…scope…, checkpoint_id)` | — | |
| `attachment` | `attachment_id` | `r2_object_key` | |
| `operation_log` | `operation_id` | — | idempotency |

### 14.2 nullable `worldline_id`를 키에 쓰는 문제

SQLite/D1에서 **`NULL`은 서로 같지 않으므로 primary key나 unique 제약에 그대로 넣으면 중복 행이 생긴다.** `worldline_id`가 null인 기본 세계선이 여러 번 삽입될 수 있다.

해결책은 둘 중 하나다.

- **(a) sentinel 값**: 기본 세계선을 `00000000-0000-4000-8000-000000000000` 같은 고정 UUID로 저장하고 애플리케이션 경계에서 null과 변환한다.
- **(b) 생성 컬럼**: `worldline_key = COALESCE(worldline_id, '')`를 만들어 키에 쓴다.

이 초안은 **(a)를 기본으로 그렸다.** 다만 E2EE 제안서 §7.2의 AAD field 6은 `worldline_id`를 **nullable UUID(`presence = 0`)**로 정의한다. 즉 **저장 표현과 AAD 표현이 달라진다.** sentinel을 AAD에도 쓰면 AAD 규격을 고쳐야 하고, AAD만 null로 두면 두 표현 사이 변환 규칙을 명시해야 한다.

> **Codex 통합 결정 필요 (중요):** (a)와 (b) 중 선택, 그리고 선택한 표현이 E2EE AAD의 nullable 정의와 어떻게 대응하는지. **이 대응을 정하지 않으면 같은 대화가 저장 경로와 암호화 경로에서 다른 scope로 취급될 수 있다.**

### 14.3 revision과 CAS 조건

모든 mutable entity(`room`, `persona_snapshot`, `checkpoint`, `engine_profile`)는 ⬜ `revision`을 가진다.

```sql
UPDATE room
   SET status_message = ?, revision = revision + 1, server_seq = ?
 WHERE account_id = ? AND space_id = ? AND room_id = ?
   AND revision = ?;          -- base_revision. 0 row 갱신이면 conflict
```

- 갱신은 **`base_revision`이 현재 `revision`과 정확히 같을 때만** 성공한다.
- 영향 행이 0이면 **conflict로 거부**하고 클라이언트가 최신 상태를 받아 다시 만든다.
- `revision` 증가·canonical row 갱신·`operation_log` 삽입·change log 기록은 **하나의 `batch()` transaction**으로 적용한다.
- 같은 `operation_id`가 이미 `operation_log`에 있으면 **재적용하지 않고 기존 결과를 반환**한다(idempotency).

`server_seq`는 Worker가 계정 단위로 매기는 단조 증가 값이며 클라이언트 pull의 cursor가 된다.

> **Codex 통합 결정 필요:** `server_seq`를 account 단위로 할지 scope 단위로 할지. account 단위는 cursor가 하나여서 단순하지만 모든 write가 한 시퀀스를 경합한다. Workers Free의 10ms CPU 한도 안에서 동작하는지는 아직 측정하지 않았다.

---

## 15. 미결 항목 정리 — Codex 통합 결정 필요

| # | 절 | 항목 |
| ---: | --- | --- |
| 1 | §0.2 | 암호화 필드의 D1 컬럼 명명 규칙(`title` vs `title_enc`) |
| 2 | §1.2 | 한 `space_id`에 기기가 둘 이상 연결될 수 있는지 |
| 3 | §2 | `bubble_order`의 폭과 새 bubble 증가 폭 |
| 4 | §3.3 | `extensions` 키 명명 규칙과 봉투 단위(키별 vs 통째) |
| 5 | §4 | `engine_profile`을 room에 인라인할지 별도 entity로 둘지 |
| 6 | §4 | `relationship_policy = group`을 `PHONE_SPACE` 밖에서 허용할지 |
| 7 | §6.3 | `legacy_unversioned` digest 4개의 처리 방식 (a/b/c) |
| 8 | §9.2 | 마지막 bubble 삭제의 승격 여부와 turn-level 필드 재anchor 위치 |
| 9 | **§14.2** | **nullable `worldline_id`의 저장 표현과 E2EE AAD 표현의 대응** |
| 10 | §14.3 | `server_seq`의 단위(account vs scope) |

**9번이 가장 시급하다.** 저장 경로와 암호화 경로가 같은 대화를 다른 scope로 취급하면 복호화가 실패하거나, 더 나쁘게는 서로 다른 세계선의 데이터가 같은 키로 처리된다.

### 15.1 이 초안이 확정하지 않은 것

- 실제 `CREATE TABLE` DDL과 인덱스
- Worker API endpoint 목록과 요청·응답 형식
- pull cursor·페이지 크기·충돌 해소 UX
- Phase 4 remote replica의 별도 store 구조
- Mac 방 목록 6개와 메시지 파일 13개의 차이 원인 — Phase 0이 **후속 확인 대상으로 남긴 항목**이며 임의 삭제하지 않는다

## 16. Phase 1 완료 조건

이 초안이 계약으로 확정되려면 다음이 필요하다.

1. §15의 미결 10건에 대한 Codex 통합 결정
2. 각 entity의 fixture와 acceptance test 작성
3. E2EE 제안서 §13의 contract test와 이 schema의 결합 검증 — 특히 AAD scope 대응(§14.2)
4. 비파괴 importer가 §12 규칙으로 같은 결과를 반복 생성하는지 확인
5. Mac `PersonaStyle` custom decoder 하위호환 확인(§5.1)

**위 조건이 충족되기 전에는 이 문서를 구현 규격으로 사용하지 않는다.** Phase 2 합성 시험과 Phase 3 실데이터 업로드는 각각의 게이트를 별도로 통과해야 하며, 이 초안은 어느 쪽도 승인하지 않는다.
