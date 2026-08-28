# Phase 1 Worker API 계약 초안

## 문서 상태

- 작성일: 2026-08-28
- 작성: Codex
- 상태: **API·transaction 설계 / 구현 승인 아님 / Cloudflare 리소스 생성 안 함**
- Schema 기준: `7748170`
- Claude Code의 schema fixture 작업과 소유 파일이 겹치지 않는다.

이 문서는 Worker의 HTTP 경계와 D1·R2 transaction 순서를 고정하기 위한 설계다. TypeScript project, Wrangler 설정, D1 migration, R2 bucket, 앱 networking code는 아직 만들지 않는다.

## 1. v1 원칙

1. **device token이 account 경계다.** URL·body의 `account_id`를 신뢰하지 않고 token에서 얻는다.
2. **한 push request는 operation 하나다.** 초기 규모는 세 기기이며, 여러 operation의 부분 성공 규격보다 단일 idempotent transaction이 안전하다.
3. **내용은 Worker가 해석하지 않는다.** 평문 identity·revision·field path만 검증하고 암호문은 opaque byte/base64로 보존한다.
4. **operation 적용은 원자적이다.** canonical row, account sequence, operation log, change log가 함께 commit되거나 함께 rollback된다.
5. **R2 payload와 D1 metadata는 2단계 완료 상태를 쓴다.** R2와 D1을 하나의 transaction으로 묶을 수 없기 때문이다.
6. **로그에 content·token·복구 문구·암호문·첨부 이름을 남기지 않는다.** request id, endpoint, status, duration, byte count, 오류 code만 허용한다.
7. v1은 D1 read replication을 켜지 않는다. 향후 켤 경우 Sessions API bookmark를 `X-Sync-Bookmark`로 전달한다.

## 2. 공통 HTTP 규격

### 2.1 Base와 headers

```text
Base path: /v1
Authorization: Device <opaque-device-token>
Content-Type: application/json
X-Protocol-Version: 1
```

- token·pairing secret·recovery material은 URL query에 넣지 않는다.
- JSON request body 최대값은 endpoint별로 제한한다. 일반 sync operation은 정확히 `2,000,000 bytes` 이하이고, 암호화된 단일 field 값은 base64 envelope 전체가 `1,900,000 bytes` 이하여야 한다. attachment body는 별도 endpoint만 쓴다.
- UUID는 대문자 하이픈 36-byte 형식, integer는 `0...2^53-1`, timestamp는 RFC 3339 UTC다.
- 알 수 없는 top-level field와 enum은 v1에서 fail-closed한다. Opaque extension은 등록된 `extensions` container 안에서만 허용한다.

**2026-08-28 보정(Claude Code):** "base64 envelope"는 JavaScript `string.length`만 재는 것이 아니라 다음을 모두 만족해야 통과한다.

1. 표준 padded Base64의 **canonical** 형식이다. charset·패딩 위치·4의 배수 길이를 확인하는 것만으로는 부족하다. 마지막 quantum에서 실제 byte를 넘어가는 bit는 decode 때 버려지므로 서로 다른 문자열이 같은 byte로 풀린다(`"QQ=="`와 `"QR=="`은 둘 다 `0x41`). 그래서 decode한 뒤 표준 encoder로 **다시 encode해 입력과 byte-for-byte 같은지**까지 확인하고, encoder가 내놓는 철자 하나만 통과시킨다. 이것을 허용하면 같은 ciphertext를 담은 body가 byte 수준에서 여러 개가 되어 §4.1의 replay fingerprint 계약이 약해진다.
2. decode한 byte 길이가 E2EE 제안서 §7.1 봉투의 최소 크기 **34 byte**(`version` 1 + `alg` 1 + `key_generation` 4 + `nonce` 12 + GCM tag 16, 평문이 0 byte일 때의 하한) 이상이다.
3. decode한 첫 byte(`version`)와 둘째 byte(`alg`)가 v1이 지원하는 값(`0x01`, `0x01`)이다.
4. `1,900,000 bytes` 상한은 이 canonical Base64 문자열 자체의 길이에 적용한다. canonical 형식이 아닌 문자열은 길이 검사 전에 먼저 거부되므로, 상한 검사와 원본 HTTP body 상한(`2,000,000 bytes`, §5.1)은 서로 다른 두 경계를 각각 검증한다.

이 네 단계를 통과하지 못하면 오류에 실패한 필드의 값이나 path를 넣지 않고 `VALIDATION_FAILED`만 돌려준다.

#### 암호 검증 책임 경계 (2026-08-28 확정)

위 네 단계는 **구조 검사이지 암호 검증이 아니다.** 계층별 책임을 혼동하면 "Worker가 검사했으니 안전하다"는 잘못된 결론이 나오므로 경계를 명시한다.

| 계층 | 하는 일 | 하지 않는 일 |
| --- | --- | --- |
| **Worker** | canonical Base64 여부, envelope 최소 크기(34 byte), `version`·`alg` byte, 크기 상한, identity·scope·권한 경계 | 복호화, AAD 조립·대조, AEAD tag 검증, nonce 검사 |
| **Swift·Kotlin client crypto** | nonce 생성과 재사용 방지, canonical AAD 조립과 일치 확인, AEAD tag 검증, key 파생 | — |
| **D1 handler** | envelope byte를 **받은 그대로 보존**, identity·CAS·idempotency 처리 | 복호화, ciphertext 재직렬화, AAD 내용 추론, unknown extension 제거 |

**Worker와 D1 handler는 ciphertext를 복호화하지 않으며 AAD 내용을 검사하지도 추론하지도 않는다.** 키가 없으므로 할 수도 없다. 따라서 nonce가 재사용됐는지, AAD가 실제 scope와 일치하는지는 **오직 키를 가진 client만 판정할 수 있다.** Worker의 통과는 "봉투 모양이 규격에 맞다"는 뜻일 뿐 "내용이 정품이다"라는 뜻이 아니다.

D1은 envelope byte를 있는 그대로 저장한다. 평문으로 decode하거나 JSON을 다시 직렬화하지 않으며, 모르는 extension key도 byte 단위로 보존한다.

#### Attachment identity와 `space_id`의 역할 (2026-08-28 확정)

- attachment의 canonical identity와 D1 primary key는 **`(account_id, attachment_id)`**다.
- operation target의 `space_id`는 **identity의 일부가 아니다.** 생성 출처를 기록하고 device 권한을 검사하기 위한 평문 metadata다.
- D1 row에는 `origin_space_id`로 저장하되 **primary key·unique key에는 넣지 않는다.**
- 다운로드 권한은 같은 account의 유효한 device token으로 검사한다. room UUID를 attachment identity에 억지로 넣지 않는다.
- 따라서 `create_attachment`의 target에서 **`room_id`와 `worldline_id`는 금지**된다(§4.1.1).

### 2.2 성공 envelope

```json
{
  "protocol_version": 1,
  "request_id": "90000000-0000-4000-8000-000000000001",
  "result": {}
}
```

### 2.3 오류 envelope

```json
{
  "protocol_version": 1,
  "request_id": "90000000-0000-4000-8000-000000000001",
  "error": {
    "code": "REVISION_CONFLICT",
    "retryable": false,
    "current_revision": 42
  }
}
```

허용 code:

| HTTP | code | 의미 |
| ---: | --- | --- |
| 400 | `VALIDATION_FAILED` | 형식·범위·scope 불일치 |
| 401 | `AUTH_INVALID` | token 없음·불일치 |
| 403 | `DEVICE_REVOKED` | 폐기된 기기 |
| 404 | `ENTITY_NOT_FOUND` | account 안에 target 없음 |
| 409 | `REVISION_CONFLICT` | `base_revision` 불일치 |
| 409 | `OPERATION_REPLAY_MISMATCH` | 같은 ID에 다른 request fingerprint |
| 409 | `ATTACHMENT_STATE_CONFLICT` | 잘못된 attachment 상태 전이 |
| 413 | `REQUEST_TOO_LARGE` | endpoint 상한 초과 |
| 422 | `PROFILE_UNSUPPORTED` | 지원·고지된 fallback 없음 |
| 429 | `RATE_LIMITED` | 호출 제한 |
| 500 | `INTERNAL_ERROR` | content 없는 내부 오류 |
| 503 | `STORAGE_UNAVAILABLE` | D1·R2 일시 실패 |

서버 오류 본문에는 SQL, stack, object key, token 일부를 넣지 않는다.

## 3. Device 인증 경계

모든 sync·attachment endpoint는 다음 `AuthContext`를 먼저 만든다.

```text
AuthContext = {
  account_id,
  device_id,
  registered_space_id,
  key_generation,
  revoked_at
}
```

- request body의 `device_id`가 있으면 token의 값과 정확히 같아야 한다.
- target `space_id` write 권한은 device 등록, owner space, active writer/generation authority를 함께 검사한다.
- v1 operation write는 `target.space_id === AuthContext.registered_space_id`를 최소 선행 조건으로 강제한다. 같은 account token이어도 다른 등록 space의 canonical row를 쓰지 못한다. 향후 active-writer 위임은 이 조건을 조용히 우회하지 않고 별도 authority 계약으로만 확장한다.
- `create_attachment`도 write이므로 이 equality를 적용한다. 이때 target space는 attachment identity가 아니라 `origin_space_id` provenance와 일치하는 생성 출처다. 반대로 ready attachment download는 §6 계약대로 같은 account의 유효한 device이면 허용하며 registered-space equality를 적용하지 않는다.
- `PHONE_SPACE` 전용 group/worldline/relationship operation을 다른 space device가 만들면 거부한다.
- 폐기된 token은 R2 download를 포함한 모든 endpoint에서 거부한다.
- QR pairing·전체 복구 endpoint는 [E2EE 제안서](2026-08-27-sync-encryption-proposal.md) §4~5의 별도 인증 흐름을 사용하며 일반 device middleware를 우회하지 않는다.

### 3.1 Device token v1 wire·storage 계약

- token은 CSPRNG 32 byte이며 wire 표기는 `gdt1_` + padding 없는 canonical Base64URL 43자다.
- header는 `Authorization: Device <token>` 한 경로만 사용한다. URL·query·body fallback은 금지한다.
- D1에는 decoded 32 byte의 SHA-256 lowercase hex만 `device.token_hash`로 저장하며 raw token은 저장·로그하지 않는다.
- `token_hash`는 account를 가로질러 전역 unique다. request가 account를 고르지 않고 hash lookup 결과가 account를 결정한다.
- malformed·unknown token은 `401 AUTH_INVALID`, 유효하지만 `revoked_at`이 non-null인 token은 `403 DEVICE_REVOKED`다. 이 구분은 폐기된 기기가 재연결 흐름으로 전환할 수 있게 하기 위한 명시 계약이다.
- physical migration `0007_device_token.sql`은 논리 M-stage가 아니라 M06 handler 전에 필요한 cross-cutting 인증 경계다. token 발급·pairing은 이 migration의 범위가 아니다.

## 4. Sync endpoints

### 4.1 `POST /v1/sync/operations`

operation 하나를 적용한다.

```json
{
  "protocol_version": 1,
  "operation_id": "90000000-0000-4000-8000-000000000003",
  "device_id": "80000000-0000-4000-8000-000000000001",
  "op": "patch_room",
  "entity_type": "room",
  "target": {
    "space_id": "MAC_SPACE",
    "room_id": "10000000-0000-4000-8000-000000000002",
    "worldline_id": null
  },
  "base_revision": 41,
  "metadata_set": {},
  "metadata_clear": [],
  "set": {
    "status_message": "BASE64_ENVELOPE"
  },
  "clear": [],
  "created_at": "2026-08-28T00:00:00Z"
}
```

응답:

```json
{
  "protocol_version": 1,
  "request_id": "90000000-0000-4000-8000-000000000003",
  "result": {
    "status": "applied",
    "operation_id": "90000000-0000-4000-8000-000000000003",
    "server_seq": 10428,
    "revision": 42
  }
}
```

같은 `operation_id`와 같은 request fingerprint면 `status = replayed`와 최초 결과를 돌려준다. fingerprint는 **검증 전에 받은 HTTP request body 원본 bytes**의 SHA-256이다. retry는 outbox에 보관한 동일 bytes를 다시 보내야 하며, 의미가 같더라도 JSON을 다시 직렬화해 bytes가 달라지면 replay mismatch다. 같은 ID에 fingerprint가 다르면 `OPERATION_REPLAY_MISMATCH`다.

### 4.1.0 encrypted field와 plaintext metadata patch

`set`·`clear`는 encrypted field와 extension envelope에만 사용한다. D1이 identity·FK·ordering을 검사해야 하는 평문 canonical metadata는 별도 `metadata_set`·`metadata_clear`를 사용한다.

- 두 object/list는 모든 operation에 명시적으로 존재하며 사용하지 않을 때 각각 `{}`·`[]`다.
- Worker는 entity·operation별 metadata key allowlist와 value type/range를 검사한다. unknown key, 중복 clear, set/clear 동시 지정은 fail-closed다.
- create operation의 `metadata_clear`는 항상 빈 배열이어야 한다. 아직 존재하지 않는 row의 metadata를 clear하는 의미를 만들지 않는다.
- ID/revision pair와 checkpoint range pair는 함께 set하거나 함께 clear해야 한다.
- metadata는 로그에 값을 출력하지 않는다. raw-body fingerprint는 metadata를 포함한 최초 request bytes 전체에 대해 계산한다.

M04~M05 allowlist는 다음 표가 단일 계약이다. `필수 set`은 create request의 `metadata_set`에 반드시 있어야 하고, `선택 set`은 생략할 수 있다. 표에 없는 key는 허용하지 않는다.

| operation | 필수 `metadata_set` | 선택 `metadata_set` | 허용 `metadata_clear` |
| --- | --- | --- | --- |
| `patch_room` | 없음 | `engine_profile_id` + `engine_profile_revision`; `persona_snapshot_id` + `persona_snapshot_revision` | 같은 두 pair만 pair 단위로 허용 |
| `create_engine_profile` | 없음 | `compaction_compat_tag` | 없음 (`[]`만 허용) |
| `create_persona_snapshot` | `owner_space_id`, `created_by_device_id`, `created_at`, `persona_schema_version` | 없음 | 없음 (`[]`만 허용) |
| `create_checkpoint` | `checkpoint_schema_version`, `owner_space_id`, `created_by_device_id`, `created_at` | `first_turn_id` + `last_turn_id`; `through_server_seq`; `compaction_compat_tag` | 없음 (`[]`만 허용) |
| `patch_checkpoint` | 없음 | `first_turn_id` + `last_turn_id`; `through_server_seq`; `checkpoint_schema_version`; `compaction_compat_tag` | 같은 optional fields만 허용하며 range는 pair 단위 |
| `create_attachment` | `origin_space_id`, `kind`, `source_byte_size`, `ciphertext_byte_size`, `ciphertext_hash`, `key_generation`, `created_at` | 없음 | 없음 (`[]`만 허용) |

`owner_space_id`·`created_by_device_id`·`created_at`은 생성 provenance이므로 `patch_checkpoint`가 바꾸거나 지우지 못한다. encrypted segments·summary·profile/fingerprint는 계속 `set`·`clear`를 사용한다. `create_persona_snapshot`은 위 필수 metadata와 `base_revision`을 받고, 최초 `(base=0,target=1)` 또는 연속 `(target=base+1)`만 허용한다.

`compaction_compat_tag`는 문법을 해석하지 않는 opaque plaintext equality tag이며 UTF-16 code unit 기준 1~256자의 문자열만 받는다. 이 길이 제한은 transport/validator 경계일 뿐 hash·encoding 형식을 뜻하지 않는다.

### 4.1.1 operation별 identity shape (2026-08-28, Claude Code 보정)

`entity_type`은 자유 문자열이 아니라 `op`이 정확히 하나로 결정하는 값이다. `target`이 가질 수 있는 필드도 entity마다 다르며, 다른 entity의 ID가 섞이면 거부한다. 이 표가 `cloudflare/sync-worker/src/contracts/operation.ts`의 `OPERATION_SPECS`·`ENTITY_SHAPES`와 **정확히 같은 내용의 단일 source**다. 코드가 검증 구현이고 이 표는 그 구현이 따르는 계약이다.

| `op` | `entity_type` | 종류 | `target` 필수 필드 | `worldline_id` | 비고 |
| --- | --- | --- | --- | --- | --- |
| `create_room` | `room` | create | `room_id` | **null-only** | 키는 필수이며 값은 반드시 `null`; room storage identity에는 worldline 축이 없음 |
| `patch_room` | `room` | patch | `room_id` | **null-only** | 키는 필수이며 값은 반드시 `null`; `base_revision` 필수 |
| `create_persona_snapshot` | `persona_snapshot` | create+head CAS | `persona_snapshot_id`, `snapshot_revision` | **없음** | `room_id` 금지. `base_revision` 필수; 최초 0→1 또는 target=base+1 |
| `create_engine_profile` | `engine_profile` | create | `engine_profile_id`, `profile_revision` | **없음** | `room_id` 금지. identity가 `(account_id, space_id, engine_profile_id, profile_revision)`이다 |
| `create_checkpoint` | `checkpoint` | create | `room_id`, `checkpoint_id` | nullable | |
| `patch_checkpoint` | `checkpoint` | patch | `room_id`, `checkpoint_id` | nullable | `base_revision` 필수 (연장 CAS) |
| `create_turn` | `turn` | create | `room_id`, `turn_id` | nullable | |
| `patch_turn` | `turn` | patch | `room_id`, `turn_id` | nullable | `base_revision` 필수 |
| `create_bubble` | `bubble` | create | `room_id`, `turn_id`, `message_id` | nullable | top-level `bubble_order` 필수 |
| `patch_bubble` | `bubble` | patch | `room_id`, `turn_id`, `message_id` | nullable | `base_revision` 필수 |
| `create_group_state` | `group_state` | create | `room_id` | **없음** | **`PHONE_SPACE` 전용**. 아래 §4.1.2 참조 |
| `patch_group_state` | `group_state` | patch | `room_id` | **없음** | **`PHONE_SPACE` 전용**, `base_revision` 필수 |
| `create_worldline` | `worldline` | create | `room_id`, `worldline_id` | **필수(non-null)** | **`PHONE_SPACE` 전용**. target이 세계선 자신을 가리키므로 기본 세계선(null) 개념이 없다 |
| `patch_worldline` | `worldline` | patch | `room_id`, `worldline_id` | **필수(non-null)** | **`PHONE_SPACE` 전용**, `base_revision` 필수 |
| `create_attachment` | `attachment` | create | `attachment_id` | **없음** | `room_id`·`worldline_id` 금지. identity가 `(account_id, attachment_id)`다 |
| `delete_turn` | `turn` | delete | `room_id`, `turn_id` | nullable | **schema에만 정의. 사용자 결정 15에 따라 초기 runtime은 형식이 올바른 요청도 거부한다** |

"없음"은 그 필드를 target에 넣으면 `VALIDATION_FAILED`라는 뜻이다(예: `create_attachment`에 `worldline_id`를 넣으면 거부). "nullable"은 명시적으로 `null`이거나 대문자 UUID여야 하며, 키 자체가 없으면 모호하므로 거부한다. "null-only"도 키를 반드시 보내지만 값은 `null`만 허용한다. Room은 API object shape에는 nullable `worldline_id`를 유지하되 D1 identity가 `(account_id, space_id, room_id)`뿐이므로 non-null 값으로 같은 row를 두 방식으로 지칭하지 못하게 한다.

v1 runtime이 실제로 받아들이는 operation(`RUNTIME_ENABLED_OPERATIONS`)은 위 표에서 `delete_turn`을 제외한 15개다. `delete_turn`은 schema에는 있지만(`SCHEMA_OPERATIONS`) 삭제 기능 flag가 열리기 전에는 형식이 완전히 올바른 요청도 `VALIDATION_FAILED`로 거부한다.

whole-room·whole-message PUT, `delete_bubble`(schema에 아예 없음), client가 임의 발급한 `server_seq`는 거부한다.

### 4.1.2 `group_state`에 `worldline_id`가 없는 이유 (2026-08-28 확정)

`group_state`는 **room 전체의 상태를 담는 한 행**이며 D1 identity가 `(account_id, PHONE_SPACE, room_id)`다. worldline 차원이 없다.

따라서 `create_group_state`·`patch_group_state`의 `target`에 `worldline_id`가 **있으면(값이 `null`이든 UUID든) 거부한다.**

이유는 편의가 아니라 identity 모호성이다. `worldline_id`를 허용하면 같은 room-level 행 하나를 `worldline_id: null`인 target과 `worldline_id: <UUID>`인 target 두 가지로 지칭할 수 있게 되고, handler는 그 값을 identity에 넣어야 하는지 아닌지 판단할 근거가 없다. `worldline_key`가 `''`와 UUID 사이를 오가면 D1 primary key도 흔들린다.

현재 선택된 세계선은 행 **안**의 암호화된 `active_worldline_id` field로만 존재한다(canonical schema §11.1, E2EE 제안서 §8.2). Worker는 이 값을 읽지 않으며, 각 write가 자기 canonical `worldline_id`를 평문으로 명시하므로 서버 routing에도 필요하지 않다.

대조: `create_worldline`·`patch_worldline`은 target이 **세계선 행 자신**을 가리키므로 `worldline_id`가 필수이고 `null`일 수 없다. 두 entity를 헷갈리지 않도록 validator에서도 서로 다른 규칙(`absent` vs `required`)으로 분리했다.

Room도 물리 identity에 worldline 축이 없지만 canonical room wire object가 `worldline_id: null`을 명시하므로 `absent`가 아니라 `null-only` 규칙을 사용한다. `create_room`·`patch_room` target은 키 누락과 non-null 값을 모두 거부한다. 따라서 `change_log`의 room identity도 `space_id`, `room_id`만 갖는다.

### 4.1.3 operation 규칙표의 단일 source (2026-08-28)

위 표는 `cloudflare/sync-worker/src/contracts/operation.ts`의 `OPERATION_SPECS`·`ENTITY_SHAPES`와 같은 내용이며, 후속 D1 handler는 **이 규칙을 다시 선언하지 않고** 다음 read-only 경로로 조회한다.

| export | 용도 |
| --- | --- |
| `getOperationSpec(op)` | 검증 완료된 operation의 `entityType`·`kind`·`phoneSpaceOnly`·`requiresBubbleOrder` |
| `getEntityShape(entityType)` | 그 entity의 필수 target 필드와 `worldlineRule` |
| `SCHEMA_OPERATIONS` / `RUNTIME_ENABLED_OPERATIONS` | 16개 / 15개 목록. 둘 다 `OPERATION_SPECS`에서 파생되므로 갈라질 수 없다 |
| `isSchemaOperation()` / `isRuntimeEnabledOperation()` | 목록 멤버십 판정 |

반환되는 객체와 배열은 모두 `Object.freeze`돼 있다. `as const`는 compile-time 보장일 뿐이라, handler가 런타임에 `phoneSpaceOnly`를 뒤집으면 validator가 참조하는 바로 그 객체가 바뀌기 때문이다. 규칙을 바꿔야 하면 표 자체를 고치고 이 문서를 함께 갱신한다.

### 4.1.4 `patch_room` v1 storage mapping

Room 본체의 encrypted wire field → D1 column mapping은 `title→title_enc`, `status_message→status_message_enc`, `music_title→music_title_enc`, `music_artist→music_artist_enc` 네 개다. Handler는 이 fixed map을 소유하며 문법 validator만으로 임의 column 이름을 만들지 않는다.

`extensions.<namespace>.<entity>.<field>`은 같은 operation의 `room_extension_field` mutation이며 room 본체·revision·ledger와 같은 batch에 들어간다. 이를 무시하거나 별도 transaction으로 적용하지 않는다.

`patch_room`의 engine/persona metadata pair는 `room_ai_state_ref`를 upsert/clear한다. `create_room`은 reference row를 만들지 않는다. 존재하지 않는 pair를 clear하는 것은 idempotent no-op이고, 두 pair가 모두 null이면 reference row를 삭제할 수 있다.

`create_room`은 room 본체와 `room_extension_field`만 같은 transaction에서 만든다. `PHONE_SPACE` room이라고 해서 `group_state`나 `worldline`을 자동 생성하지 않는다. Worker는 암호화된 room payload로 group semantics를 판정할 수 없고, 두 entity는 각자의 명시적 create operation과 ledger event를 가져야 한다. 따라서 room만 존재하는 상태는 후속 `create_group_state`·`create_worldline`이 도착하기 전의 유효한 중간 상태다.

Engine/persona exact-revision reference는 create payload에 싣지 않는다. 필요한 client는 room create가 성공한 뒤 `patch_room` metadata pair로 연결하며, 두 operation은 각각 revision과 `server_seq`를 소비한다. v1은 이를 하나의 암묵적 복합 create로 합치지 않는다.

`avatar_ref`는 canonical 필드지만 v1 D1 projection과 operation metadata 경로가 아직 없으므로 현재 `patch_room`에서 지원하지 않는다. Validator가 avatar key를 받지 않으며 handler가 임의 column·attachment mapping을 발명하지 않는다. Avatar write를 열기 전에 별도 schema와 operation 계약을 확정한다.

### 4.2 `GET /v1/sync/changes`

```text
GET /v1/sync/changes?after_seq=10400&limit=100
```

- `after_seq`는 마지막으로 완전히 적용한 account-wide cursor다.
- `limit` 기본 100, 최대 500.
- response는 `change_log` page와 각 identity의 **현재 canonical projection**을 함께 돌려준다.
- 같은 entity가 page 안에 여러 번 나오면 identity를 deduplicate해 최신 projection 하나만 포함해도 된다.
- projection의 `server_seq`가 page 마지막 sequence보다 클 수 있다. client는 entity revision/server_seq가 더 낮거나 같은 후속 event를 idempotently 무시한다.
- turn·bubble tombstone은 canonical 행의 soft-delete 상태로 영구 유지해 bootstrap과 pull 모두에서 삭제를 재현한다. v1 Worker는 tombstone 행을 물리 삭제하지 않는다.

```json
{
  "protocol_version": 1,
  "request_id": "90000000-0000-4000-8000-000000000010",
  "result": {
    "scanned_through_seq": 10427,
    "account_high_watermark_seq": 10431,
    "has_more": true,
    "changes": [
      {
        "change_seq": 10427,
        "entity_type": "room",
        "identity": "OPAQUE_CANONICAL_IDENTITY",
        "projection": "OPAQUE_WIRE_PROJECTION"
      }
    ]
  }
}
```

client는 page의 모든 projection을 local replica에 durable하게 적용한 뒤에만 cursor를 `scanned_through_seq`로 전진한다.

### 4.3 `GET /v1/sync/bootstrap`

새 기기나 remote replica 초기화용이다.

```text
GET /v1/sync/bootstrap?limit=200
GET /v1/sync/bootstrap?cursor=<opaque-non-secret-cursor>&limit=200
```

- 첫 page가 `snapshot_high_watermark_seq`를 확정한다.
- cursor는 high watermark, 마지막 entity type, 마지막 storage key를 canonical encoding하고 Worker secret으로 MAC한 opaque 값이다.
- page는 `(entity_type, storage_key)` 순으로 안정적으로 정렬한다.
- projection이 snapshot watermark보다 새 버전이어도 적용 가능하다. bootstrap 종료 뒤 `after_seq = snapshot_high_watermark_seq`로 pull하면 중복 event가 오지만 revision check로 무해하다.
- cursor 변조·다른 account 재사용·만료는 `VALIDATION_FAILED`로 거부한다.
- bootstrap 완료 전 remote 탭을 쓰기 가능 상태로 바꾸지 않는다.

## 5. D1 transaction 계약

### 5.1 operation 적용 순서

1. device 인증과 body 형식·scope·field path를 검증한다.
2. HTTP request body 원본 bytes의 SHA-256 fingerprint를 계산한다. 원본 body와 fingerprint는 로그에 쓰지 않는다.
3. 기존 `(account_id, operation_id)`를 읽는다.
   - fingerprint 같음: 최초 결과 반환
   - fingerprint 다름: replay mismatch
4. 신규 operation이면 D1 `batch()` 한 번에 다음 statement를 순서대로 실행한다.
   1. `transaction_guard`에 base revision/existence 검증 결과를 삽입한다. false는 `CHECK` violation으로 전체 rollback한다.
   2. account의 현재 `next_server_seq`를 이번 operation에 할당한다. 값이 `2^53` 소진 sentinel이면 guard failure로 전체 rollback한다.
   3. canonical row create/patch를 적용한다. 초기 runtime에서 `delete_turn`은 계속 거부한다.
   4. `operation_log`에 fingerprint·결과 revision·할당 sequence를 삽입한다.
   5. `change_log`에 canonical storage identity·change kind·revision·sequence를 한 행 삽입한다.
   6. account `next_server_seq`를 1 증가시키고 guard row를 삭제한다.
5. 동시에 같은 operation이 들어와 unique violation이 나면 transaction 전체가 rollback된다. 기존 operation을 다시 읽어 replay/mismatch로 응답한다.

`batch()`는 statement를 순차 실행하고 하나가 실패하면 전체 sequence를 rollback한다. CAS mismatch가 단순히 `UPDATE 0 rows`로 끝나면 batch는 성공해 버리므로 **guard constraint가 필수**다.

### 5.2 tombstone과 `bubble_order`

- `turn`·`bubble`은 `is_tombstoned`, `tombstoned_at`, `tombstone_operation_id`를 가진다.
- tombstone 행도 `(account, scope, bubble_order)` unique 제약과 `max + 1` 계산에 포함한다.
- tombstone 적용 시 identity·order·삭제 metadata만 남기고 암호화 content 컬럼은 `NULL`로 비운다. soft-delete는 삭제된 content를 계속 보관한다는 뜻이 아니다.
- 호감도 되돌림은 Worker 계산이 아니라 client가 함께 보낸 encrypted group/worldline state patch이며, tombstone과 같은 CAS batch에서 적용한다.
- 새 bubble의 번호는 살아 있는 행만 대상으로 계산하지 않는다.
- v1에는 tombstone retention·물리 삭제 endpoint와 cleanup job을 두지 않는다.
- 향후 물리 삭제를 도입하려면 scope별 최고 발급 번호 watermark를 먼저 영구 entity로 만들고 CAS 발급을 검증한다.

### 5.3 sequence 규칙

- `server_seq`는 account 단위 `1...2^53-1`이다.
- 성공한 신규 operation만 한 값을 소비한다.
- replay, validation failure, CAS failure는 값을 소비하지 않는다.
- 중복은 금지하고 gap은 허용한다.
- 상한 도달 시 wrap하지 않고 fail-closed한다.
- `change_log(account_id, server_seq)` index는 pull hot path다.

`account.next_server_seq`는 이름 그대로 **다음 미할당 값**이다. 기존·신규 account의 초기값은 1이다. 실제 change에 할당 가능한 범위는 `1...2^53-1`이고, 내부 값 `2^53`은 모든 sequence가 소진됐다는 sentinel로만 허용한다. sentinel은 response·row `server_seq`·cursor에 쓰지 않는다. 할당한 값을 canonical row·두 ledger에 기록한 뒤 같은 batch 마지막에 1 증가시키므로 실패한 batch는 값도 소비하지 않는다.

### 5.3.1 M06 ledger v1 row 계약

`operation_log`는 `(account_id, operation_id)` primary key와 `request_fingerprint`, `entity_type`, `change_kind`, nullable `result_revision`, `server_seq`를 가진다. fingerprint는 lowercase SHA-256 hex이고 raw body를 저장하지 않는다. `result_revision`은 attachment처럼 revision이 없는 projection에서 null이며, replay response는 나머지 저장 값으로 재구성한다.

`change_log`는 `(account_id, server_seq)` primary key를 유지한다. identity는 serialized JSON/blob/owner key가 아니라 다음 nullable plaintext column으로 저장한다: `space_id`, `room_id`, `worldline_key`, `turn_id`, `message_id`, `persona_snapshot_id`, `snapshot_revision`, `engine_profile_id`, `profile_revision`, `checkpoint_id`, `attachment_id`. `entity_type`별 `CHECK`가 canonical storage key에 필요한 축만 정확히 non-null이 되도록 강제한다. `worldline_key = ''`는 D1 내부 key 표현이며 API projection에서는 nullable `worldline_id`로 되돌린다.

| entity_type | non-null identity column |
| --- | --- |
| `room`, `group_state` | `space_id`, `room_id` |
| `worldline` | `space_id`, `room_id`, `worldline_key` |
| `turn` | `space_id`, `room_id`, `worldline_key`, `turn_id` |
| `bubble` | `space_id`, `room_id`, `worldline_key`, `turn_id`, `message_id` |
| `persona_snapshot` | `space_id`, `persona_snapshot_id`, `snapshot_revision` |
| `engine_profile` | `space_id`, `engine_profile_id`, `profile_revision` |
| `checkpoint` | `space_id`, `room_id`, `worldline_key`, `checkpoint_id` |
| `attachment` | `attachment_id` |

표에 없는 identity column은 반드시 null이다. `account_id`는 모든 행의 PK 앞축이라 표에서 생략했다.

`change_kind` v1 enum은 `upsert`, `tombstone`이다. 현재 runtime의 15개 operation은 모두 한 canonical projection owner를 가지므로 성공 operation 하나가 sequence 하나와 change row 하나를 만든다. `create_persona_snapshot`의 immutable row+head CAS는 persona snapshot projection 하나로 기록한다. 여러 child bubble까지 바꾸는 `delete_turn`은 runtime 금지를 유지하며, 이를 열기 전에 fan-out event·PK 계약을 별도로 확정한다.

Identity column에는 polymorphic FK를 두지 않는다. entity별 shape는 `CHECK`로 강제하고 handler가 같은 batch에서 canonical row의 존재를 보장한다. v1 canonical row는 immutable 또는 tombstone 보존이며 physical delete가 금지돼 있으므로 dangling change identity가 생기지 않는다.

`transaction_guard`는 영구 schema의 scratch table이다. `(account_id, operation_id)`를 key로 하고 `ok INTEGER NOT NULL CHECK (ok = 1)`을 둔다. handler는 scalar existence/revision predicate 결과를 insert하고 성공 batch 끝에서 삭제한다. false와 missing entity는 각각 CHECK/NOT NULL violation으로 batch 전체를 rollback하며, 실패 insert도 transaction rollback 때문에 남지 않는다.

### 5.4 read consistency

v1은 read replication을 활성화하지 않는다. 활성화하는 후속 버전은 D1 Sessions API를 사용한다.

- client는 마지막 `X-Sync-Bookmark`를 다음 request에 보낼 수 있다.
- Worker는 bookmark가 없으면 `first-primary`, 있으면 해당 bookmark로 session을 연다.
- response는 새 bookmark를 같은 header로 돌려준다.
- bookmark는 `server_seq`를 대체하지 않는다. bookmark는 D1 sequential consistency, sequence는 앱 동기화 cursor다.

## 6. Attachment·avatar endpoints

R2 payload는 공개 URL로 노출하지 않고 Worker binding을 통해 stream한다. Workers Free request body 상한은 100MB이므로 v1 12MiB보다 크지만, 앱·Worker 규격은 더 작은 자체 상한을 적용한다.

### 6.1 정확한 상한

Android 현재 코드는 `12 * 1024 * 1024`를 사용한다. v1 source payload 상한은 **12,582,912 bytes**로 해석한다. 이 값은 Claude 검토가 끝난 뒤 E2EE 원문에 통합해야 하며, 현재 검토 중인 문서는 이 작업에서 수정하지 않는다.

R2 object는 E2EE §7.1 binary envelope를 Base64 없이 저장한다. 따라서 `MAX_ENCRYPTED_OBJECT_BYTES = 12,582,946`(`12,582,912 + 34`)이다. metadata allocation 단계에서 source가 `1...12,582,912`, ciphertext가 정확히 source + 34인지 먼저 검사한다. content PUT은 `Content-Length`가 metadata의 ciphertext size와 같고 이 상한 이하인지 body를 읽기 전에 다시 검사한다.

### 6.2 상태 기계

```text
allocated → uploaded → ready
    └──────────────→ abandoned
ready → tombstoned → garbage_collected
```

D1 `state` CHECK는 `allocated`, `uploaded`, `ready`, `abandoned`, `tombstoned`, `garbage_collected` 6개 값만 허용한다. 임의 UPDATE를 통한 전이는 허용하지 않으며 handler가 위 edge만 CAS로 적용한다. M05 migration은 enum 저장 경계까지만 만들고 실제 endpoint transition handler는 후속 local handler 작업이다.

### 6.3 endpoints

| Method | Path | 역할 |
| --- | --- | --- |
| POST | `/v1/attachments` | D1 metadata를 `allocated`로 생성하고 난수 R2 key 반환 |
| PUT | `/v1/attachments/{attachment_id}/content` | 인증 후 ciphertext stream을 R2에 저장 |
| POST | `/v1/attachments/{attachment_id}/complete` | R2 `head()`의 size 존재 확인 후 D1을 `ready`로 변경 |
| GET | `/v1/attachments/{attachment_id}/content` | ready·account·device 확인 후 R2 body stream 반환 |

upload 규칙:

- `Content-Length` 필수. 없거나 ciphertext 상한 초과면 body를 읽기 전에 거부한다.
- client가 보낸 `ciphertext_hash`, `key_generation`, source byte size, ciphertext byte size를 metadata에 보존한다.
- Worker는 v1 hot path에서 12MiB 전체를 buffer해 hash하지 않는다. AEAD 검증은 download client가 하고, Phase 2에서 streaming hash의 CPU 비용을 측정한다.
- upload 성공 전 `ready`로 보이지 않는다.
- complete는 R2 object 존재와 byte size를 확인한다. 실패하면 `uploaded/allocated` 상태를 유지해 재시도할 수 있다.
- R2 성공 뒤 D1 complete가 실패한 orphan은 TTL cleanup 대상이지만 Phase 1에서는 삭제하지 않고 보고서로만 찾는다.
- download response는 `Cache-Control: private, no-store`이며 object key를 외부 URL로 노출하지 않는다.

## 7. Pairing·recovery 경계

세부 cryptographic contract는 E2EE 제안서가 source of truth다. Worker API 구현 plan에는 다음 endpoint 군만 포함한다.

- pairing session 생성: 기존 device 재인증 필요
- claim 제출: QR bearer가 가능하되 claim 조회는 불가
- claim 조회·승인: 기존 account device만 가능
- package redeem: 승인된 claim의 verifier를 constant-time 검증하고 원자적으로 1회 소비
- recovery lookup: 복구 문구에서 유도한 lookup/auth를 body로 전달

pairing/recovery material은 sync operation log와 일반 request log에 들어가지 않는다.

## 8. 관측성과 privacy

허용 metric:

- endpoint별 count·status·latency bucket
- D1 rows read/written, batch duration
- R2 bytes in/out, 상태별 attachment count
- cursor lag(`account_high_watermark_seq - after_seq`)
- validation/error code count

금지 metric/log:

- 암호문·hash·nonce·token·UUID 전체값
- room/persona/message/attachment 이름 또는 본문
- 복구·pairing secret
- request/response body dump

상관관계가 필요하면 request마다 random request id를 만들고, account/device는 process-local keyed hash의 짧은 값만 사용한다. 장기 사용자 추적용 identifier로 쓰지 않는다.

## 9. Phase 1 API acceptance

- 같은 operation 재시도는 동일 결과, 다른 payload는 mismatch
- CAS 실패 시 canonical row·sequence·operation/change log가 모두 불변
- concurrent identical operation은 하나만 적용
- tombstone된 꼬리 bubble 뒤 새 bubble이 이전 번호를 재사용하지 않음
- `delete_turn` 중간 실패 시 turn·child bubble·heart revert·change log가 모두 rollback
- 성공한 `delete_turn` 뒤 identity·order는 남고 encrypted content 컬럼은 비어 있음
- nullable worldline null/UUID가 D1 key와 E2EE AAD에서 같은 scope
- pull page를 중간 crash 뒤 재적용해도 결과 동일
- bootstrap 중 concurrent write가 있어도 bootstrap+pull 결과가 최신 상태
- PHONE_SPACE 밖 group write 거부
- plaintext log에 character relationship·content sentinel 없음
- attachment 상태 전이·size·account access 제약
- R2 성공/D1 실패와 D1 allocated/R2 실패를 합성해 복구 가능
- Free plan 10ms CPU, 128MB memory, 50 subrequest 범위는 로컬·remote synthetic measurement 전까지 보장으로 선언하지 않음

## 10. 공식 근거

- [D1 `batch()` transaction](https://developers.cloudflare.com/d1/worker-api/d1-database/#batch)
- [D1 limits와 single-threaded database](https://developers.cloudflare.com/d1/platform/limits/)
- [D1 Sessions API와 bookmarks](https://developers.cloudflare.com/d1/best-practices/read-replication/)
- [R2 Workers binding `get`·`put`](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/)
- [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
- [Wrangler JSONC 권고](https://developers.cloudflare.com/workers/wrangler/configuration/)
