# Phase 1 Canonical Sync Schema 통합 초안

## 문서 상태

- 작성일: 2026-08-27
- 작성: Claude Code (초안), Codex (통합 결정·보정)
- 상태: **§15 통합 결정 완료 / contract fixture 작성 전 / 구현 승인 아님**
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
  8 = device, 9 = operation, A = account, B = character,
  C = engine profile
```

실제 구현은 표준 random UUID v4를 쓴다. 위 규칙은 문서 예시 전용이다. **예시를 포함한 모든 UUID는 E2EE 제안서 §12.3의 대문자 하이픈 36-byte ASCII 형식을 따른다.** importer와 Worker는 소문자를 자동 변환하지 않고 거부한다.

### 0.2 암호화 표기

E2EE 제안서 §8이 정한 경계에 따라, **내용 필드는 봉투 base64로 저장하고 metadata만 평문으로 둔다.** 이 문서는 어느 필드가 어느 쪽인지만 표시하고 암호 규격은 정의하지 않는다.

- 🔒 = E2EE 제안서 §8.2의 암호화 대상. D1에는 봉투 base64 문자열로 들어간다.
- ⬜ = E2EE 제안서 §8.3의 평문 metadata.

예시 JSON의 봉투 값은 `"ENC(...)"` 형태의 **자리표시자**다. 실제 봉투 byte 형식은 E2EE 제안서 §7.1에 있다.

**통합 결정:** D1에서 암호문을 담는 컬럼은 반드시 `_enc` 접미사를 쓴다(`title_enc`, `status_message_enc`). API의 canonical field path와 문서 JSON 예시는 원래 이름(`title`, `status_message`)을 유지한다. 즉 `_enc`는 저장 컬럼 이름이며 patch path가 아니다. 이 구분으로 암호문을 평문처럼 처리하거나 평문을 암호문 컬럼에 넣는 실수를 막는다.

### 0.3 시각과 순서

- ⬜ `created_at`·`updated_at`은 RFC 3339 UTC 문자열이다.
- ⬜ `server_seq`는 Worker가 매기는 `1...2^53-1` 범위의 단조 증가 정수이며 정렬의 권위 원본이다.
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

Phase 0 집계 보고서에 실제 저장된 `source_space` 값은 다음과 같다.

| Phase 0 report 값 | canonical `space_id` | 처리 |
| --- | --- | --- |
| `MAC_SPACE` | `MAC_SPACE` | 이미 canonical이므로 그대로 유지 |
| `PHONE_SPACE` | `PHONE_SPACE` | 이미 canonical이므로 그대로 유지 |
| `tablet` | `TABLET_SPACE` | 관측된 legacy alias를 한 번 명시적으로 변환 |

Importer는 canonical 세 값은 그대로 허용하고, 관측된 legacy alias `tablet`만 `TABLET_SPACE`로 변환한다. `mac`·`phone`·`Tablet`·`TABLET` 같은 미등록 철자를 대소문자 보정하거나 임의 fallback으로 받아들이지 않는다. D1·AAD·outbox에는 canonical enum만 넣는다.

### 1.2 device

```json
{
  "account_id": "A0000000-0000-4000-8000-000000000001",
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

**통합 결정:** 한 `space_id`에 여러 기기를 허용한다. `space_id`는 물리 기기 identity가 아니라 동작·출처 영역이다. 기기 교체와 향후 같은 종류 기기 추가 때문에 `UNIQUE(account_id, space_id)`를 두지 않는다. 동시 write는 device 수 제한이 아니라 `base_revision` CAS, active writer, generation authority로 통제한다.

---

## 2. `bubble_order` 규칙

합의문의 확정 규칙을 schema 관점으로 옮긴다.

1. ⬜ `bubble_order`는 `0...9,007,199,254,740,991` 범위의 정수이며 **최초 canonical import에서 원본 JSON 배열의 0-based index로 확정**한다.
2. 확정된 mapping은 `(conversation_scope, message_id)`에 대해 **불변**이다. 같은 원본을 다시 import해도 같은 값을 낸다.
3. **빈 번호를 허용한다.** 삭제로 번호가 듬성듬성해지는 것은 정상이며, 빠진 번호를 누락 데이터나 삭제 증거로 해석하지 않는다.
4. 삭제·정렬·재동기화 뒤에도 기존 bubble을 재번호 매기지 않는다.
5. 새 bubble은 해당 conversation scope에서 **tombstone을 포함해 지금까지 배정된 모든 `bubble_order`의 최대값에 1을 더한 값**을 받는다. 살아 있는 bubble만 세지 않는다. 계획적으로 간격을 두지 않으며 기존 순서를 바꾸지 않는다. 한 번도 배정된 적 없는 scope의 첫 값은 0이다.

`bubble_order`는 E2EE 제안서 §7.2의 AAD field 10에 포함되므로, **확정 후 값을 바꾸면 기존 암호문을 복호화할 수 없다.** 이 문서의 불변 규칙은 표시 순서 문제가 아니라 복호화 가능성 문제다.

중간 삽입이 필요한 기능(메시지 편집 등)은 별도 stable ordering 규격을 먼저 정한 뒤에 연다.

E2EE AAD에는 이 값을 UInt64BE로 인코딩하지만 v1의 유효 범위는 JavaScript `Number`의 안전한 정수 상한(`2^53-1`)으로 제한한다. D1은 더 큰 정수를 담을 수 있어도 Worker 경계에서 정밀도를 잃을 수 있기 때문이다. 범위를 넘기기 전에 write를 fail-closed로 거부한다.

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
| `engine_profile_ref` | ⬜ canonical metadata (§4) | exact immutable revision reference |
| `persona_snapshot_ref` | ⬜ canonical metadata (§5) | exact immutable revision reference |
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
  "account_id": "A0000000-0000-4000-8000-000000000001",
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
    "engine_profile_id": "C0000000-0000-4000-8000-0000000000E1",
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
    "android.room_profile.base_affection": "ENC(opaque extension)"
  }
}
```

`extensions`는 **다른 플랫폼이 모르는 필드를 그대로 보존하는 자리**다. 키는 소유 플랫폼을 접두사로 붙여 충돌을 막는다.

**통합 결정:** extension key는 `<owner>.<entity>.<field>` 형식의 소문자 dotted namespace를 쓴다. 각 segment는 `[a-z][a-z0-9_]*`이며 예시는 `android.room_profile.base_affection`이다. 값은 **key마다 별도 봉투로 암호화**하고 patch도 key 단위로 수행한다. 서버와 모르는 클라이언트는 key와 암호문 byte를 해석하지 않고 그대로 보존한다. extension 전체를 한 봉투로 묶어 known key 하나를 고칠 때 unknown key까지 재암호화하는 방식은 금지한다.

**2026-08-28 확정 — 논리 entity와 D1 물리 table.** `extension_field`는 모든 owner에 공통인 **논리적 family 이름**이며, D1에서 서로 다른 owner identity를 nullable column과 polymorphic FK로 한 table에 억지로 합치지 않는다. owner마다 자신의 실제 primary key를 그대로 앞에 둔 물리 table을 사용한다.

| 논리 owner | D1 물리 table | Primary key와 parent 경계 | 단계 |
| --- | --- | --- | --- |
| `room` | `room_extension_field` | `(account_id, space_id, room_id, extension_key)`; 같은 key의 `room` FK | M03 |
| `turn` | `turn_extension_field` | `(account_id, space_id, room_id, worldline_key, turn_id, extension_key)`; 같은 key의 `turn` FK | M03 |
| `bubble` | `bubble_extension_field` | `(account_id, space_id, room_id, worldline_key, turn_id, message_id, extension_key)`; 같은 key의 `bubble` FK | M03 |
| `persona_snapshot` | `persona_snapshot_extension_field` | persona snapshot의 실제 revision identity + `extension_key`; 같은 owner FK | M04 |

- M03의 owner set은 그 시점에 존재하는 `room`·`turn`·`bubble` 세 종류다.
- 각 물리 table은 `owner_type`, serialized `owner_key`, JSON identity blob, sentinel UUID를 두지 않는다. table 자체가 owner type이고 composite FK가 tenant·scope·owner 존재를 실제로 강제한다.
- 각 extension row는 owner identity·`extension_key`·opaque envelope만 가진다. 독립 `revision`·`server_seq`·`updated_at`을 두지 않으며 owner row가 CAS와 ordering의 유일한 source다.
- envelope column은 owner patch에 포함된 key 하나의 opaque 값을 그대로 저장한다. extension 전용 operation을 만들지 않으며 handler는 검증된 owning operation에서 어느 table을 쓸지 결정한다.
- `clear`의 row 삭제와 patch 원자성은 handler 단계다. DDL trigger가 ciphertext를 해석하거나 extension 의미를 추론하지 않는다.
- 향후 새 canonical owner가 extension을 필요로 하면 기존 table을 nullable axis로 rebuild하지 않고 해당 owner 전용 table을 그 owner의 migration 단계에 추가한다.

### 3.4 Turn과 bubble canonical 필드

초안에서 identity만 있고 내용 entity가 빠져 있었으므로 다음 ownership을 확정한다.

| Entity | 필드 | 분류 |
| --- | --- | --- |
| turn | `account_id`, conversation scope, `turn_id` | ⬜ identity |
| turn | `canonical_text`, `heart_changes` | 🔒 turn-level source of truth |
| turn | `generation_profile_ref`, `fallback_reason` | 🔒 실제 생성 계약 provenance |
| turn | `created_by_device_id`, `created_at`, `revision`, `server_seq` | ⬜ provenance·metadata·CAS |
| bubble | conversation scope, `turn_id`, `message_id`, `bubble_order` | ⬜ identity·order |
| bubble | `sender`, `kind`, `text`, `speaker_ref`, `reactions` | 🔒 content·relationship edge |
| bubble | `attachment_ref` | ⬜ R2 identity·byte size만; filename·MIME·payload는 🔒 |
| bubble | `timestamp`, `revision`, `server_seq` | ⬜ metadata·CAS |

`canonical_text`와 `heart_changes`를 bubble에 중복 저장하지 않는다. 기존 local JSON으로 내릴 때만 §9.3의 anchor 규칙으로 투영한다. `speaker_ref`·reaction·heart target의 암호화 경계는 §13.2를 따른다. message edit가 비활성인 초기 Phase 5에서도 `revision`은 tombstone CAS와 future compatibility를 위해 유지한다.

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
| ⬜ `profile_revision` | immutable version identity |
| ⬜ `compaction_compat_tag` | 서버가 equality만 비교하는 keyed 태그 |

`relationship_policy`의 허용값은 `none`·`personal`·`group` 세 가지다.

`mode`·`model_capability`·`compaction_profile_id`·`compaction_contract_fingerprint`는 E2EE 제안서 §8.2의 암호화 대상이다. 서버가 호환성 equality만 판정해야 하는 경우 실제 값 대신 §8.4의 `compaction_compat_tag`(평문)를 쓴다.

**반복 제어는 persona extension으로 가장하지 않고 여기 `repetition_policy`에서 계약한다.** Android의 `companionRepetitionControlEnabled`는 저장 필드가 아니라 method 인자이고 `repetitionAdviceFromConversation`은 runtime 계산 결과이므로 canonical 저장 대상이 아니다.

지원하지 않는 profile을 만난 기기는 **조용히 fallback하지 않는다.** 사용자 결정 8에 따라 방 진입 시 1회 또는 방 목록에서 차이를 알린 뒤, 그 기기에 등록된 명시적 fallback profile로 답변할 수 있다. 이때 AI turn은 원래 room profile이 아니라 실제 사용한 `generation_profile_ref`와 암호화된 `fallback_reason`을 저장한다. 지원 불가를 감지했는데 고지·등록된 fallback이 없으면 fail-closed로 전송을 막는다.

```json
{
  "account_id": "A0000000-0000-4000-8000-000000000001",
  "space_id": "MAC_SPACE",
  "engine_profile_id": "C0000000-0000-4000-8000-0000000000E1",
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

**통합 결정:** `engine_profile`은 별도 versioned entity로 두고 room은 `(engine_profile_id, profile_revision)`을 정확히 참조한다. profile revision은 immutable이다. 변경은 기존 행을 덮어쓰지 않고 새 revision을 만든 뒤, 대상 room의 reference를 field patch로 바꾼다. 여러 room이 같은 revision을 참조할 수 있지만 한 room의 변경이 다른 room에 암묵적으로 전파되어서는 안 된다.

**2026-08-28 확정 — revision과 room reference의 물리 경계.** `profile_revision`은 `1...2^53-1`이며 engine profile row는 D1 `UPDATE`를 거부하는 immutable revision이다. 별도 engine head table은 두지 않는다. Room의 engine/persona reference는 서버가 exact-revision FK를 검사해야 하므로 암호문이 아니라 평문 canonical metadata다. D1은 기존 room과 child graph를 rebuild하지 않고 다음 1:1 table로 정규화한다.

```text
room_ai_state_ref PK/FK = (account_id, space_id, room_id)
```

- engine pair는 `(engine_profile_id, engine_profile_revision)` 둘 다 null 또는 둘 다 non-null이고, non-null이면 같은 account/space의 exact engine revision을 FK로 참조한다.
- persona pair도 `(persona_snapshot_id, persona_snapshot_revision)` 둘 다 null 또는 둘 다 non-null이고, 같은 account/space의 exact snapshot revision을 FK로 참조한다.
- 두 pair가 모두 null이면 row를 삭제해도 되며, M06 handler는 room revision CAS와 reference row 변경을 같은 batch에 넣는다.
- 이것은 logical room object를 D1에서 두 행으로 정규화한 표현일 뿐 wire projection에서는 room reference로 합쳐서 내려준다.

**통합 결정:** v1에서 `relationship_policy = group`은 `PHONE_SPACE`에만 허용한다. 이는 group/worldline과 하트가 PHONE_SPACE 백업 안에만 존재한다는 사용자 결정 4·9의 경계다.

**2026-08-28 검사 경계 보정(Claude Code):** `relationship_policy`는 §4 표에서 이미 🔒(암호화 대상)이므로 **Worker가 이 값 자체를 읽거나 검사할 수 없다.** "Worker와 client 양쪽에서 거부한다"는 이전 표현은 두 계층이 같은 것을 검사한다고 오해할 수 있어 다음으로 나눈다.

- **Client**: 복호화한 `relationship_policy` enum(`none`·`personal`·`group`)과 `PHONE_SPACE` 제약을 실제 값 기준으로 검사한다. `group`을 다른 space의 engine profile에 넣지 않는 책임은 client에 있다.
- **Worker**: 암호화된 정책 값은 읽지 못하고, **평문 entity·space·권한 경계만** 검사한다. 구체적으로는 `create_group_state`·`patch_group_state`·`create_worldline`·`patch_worldline`이 `PHONE_SPACE` 밖에서 오면 거부한다. 이것은 group/worldline **entity 자체**의 space 제약이지 `relationship_policy` 값 검사가 아니다.
- **한계**: Worker는 `engine_profile`의 암호화된 `relationship_policy`가 실제로 `group`인지, 혹은 client가 다른 space에서 `group`을 잘못 설정했는지 **검증할 수 없다.** v1은 이 위협을 client 정직성에 의존하는 것으로 받아들인다. 서버 측 강제가 필요해지면 §8.4의 `compaction_compat_tag`처럼 값 자체는 숨기되 정책 class만 구분하는 keyed tag를 추가로 도입해야 한다.

---

## 5. Persona snapshot

동기화 대상은 persona를 추출·편집한 과정 전체가 아니라 **사용자가 확정한 versioned snapshot**이다.

```text
persona_snapshot_identity = (account_id, space_id, persona_snapshot_id, snapshot_revision)
```

| 필드 집합 | 내용 |
| --- | --- |
| Identity | ⬜ `account_id`, ⬜ `space_id`, ⬜ `persona_snapshot_id`, ⬜ `snapshot_revision` |
| 내용 | 🔒 `description`, 🔒 `samples`, 🔒 `style_guide`, 🔒 `is_enabled` |
| Provenance | ⬜ `owner_space_id`, ⬜ `created_by_device_id`, ⬜ `created_at` |
| Compatibility | ⬜ `persona_schema_version`, 🔒 `content_fingerprint` |
| Extension | 🔒 `extensions` — `suppressedExpressions`, `sampleEvidence` 등 |

### 5.1 revision·ownership·extension 규칙

1. **snapshot 변경은 기존 revision을 덮어쓰지 않고 새 revision을 만든다.** `persona_snapshot_head`의 갱신을 `base_revision` CAS로 직렬화한다.
2. room profile은 AI request에 실제로 쓴 `persona_snapshot_id`와 `snapshot_revision`을 정확히 참조한다.
3. **write 권한은 `owner_space_id`가 결정한다.** `created_by_device_id`는 provenance이며 단독 권한 근거가 아니다.
4. **다른 플랫폼이 모르는 extension은 서버가 보존하며, 공통 필드 patch가 이를 삭제하면 안 된다.**

**2026-08-28 확정 — snapshot/head CAS.** `snapshot_revision`은 `1...2^53-1`이고 immutable snapshot row는 D1 `UPDATE`를 거부한다. v1에서 `owner_space_id = space_id`를 강제하며 다른 space가 소유하는 snapshot은 만들지 않는다. `persona_snapshot_head`는 `(account_id, space_id, persona_snapshot_id)` 하나에 `current_snapshot_revision`만 저장하고 이것이 head CAS version을 겸한다.

- 최초 `create_persona_snapshot`은 `base_revision = 0`, `snapshot_revision = 1`이어야 하며 immutable row와 head를 함께 만든다.
- 후속 생성은 `base_revision = 현재 current_snapshot_revision`, `snapshot_revision = base_revision + 1`이어야 하며 새 immutable row 삽입과 head 전진을 같은 M06 transaction에서 수행한다.
- 별도 mutable `head_revision`을 두지 않는다. idempotency와 concurrent create rollback은 M06 operation ledger가 담당한다.
- `persona_snapshot_extension_field`는 snapshot exact revision을 owner로 하며 owner identity·key·envelope만 가진다.

Android `PersonaStyle`의 저장 필드는 `description`·`samples`·`styleGuide`·`isEnabled`·`suppressedExpressions`·`sampleEvidence` 여섯 개다. 앞 넷은 canonical 공통 필드, 뒤 둘은 extension으로 옮긴다.

**Mac에 이 필드를 추가할 때는 `init(from:)`을 직접 구현해 `decodeIfPresent(...) ?? []`로 읽어야 한다.** Swift의 자동 합성 디코더는 프로퍼티 기본값을 적용하지 않으므로 옛 JSON에서 `keyNotFound`가 난다(E2EE 제안서 §1.3). 이는 schema가 아니라 구현 주의사항이지만 Phase 1 계약 test에 포함한다.

```json
{
  "account_id": "A0000000-0000-4000-8000-000000000001",
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
    "android.persona_style.suppressed_expressions": "ENC(opaque)",
    "android.persona_style.sample_evidence": "ENC(opaque)"
  },
  "server_seq": 10310
}
```

---

## 6. Context checkpoint

Context checkpoint는 provider cache가 아니라 **장기 대화 기억**이다.

```text
checkpoint_identity = (account_id, conversation_scope, checkpoint_id)
```

| 필드 집합 | 내용 |
| --- | --- |
| Identity | ⬜ `conversation_scope`, ⬜ `checkpoint_id` |
| Coverage | ⬜ `first_turn_id`, ⬜ `last_turn_id`, ⬜ `through_server_seq` |
| Payload | 🔒 `segments`, 🔒 `summary_text` |
| Compatibility | ⬜ `checkpoint_schema_version`, 🔒 `compaction_profile_id`, 🔒 `compaction_contract_fingerprint`, ⬜ `compaction_compat_tag` |
| Provenance | ⬜ `owner_space_id`, ⬜ `created_by_device_id`, ⬜ `created_at` |
| Concurrency | ⬜ `revision`, 갱신 요청의 `base_revision` |

Checkpoint는 turn·bubble과 같은 conversation scope 규칙을 쓴다. 따라서 `worldline_id = null`인 default checkpoint는 세 canonical space에서 허용하지만, non-null named-worldline checkpoint는 `PHONE_SPACE`에서만 허용한다. Worker의 공통 room-scoped target validator와 D1 checkpoint CHECK가 같은 규칙을 강제해야 한다.

`first_turn_id`와 `last_turn_id`는 둘 다 null이거나 둘 다 non-null이다. non-null이면 checkpoint와 같은 scope의 turn을 각각 composite FK로 참조한다. `through_server_seq`는 M06 전에는 null을 허용하고, 값이 있으면 `1...2^53-1`이다. legacy unversioned digest도 같은 table을 쓰며 null range/sequence를 허용한다. checkpoint `revision`은 0부터 시작하는 mutable CAS version이고 create는 base revision 없이 revision 0을 만들며 patch가 현재 revision과 `base_revision`을 비교한다.

`owner_space_id = space_id`를 v1에서 강제하고 `created_by_device_id`는 같은 account의 device provenance로 저장한다. generation authority의 실제 write 허용 판정은 handler 책임이다.

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

- version 정보가 없는 기존 digest는 🔒 `compaction_profile_id = "legacy_unversioned"`로 격리한다.
- **현재 profile과 같다고 추정하지 않는다.**
- v1은 기존 digest를 **opaque read-only summary로만 보존**하고 이어쓰기·재요약하지 않는다.
- 새 versioned checkpoint가 실제로 필요해지는 시점에만 canonical 원본 message에서 새 checkpoint를 만든다. 기존 digest를 변환하거나 그 결과로 덮어쓰지 않는다.
- import만을 위한 model 호출은 하지 않는다. 기존 4개 digest의 비용·결과를 임의로 바꾸지 않기 위해서다.

```json
{
  "account_id": "A0000000-0000-4000-8000-000000000001",
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
| ⬜ `origin_space_id` | 생성 출처·권한 metadata, key에는 미포함 |
| ⬜ `kind` | `attachment` 또는 `avatar` |
| ⬜ `state` | `allocated`, `uploaded`, `ready`, `abandoned`, `tombstoned`, `garbage_collected` |
| ⬜ `source_byte_size` | 암호화 전 원문 크기, `1...12,582,912` |
| ⬜ `ciphertext_byte_size` | binary R2 envelope 크기, 정확히 source + 34 |
| ⬜ `ciphertext_hash` | lowercase SHA-256 hex 64자, byte 동일성 확인용 |
| ⬜ `key_generation` | v1은 정확히 `1` |
| 🔒 `file_name` | |
| 🔒 `mime_type` | |
| 🔒 `wrapped_file_key` | scope 하위 키로 감싼 file key |
| ⬜ `created_at`, ⬜ `server_seq` | |

**R2 객체에 공개 접근 경로를 만들지 않는다.** 앱이 첨부를 요청하면 Worker가 device token을 검증한 뒤에만 단기 유효 경로를 발급하거나 중계한다. 기기 종속이 아니라 **계정에 속한 기기임이 증명되면 어느 기기에서든 접근 가능**하다.

**2026-08-28 확정 — identity에서 `space_id`의 위치.** attachment의 canonical identity와 D1 primary key는 **`(account_id, attachment_id)`**이며 `space_id`를 포함하지 않는다(§14.1과 일치).

- ⬜ `origin_space_id`는 **생성 출처 기록과 device 권한 검사용 평문 metadata**로 저장하되 primary·unique key에는 넣지 않는다.
- sync operation의 `create_attachment` target에는 `space_id`와 `attachment_id`만 온다. **`room_id`와 `worldline_id`는 금지**한다(Worker API 초안 §4.1.1).
- 다운로드 권한은 같은 account의 유효한 device token으로 판정한다. 한 첨부가 여러 방에서 참조될 수 있으므로 room UUID를 identity에 억지로 넣지 않는다.

M05 D1은 6개 state enum 자체를 저장하지만 상태 전이 순서는 handler가 강제한다. `create_attachment`는 `allocated`만 만들고, upload 성공 뒤 `uploaded`, R2 `head()`의 byte size 확인 뒤 `ready`가 된다. `abandoned`·`tombstoned`·`garbage_collected`도 같은 행에 남겨 audit와 dangling reference 검사를 유지하며 physical row delete를 lifecycle 의미로 사용하지 않는다.

M05에서 기존 `bubble.attachment_ref_attachment_id`에 `(account_id, attachment_id)` FK를 소급한다. attachment가 없는 null reference는 유지하지만 dangling 또는 cross-account non-null reference는 migration 전체를 rollback한다. Tombstoned bubble도 reference identity를 보존하므로 garbage-collected attachment metadata row는 삭제하지 않는다.

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

R2 object는 E2EE §7.1의 binary envelope를 Base64 변환 없이 저장한다. 고정 overhead는 `version 1 + alg 1 + key_generation 4 + nonce 12 + GCM tag 16 = 34 bytes`이므로 `MAX_ATTACHMENT_SOURCE_BYTES = 12,582,912`, `MAX_ENCRYPTED_OBJECT_BYTES = 12,582,946`이다. `ciphertext_byte_size`는 source + 34와 정확히 같아야 한다. Chunked AEAD는 이 식과 다른 manifest contract가 필요하므로 v1 M05 범위에서 사용하지 않는다.

```json
{
  "account_id": "A0000000-0000-4000-8000-000000000001",
  "attachment_id": "70000000-0000-4000-8000-000000000001",
  "origin_space_id": "PHONE_SPACE",
  "kind": "attachment",
  "state": "allocated",
  "r2_object_key": "obj/70000000-0000-4000-8000-0000000000FF",
  "source_byte_size": 2618357,
  "ciphertext_byte_size": 2618391,
  "ciphertext_hash": "0000000000000000000000000000000000000000000000000000000000000000",
  "key_generation": 1,
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

### 9.1 D1 보존 규칙

v1 tombstone은 별도 기록만 남기고 원본 entity를 지우는 방식이 아니라 **turn·bubble canonical 행을 보존하는 soft delete**다.

- `turn`과 `bubble` 행은 ⬜ `is_tombstoned`, ⬜ `tombstoned_at`, ⬜ `tombstone_operation_id`를 가진다.
- `is_tombstoned = 1`인 행도 primary/unique key와 scope-wide `bubble_order` unique 제약에 계속 참여한다.
- `delete_turn`은 turn과 모든 child bubble을 같은 D1 transaction에서 tombstone 처리하며 identity·order 행을 물리 삭제하지 않는다. **본문·canonical text·heart change reason·extension 등 암호화 content 컬럼은 tombstone 적용과 함께 `NULL`로 비운다.** tombstone 보존은 삭제된 내용을 보관한다는 뜻이 아니다.
- Worker는 호감도 암호문을 해석할 수 없으므로, 호감도 되돌림이 필요한 operation은 권한 있는 client가 계산한 새 encrypted worldline/group state patch를 함께 보낸다. 이 patch와 turn·bubble tombstone이 하나의 CAS transaction으로 성공하거나 모두 rollback된다.
- pull·bootstrap projection은 tombstone identity와 ordering metadata를 내려주되 삭제된 content를 활성 entity처럼 노출하지 않는다.
- v1에는 tombstone retention 만료나 물리 삭제를 두지 않는다.

따라서 삭제된 꼬리 bubble의 번호도 영구히 은퇴하며 새 bubble에 재사용되지 않는다. 향후 tombstone을 물리 삭제하려면 먼저 conversation scope별 `next_bubble_order` 또는 `max_assigned_bubble_order` watermark를 별도 canonical 행에 영구 보존하고, 발급 transaction이 그 값을 CAS로 증가시키도록 규격을 바꿔야 한다.

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

### 9.2 플랫폼 삭제 의미가 다르다

- Mac은 선택한 message와 같은 `turnId`를 공유하는 **모든 bubble**을 지운다.
- Android는 선택한 `message.id` **하나**만 지운다.

Android의 bubble 삭제는 turn과 현재 호감도 값은 남긴 채 첫 bubble의 `canonicalText` 또는 마지막 bubble의 `heartChanges` 근거만 없앨 수 있다. **따라서 canonical turn entity가 local bubble anchor와 독립적으로 이 값을 소유해야 한다.**

### 9.3 사용자 결정 반영

- 결정 10: **AI 답변은 턴 전체를 삭제한다.** 최초 활성화 버전은 `delete_turn`을 기본으로 한다.
- 결정 11: **하트도 되돌린다.** 단 되돌릴 `heart_changes` 기록이 없으면 삭제만 하고 하트는 건드리지 않는다(`reverts_heart_changes = false`).
- 결정 15: **수정·삭제는 첫 테스트에서 막아둔다.** 즉 이 절의 operation은 schema에 정의하되 Phase 5 초기에는 전송·수용하지 않는다.

`delete_turn`이 단톡방에서 실행되면 여러 화자의 bubble tombstone과 권한 있는 client가 계산한 여러 참여자의 encrypted 하트 상태 patch가 **함께 원자적으로** 적용된다(결정 4·10·11 조합). Worker가 하트 값을 복호화하거나 직접 계산하지 않는다.

**통합 결정:** headless turn을 만들지 않는다. 마지막 bubble을 지우려는 `delete_bubble`은 `delete_turn`으로 승격하며, turn과 모든 child bubble을 같은 transaction에서 tombstone 처리한다.

canonical turn의 `canonical_text`·`heart_changes`는 bubble과 독립된 turn-level source of truth다. local JSON으로 투영할 때만 다음 규칙으로 anchor한다.

- `canonical_text`: 남은 AI bubble 중 첫 bubble
- `heart_changes`: 남은 AI bubble 중 마지막 bubble
- 중간 bubble: 두 turn-level 필드를 갖지 않는다
- 남은 bubble이 없으면 reanchor하지 않고 turn을 삭제한다

이 anchor는 local storage 호환을 위한 projection일 뿐 canonical ownership을 bubble로 되돌리지 않는다. 초기 Phase 5에서는 사용자 결정 10·15에 따라 `delete_bubble` 자체를 전송·수용하지 않고 `delete_turn`만 허용한다.

---

## 10. Durable outbox event envelope

모든 local 변경은 **local content와 outbox record가 하나의 복구 가능한 operation으로 durable해진 뒤** 업로드된다.

```json
{
  "operation_id": "90000000-0000-4000-8000-000000000003",
  "account_id": "A0000000-0000-4000-8000-000000000001",
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

### 11.1 PHONE_SPACE group·worldline canonical entity

초안에서 scope만 정의하고 실제 group state 행이 빠져 있었으므로 다음 두 entity를 둔다.

| Entity | 필드 | 분류 |
| --- | --- | --- |
| `group_state` | `(account_id, PHONE_SPACE, room_id)` | ⬜ identity |
| `group_state` | `participants` | 🔒 participant relationship 목록 |
| `group_state` | `active_worldline_id` | 🔒 현재 선택된 write scope 참조 |
| `group_state` | `revision`, `server_seq` | ⬜ CAS·ordering |
| `worldline` | `(account_id, PHONE_SPACE, room_id, worldline_id)` | ⬜ identity |
| `worldline` | `name` | 🔒 표시 내용 |
| `worldline` | `created_at` | ⬜ timestamp |
| `worldline` | `participant_hearts` | 🔒 participant reference와 현재 하트 값 |
| `worldline` | `revision`, `server_seq` | ⬜ CAS·ordering |

`participants`와 `participant_hearts`는 unknown member 보존이 가능한 canonical payload로 직렬화한다. 둘의 participant reference 값은 §13.2에 따라 암호화한다. `active_worldline_id`는 다음 message의 canonical scope를 결정하므로 local-only 선택 상태로 두지 않되, 서버 routing에는 각 write가 명시한 scope만 필요하므로 값은 암호화한다. **그러나 각 write의 평문 `worldline_id`와 timestamp를 관찰하면 서버가 최근 active worldline을 추론할 수 있으므로, 암호화가 선택 상태를 완전히 숨긴다고 보장하지 않는다.** `group_state`·`worldline` create/patch는 `PHONE_SPACE`가 아니면 거부한다.

**2026-08-28 확정 — `group_state` target에는 `worldline_id`가 없다.** `group_state`의 identity는 위 표대로 `(account_id, PHONE_SPACE, room_id)`이며 worldline 차원이 없다. 따라서 sync operation의 `target`에 `worldline_id`가 **있으면 값이 `null`이든 UUID든 거부한다**(Worker API 초안 §4.1.2).

이것은 형식 문제가 아니라 identity 모호성 때문이다. `worldline_id`를 허용하면 같은 room-level 행 하나를 `null`인 target과 UUID인 target 두 가지로 지칭할 수 있고, `worldline_key`가 `''`와 UUID 사이를 오가면서 §14.2의 D1 primary key가 흔들린다. 현재 선택된 세계선은 **행 안의 암호화된 `active_worldline_id`로만** 존재하며 target에는 절대 나타나지 않는다.

`worldline` entity는 반대다. target이 세계선 행 자신을 가리키므로 `worldline_id`가 필수이고 `null`일 수 없다.

**2026-08-28 확정 — named worldline의 space 경계.** conversation scope의 `worldline_id = null`은 기본 scope이므로 `MAC_SPACE`·`PHONE_SPACE`·`TABLET_SPACE`에서 모두 허용한다. 반면 non-null `worldline_id`는 phone 전용 worldline을 가리키므로 `PHONE_SPACE`에서만 허용한다.

- Worker는 room-scoped target의 평문 `space_id`와 nullable `worldline_id`를 함께 검사해 MAC/TABLET의 named scope를 거부한다.
- D1 `turn`은 `CHECK (worldline_id IS NULL OR space_id = 'PHONE_SPACE')`와 `worldline_key = COALESCE(worldline_id, '')`를 함께 강제한다.
- bubble은 parent turn FK의 `worldline_key`를 따르며 nullable ID를 중복 저장하지 않는다.
- default scope에는 대응하는 `worldline` row가 없으므로 turn이 worldline table을 직접 FK로 참조하지 않는다.

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

### 13.2 다섯 참조의 E2EE 분류

**통합 결정:** 다섯 참조의 **값은 암호화 대상**이다. entity 자체의 `room_id`·향후 `character_id`는 D1 routing과 identity를 위해 평문이지만, 메시지·반응·호감도 안의 참조는 “어느 방/캐릭터가 누구와 말하고 반응했는지”라는 관계 graph를 드러내며 서버 query에 필요하지 않다.

- `GroupParticipant.roomId`, `ParticipantHeart.participantRoomId`는 각각 group participant·heart payload 안에서 암호화한다.
- `ChatMessage.speakerRoomId`, `MessageReaction.participantRoomId`, `MessageHeartChange.participantRoomId`는 해당 bubble/turn의 수정 가능한 field 봉투 안에서 암호화한다.
- field path와 entity identity는 평문이고 참조 **값**만 암호화한다.
- `character_id` 도입 시 authorized client/importer가 다섯 값을 같은 mapping으로 복호화·이전·재암호화한다. 서버가 ciphertext를 보고 migration을 추론하지 않는다.

이 결정은 E2EE 제안서 §8.2의 암호화 목록에 반영하며, §8.3의 canonical identity 평문 규칙과 충돌하지 않는다. 평문인 것은 entity의 identity이고, 암호화되는 것은 다른 entity를 가리키는 relationship edge다.

### 13.3 이전 대상이 아닌 것

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

아래는 통합 key contract다. 실제 `CREATE TABLE`과 index DDL은 fixture·migration test와 함께 별도 구현한다. 이 문서는 Cloudflare 리소스를 만들지 않는다.

### 14.1 키 설계

| 테이블 | Primary key | Unique key | 비고 |
| --- | --- | --- | --- |
| `account` | `account_id` | — | |
| `device` | `(account_id, device_id)` | — | `revoked_at`으로 무효화 |
| `room` | `(account_id, space_id, room_id)` | — | `space_id`를 키에 넣어 space 간 UUID 충돌을 막는다 |
| `group_state` | `(account_id, space_id, room_id)` | — | v1은 `PHONE_SPACE`만 허용 |
| `worldline` | `(account_id, space_id, room_id, worldline_key)` | — | `worldline_key` 규칙은 §14.2 |
| `turn` | `(account_id, space_id, room_id, worldline_key, turn_id)` | — | `is_tombstoned` soft-delete; v1 물리 삭제 금지 |
| `bubble` | `(…scope key…, turn_id, message_id)` | `(…scope key…, message_id)`, `(…scope key…, bubble_order)` | tombstone 행도 unique 제약에 참여; v1 물리 삭제 금지 |
| `persona_snapshot` | `(account_id, space_id, persona_snapshot_id, snapshot_revision)` | — | immutable revision 행 |
| `persona_snapshot_head` | `(account_id, space_id, persona_snapshot_id)` | — | 현재 revision을 CAS로 전진 |
| `engine_profile` | `(account_id, space_id, engine_profile_id, profile_revision)` | — | immutable revision 행 |
| `checkpoint` | `(…scope key…, checkpoint_id)` | — | mutable revision은 CAS |
| `room_extension_field` | `(account_id, space_id, room_id, extension_key)` | — | 논리 `extension_field` family; room FK |
| `turn_extension_field` | `(…scope key…, turn_id, extension_key)` | — | 논리 `extension_field` family; turn FK |
| `bubble_extension_field` | `(…scope key…, turn_id, message_id, extension_key)` | — | 논리 `extension_field` family; bubble FK |
| `persona_snapshot_extension_field` | `(account_id, space_id, persona_snapshot_id, snapshot_revision, extension_key)` | — | M04에서 owner와 함께 추가 |
| `attachment` | `(account_id, attachment_id)` | `(account_id, r2_object_key)` | |
| `operation_log` | `(account_id, operation_id)` | — | idempotency |
| `change_log` | `(account_id, server_seq)` | — | account cursor |

### 14.2 nullable `worldline_id`를 키에 쓰는 문제

SQLite/D1에서 **`NULL`은 서로 같지 않으므로 primary key나 unique 제약에 그대로 넣으면 중복 행이 생긴다.** `worldline_id`가 null인 기본 세계선이 여러 번 삽입될 수 있다.

**통합 결정:** sentinel UUID를 쓰지 않는다. D1에는 nullable `worldline_id`와 key 전용 non-null **materialized column**을 함께 둔다.

```sql
worldline_id  TEXT NULL,
worldline_key TEXT NOT NULL,
CHECK (worldline_key = COALESCE(worldline_id, ''))
```

- D1 primary/unique/index는 `worldline_key`를 사용한다.
- API·canonical object·E2EE AAD는 언제나 원래 nullable `worldline_id`를 사용한다. null은 LP v1 `presence = 0`, 실제 UUID는 `presence = 1`이다.
- `worldline_key = ''`는 D1 내부 key 표현일 뿐 API, AAD, outbox, R2 key에 노출하지 않는다.
- 실제 UUID가 빈 문자열이 될 수 없으므로 mapping은 일대일이다. sentinel UUID와 실제 UUID 충돌 가능성도 없다.
- Worker가 canonical uppercase UUID 형식을 검증한 뒤 `worldline_key = worldline_id ?? ""`를 함께 bind한다. DB의 `CHECK`가 둘의 불일치를 거부한다.
- SQLite generated column은 primary key 일부가 될 수 없으므로 generated column을 쓰지 않는다. natural composite primary key를 유지하면서 mapping을 DB가 검증하는 선택이다.

### 14.3 revision과 CAS 조건

모든 mutable entity(`room`, `persona_snapshot_head`, `checkpoint`)는 ⬜ `revision`을 가진다. `persona_snapshot`과 `engine_profile`의 revision 행 자체는 immutable이며 새 revision 생성과 head/reference 전진을 같은 transaction에서 처리한다.

```sql
UPDATE room
   SET status_message_enc = ?, revision = revision + 1, server_seq = ?
 WHERE account_id = ? AND space_id = ? AND room_id = ?
   AND revision = ?;          -- base_revision. 0 row 갱신이면 conflict
```

- 갱신은 **`base_revision`이 현재 `revision`과 정확히 같을 때만** 성공한다.
- 영향 행이 0이면 **conflict로 거부**하고 클라이언트가 최신 상태를 받아 다시 만든다.
- `revision` 증가·canonical row 갱신·`operation_log` 삽입·change log 기록은 **하나의 `batch()` transaction**으로 적용한다.
- 같은 `operation_id`가 이미 `operation_log`에 있으면 **재적용하지 않고 기존 결과를 반환**한다(idempotency).

`server_seq`는 Worker가 **account 단위**로 매기는 단조 증가 값이며 클라이언트 pull의 단일 cursor가 된다. scope별 cursor는 room 생성·삭제와 새 scope 발견을 위해 별도 fan-out cursor가 필요하므로 v1에서 쓰지 않는다. 이 선택은 correctness contract이며 성능 보장은 아니다. 합성 Phase 2에서 동시 write·pagination·D1 CPU/latency를 측정하고, 한 DB가 query를 순차 처리한다는 D1 특성 때문에 병목이 확인될 때만 shard나 별도 sequencer를 검토한다.

Worker는 같은 `operation_id`가 없을 때만 account row의 `next_server_seq`를 1 증가시키고, 같은 transaction의 canonical row·operation log·change log가 그 값을 읽게 한다. idempotent 재시도는 새 sequence를 소비하지 않는다. sequence는 중복 없이 증가하며 gap은 허용한다. 범위 상한에 도달하면 wrap하거나 0으로 돌아가지 않고 fail-closed한다. 동시 batch 두 개가 중복 sequence를 만들지 않는지 Phase 2에서 검증한다.

---

### 14.4 Phase 0 기반 D1 용량 추정

이 계산은 정책 결정이 아니라 Phase 1 sizing 참고값이다. 실제 D1 DDL·index와 ciphertext가 없으므로 정확한 청구량을 뜻하지 않는다.

| 항목 | byte | 처리 |
| --- | ---: | --- |
| 세 archive 전체 | 40,355,530 | 출발점 |
| 별도 avatar 파일(프로필 avatar 포함) | 20,800,577 | R2, D1 본문에서 제외 |
| local-only·cache·ink 등 나머지 other | 2,558,968 | canonical D1에서 제외 |
| message·room list·digest JSON | 16,995,985 | D1 후보 |
| 그 JSON 안 attachment base64 추정 | 12,494,244 | decoded 9,370,679 byte의 `4 × ceil(n/3)` 합계, R2로 이동 |
| media 제거 후 text·JSON 구조 추정 | **4,501,741** | 암호화 전 계획값 |

E2EE §7.1 봉투의 binary 고정 오버헤드는 `version 1 + alg 1 + key_generation 4 + nonce 12 + GCM tag 16 = 34 bytes`다. 패딩 포함 표준 Base64의 정확한 길이는 `4 × ceil(n / 3)`이므로 plaintext 크기가 `p_i`인 field 하나의 D1 text 길이는 다음과 같다.

```text
field_i_bytes = 4 × ceil((p_i + 34) / 3)
exact_payload_bytes = Σ field_i_bytes
```

현재는 field별 `p_i`를 세지 않았으므로 총 plaintext `P = 4,501,741`과 field 수 `F`만으로 정확값을 낼 수 없다. 각 field의 Base64 padding 차이를 포함한 보수적 범위는 다음과 같이 둔다.

```text
lower = 4 × ceil((P + 34F) / 3)
upper = 4 × floor((P + 34F + 2F) / 3)
```

| 가정한 `F` | D1 암호문 text 범위 |
| ---: | ---: |
| 10,000 | 6,455,656 ~ 6,482,320 bytes |
| 25,000 | 7,135,656 ~ 7,202,320 bytes |
| 50,000 | 8,268,988 ~ 8,402,320 bytes |

Phase 0 보고서는 민감한 본문을 남기지 않기 위해 **암호화 field instance 총수 `F`와 field별 byte 분포를 세지 않았다.** 따라서 현재의 정직한 결론은 “초기 D1 암호문 text는 예시 `F` 범위에서 약 6.46~8.40MB 규모일 가능성이 높고, 정확값은 합성 importer가 field별 envelope를 실제 직렬화한 뒤 확정”이다. index·PK·row header, 평문 metadata, 이전 revision, tombstone, operation/change log, 향후 증가는 위 숫자에 포함되지 않는다.

현재 D1 Free 한도는 database당 500MB, account 전체 5GB, row/string/BLOB당 2MB다. 위 초기 암호문 text 범위는 database 한도의 약 1.3~1.7%지만, 평균이 아니라 **개별 암호문이 2MB를 넘지 않는지**도 별도 fixture로 검증해야 한다. D1은 한 database에서 query를 순차 처리하며 `batch()`는 하나가 실패하면 전체 sequence를 rollback한다. 근거: [D1 limits](https://developers.cloudflare.com/d1/platform/limits/), [D1 `batch()`](https://developers.cloudflare.com/d1/worker-api/d1-database/#batch).

---

## 15. Codex 통합 결정 기록

| # | 절 | 확정 결정 |
| ---: | --- | --- |
| 1 | §0.2 | D1 암호문 컬럼은 `_enc`; wire field path는 canonical 이름 유지 |
| 2 | §1.2 | 한 `space_id`에 여러 device 허용; 동시성은 CAS·authority로 통제 |
| 3 | §2·§9.1 | `bubble_order`는 scope-wide `0...2^53-1`, 최초 0-based index, tombstone 포함 `max+1`; 번호 재사용 금지 |
| 4 | §3.3 | `<owner>.<entity>.<field>` namespace, key별 독립 봉투 |
| 5 | §4 | `engine_profile`은 별도 immutable version entity, room이 exact revision 참조 |
| 6 | §4 | `relationship_policy = group`은 v1 `PHONE_SPACE` 전용 |
| 7 | §6.3 | legacy digest는 opaque read-only 보존; 필요할 때 원본에서 새 version 생성 |
| 8 | §9.3 | 마지막 bubble 삭제는 `delete_turn`; headless turn 금지; first/last anchor 규칙 |
| 9 | §14.2 | D1 key는 checked materialized `worldline_key`; API·AAD는 nullable `worldline_id` 유지 |
| 10 | §14.3 | account-wide `server_seq` 단일 cursor |
| 11 | §13.2 | character migration 대상 다섯 relationship 참조값은 암호화 |

### 15.1 이 통합 초안이 아직 확정하지 않은 것

- 실제 `CREATE TABLE` DDL과 인덱스
- Worker API endpoint 목록과 요청·응답 형식
- pull cursor·페이지 크기·충돌 해소 UX
- Phase 4 remote replica의 별도 store 구조
- Mac 방 목록 6개와 메시지 파일 13개의 차이 원인 — Phase 0이 **후속 확인 대상으로 남긴 항목**이며 임의 삭제하지 않는다

### 15.2 통합 검토에서 고친 오류·누락

- `turn`·`bubble`의 canonical 내용 필드와 ownership이 없던 문제를 §3.4에 보완했다.
- group/worldline scope만 있고 `group_state`·`worldline` payload가 없던 문제를 §11.1에 보완했다.
- `persona_snapshot`·`attachment` key에 `account_id`가 빠져 tenant 경계가 약했던 것을 §14.1에서 수정했다.
- `engine_profile`·extension·change log table이 key 표에 빠진 것을 추가했다.
- 같은 turn 안에서 `bubble_order` 중복을 허용해 표시 순서가 모호해질 수 있던 것을 unique constraint로 막았다.
- generated column을 primary key에 쓸 수 없는 SQLite 제약을 반영해 checked materialized `worldline_key`로 바꿨다.
- Phase 0 tablet raw label `tablet`과 canonical `TABLET_SPACE`가 다른 점을 importer mapping으로 명시했다.
- Phase 0 보고서의 실제 Mac·phone 값이 이미 `MAC_SPACE`·`PHONE_SPACE`임을 확인해 canonical pass-through와 legacy `tablet` 변환을 분리했다.
- tombstone 행의 보존 위치가 불명확해 꼬리 `bubble_order`가 재사용될 수 있던 문제를 §2·§9.1·§14.1의 soft-delete 계약으로 막았다.
- 예시 UUID 세 종류의 소문자 표기를 E2EE canonical 대문자 형식으로 통일했다.
- character migration의 다섯 참조가 암호화 목록에 없던 것을 §13.2와 E2EE 제안서 §8.2에 반영했다.
- unsupported profile을 무조건 read-only로 둬 사용자 결정 8과 충돌하던 문구를, 고지된 명시적 fallback과 turn별 실제 generation profile 기록으로 수정했다.
- Phase 0 총 archive byte를 그대로 D1 용량으로 오해하지 않도록 R2 media·local-only data를 분리하고, 표준 Base64 padding과 34-byte binary 봉투를 반영한 범위식을 §14.4에 추가했다.

## 16. Phase 1 완료 조건

이 초안이 계약으로 확정되려면 다음이 필요하다.

1. 각 entity의 fixture와 acceptance test 작성
2. E2EE 제안서 §13의 contract test와 이 schema의 결합 검증 — 특히 nullable worldline과 relationship reference 암호화
3. 비파괴 importer가 §12 규칙으로 같은 결과를 반복 생성하는지 확인
4. Mac `PersonaStyle` custom decoder 하위호환 확인(§5.1)
5. 실제 DDL·index에서 §14 key·CAS·account-wide sequence를 합성 동시 write로 검증
6. 합성 importer가 정확한 encrypted field count·serialized D1 row/index size를 계산해 §14.4 추정을 교체

**위 조건이 충족되기 전에는 이 문서를 구현 규격으로 사용하지 않는다.** Phase 2 합성 시험과 Phase 3 실데이터 업로드는 각각의 게이트를 별도로 통과해야 하며, 이 초안은 어느 쪽도 승인하지 않는다.
