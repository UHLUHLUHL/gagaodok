# Phase 1 Worker validator Codex 통합 검토

- 검토 대상: `2fa06b3`
- 판정: **조건부 승인 — D1 migration 전 계약 보정 3건 필요**
- 범위: local Worker validator·문서·합성 test만 검토. 원격 Cloudflare resource와 실제 데이터는 사용하지 않음.

## 확인된 완료 사항

- 공식 `@cloudflare/vitest-plugin` 1.1.1과 Vitest 4.1.11 조합으로 전환됐다.
- `compatibility_date = 2026-08-01`에서 local Workers runtime test가 경고 없이 실행된다.
- `op`·`entity_type`·target shape가 table-driven validator로 결속됐다.
- `delete_turn`은 schema에는 남지만 초기 runtime에서는 거부되고 `delete_bubble`은 schema에 없다.
- 평문 top-level `relationship_policy`가 제거됐고, client와 Worker의 검증 책임이 분리됐다.
- field envelope는 padded Base64 형태, 최소 34 byte, version·algorithm byte를 검사한다.
- RFC 3339 UTC timestamp는 달력상 존재하는 날짜와 시간 범위를 검사한다.
- `npm test -- --run` 71건, `npm run typecheck`, `git diff --check`를 Codex가 재실행해 통과했다.

Cloudflare 공식 문서도 `@cloudflare/vitest-plugin`과 Vitest 4.1 이상, `cloudflareTest()` plugin 구성을 현재 권장한다.

## D1 migration 전 보정 사항

### R1. `group_state` target에는 `worldline_id`가 없어야 한다

canonical D1 identity는 `(account_id, PHONE_SPACE, room_id)`이고, `group_state` 한 행 안에 `active_worldline_id`와 worldline별 상태가 들어간다. 그런데 현재 validator는 `create_group_state`·`patch_group_state`에 nullable `worldline_id`를 의무화한다.

이 표현을 유지하면 같은 room-level 행을 `null` 또는 특정 UUID가 붙은 서로 다른 요청 target으로 표현할 수 있고, handler가 어느 값을 identity에 포함해야 하는지 모호해진다.

통합 결정:

- `group_state.worldlineRule = "absent"`
- `group_state` target에 `worldline_id`가 있으면 `VALIDATION_FAILED`
- `active_worldline_id`는 암호화된 group-state field로만 유지

### R2. canonical Base64는 decode 후 re-encode equality까지 확인한다

현재 정규식은 alphabet·padding 위치·길이는 검사하지만 마지막 padding byte의 사용하지 않는 bit가 0인지 보장하지 않는다. 서로 다른 문자열이 같은 byte를 decode할 수 있으므로 “canonical” wire representation과 원본-byte fingerprint 계약이 약해진다.

통합 결정:

- 정규식 통과 후 decode한다.
- 같은 표준 padded Base64 encoder로 다시 encode한 문자열이 입력과 byte-for-byte 같아야 한다.
- non-zero pad-bit 표현을 negative fixture로 고정한다.

### R3. operation table 재사용 경로를 실제로 export한다

보고에서는 D1 handler가 `OPERATION_SPECS`·`ENTITY_SHAPES`를 import해 사용한다고 했지만 두 값은 현재 module-local `const`다. 후속 handler가 표를 복제하지 않게 하려면 immutable export 또는 read-only accessor를 제공해야 한다.

통합 결정:

- raw mutable object를 여러 곳에서 다시 만들지 않는다.
- handler가 검증 완료된 operation의 entity·kind·scope rule을 얻는 read-only export/accessor를 둔다.
- test가 schema operation 16개와 runtime operation 15개를 같은 source에서 대조한다.

## 확정된 두 경계

### Attachment identity와 space

- attachment의 canonical identity와 D1 primary key는 `(account_id, attachment_id)`다.
- operation의 `space_id`는 attachment identity 일부가 아니라 **생성 출처와 device 권한 검사**를 위한 평문 metadata다.
- D1 attachment row에는 `origin_space_id`로 저장하되 primary·unique key에는 넣지 않는다.
- 다운로드 권한은 동일 account의 유효 device token으로 검사하며 room UUID를 attachment identity에 억지로 넣지 않는다.

### 암호 검증 책임

- Worker는 Base64·봉투 크기·protocol version·algorithm 같은 **구조**만 검사한다.
- nonce 생성·재사용 방지, AAD 조립·일치, AEAD tag 복호 검증은 키를 가진 Swift/Kotlin client crypto 계층의 책임이다.
- Worker나 D1 handler가 ciphertext를 복호화하거나 AAD 내용을 추론하면 안 된다.
- D1 계층은 받은 envelope byte를 그대로 보존하고 operation idempotency·CAS·tenant 경계만 검사한다.

## 다음 gate

R1~R3이 코드·문서·negative test에 반영된 뒤에만 M00 local D1 harness와 migration을 시작한다. R2 attachment ciphertext 상한은 M05 attachment metadata migration 전에 별도로 확정한다.
