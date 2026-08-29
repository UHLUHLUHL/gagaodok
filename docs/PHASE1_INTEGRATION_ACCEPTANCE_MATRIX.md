# Phase 1 동기화 통합 acceptance matrix

_가가오독 크로스 디바이스 동기화의 문서 계약·fixture·local 구현 상태를 한 곳에서 대조하는 기준표 — 2026-08-28_

---

## 📋 목적과 범위

이 문서는 “무엇이 문서로 합의됐는가”와 “무엇이 실제로 local test를 통과했는가”를 구분한다. 체크 표시가 있어도 Cloudflare 배포, 앱 networking, 실제 대화 업로드가 승인됐다는 뜻은 아니다.

상태 표기:

| 상태 | 의미 |
| --- | --- |
| ✅ 계약·검증 있음 | 문서 계약과 해당 fixture 또는 local test가 존재 |
| 🟡 계약만 있음 | 문서로는 정했지만 구현·실행 검증이 없음 |
| 🔴 차단 | 후속 단계를 진행하면 계약이 깨질 수 있음 |
| ⏳ 후속 단계 | 선행 gate가 끝난 뒤에만 수행 |

## 🧭 단계 의존 관계

```mermaid
flowchart TB
    accTitle: Phase 1 Sync Gates
    accDescr: Contract, local Worker, local D1, synthetic verification, and real-data upload gates. Each later gate requires the preceding one.

    decisions[📋 User decisions] --> contracts[📚 Canonical and E2EE contracts]
    contracts --> worker[⚙️ Local Worker boundary]
    worker --> d1[💾 Local D1 migrations]
    d1 --> synthetic[🔍 Phase 2 synthetic verification]
    synthetic --> approval{👤 Explicit upload approval?}
    approval -->|Yes| shadow[🌐 Phase 3 shadow upload]
    approval -->|No| hold[📌 No real data]

    classDef document fill:#dbeafe,stroke:#2563eb,stroke-width:2px,color:#1e3a5f
    classDef local fill:#ede9fe,stroke:#7c3aed,stroke-width:2px,color:#3b0764
    classDef decision fill:#fef9c3,stroke:#ca8a04,stroke-width:2px,color:#713f12
    classDef blocked fill:#fee2e2,stroke:#dc2626,stroke-width:2px,color:#7f1d1d
    classDef remote fill:#dcfce7,stroke:#16a34a,stroke-width:2px,color:#14532d

    class decisions,contracts document
    class worker,d1,synthetic local
    class approval decision
    class hold blocked
    class shadow remote
```

## ✅ 현재 기준표

| 경계 | 현재 근거 | 상태 | 다음 gate |
| --- | --- | --- | --- |
| 제품 방향·공개 범위 | [사용자 결정 17개](CROSS_DEVICE_SYNC_USER_DECISIONS.md) | ✅ | 구현은 별도 승인 필요 |
| identity·`worldline_id`·`bubble_order` | [canonical schema](PHASE1_CANONICAL_SCHEMA_DRAFT.md), Python contract fixture | ✅ | local D1 제약 test |
| legacy turn·비파괴 조사 | [Phase 0 계획](PHASE0_INVENTORY_PLAN.md), inventory tool·집계 보고서 | ✅ | 합성 importer test |
| E2EE key·AAD·pairing 계약 | [E2EE 제안서](2026-08-27-sync-encryption-proposal.md), vector test | ✅ | Worker pairing endpoint test |
| canonical field ownership·extension | canonical schema, Python contract fixture | ✅ | D1 field·extension row 구현 |
| Worker health·기본 boundary | `2fa06b3`의 local Worker 71 tests | ✅ | D1 연결 뒤 health 회귀 test |
| operation target·field envelope 검사 | `e83bce1`, [Worker validator 통합 검토](2026-08-28-phase1-worker-validator-codex-review.md) | ✅ | handler가 exported operation table 재사용 |
| M00~M02 local D1 schema | `def5260`, `515c036`, `381000f` | ✅ | M03 owner별 extension table 구현 |
| M03 turn·bubble·extension schema | `8bd7f68`, `6bffb35` | ✅ | M04 versioned AI state preflight |
| M04 versioned AI state contract | `3c462b5`, `b2a93c6` DDL·metadata validator·320 tests | ✅ | M05 attachment migration |
| M05 attachment persistence | `5299b27` DDL·validator·bubble FK rebuild, Codex focused 50 tests 중 M05 포함 | ✅ | M06 ledger 뒤 local R2 endpoint |
| Device token auth boundary | `fa49ed1` canonical token/hash/revoked local boundary, Codex focused auth review | ✅ | M06 handler·attachment route에 연결 |
| M06 ledger DDL | `d33ee67`, `4a8bf26`; Codex focused 45 tests | ✅ | operation handler atomic batch |
| patch_room atomic handler | `8d7a8fd`, `f712c8e`, `62a83f4`; Codex focused 212 tests | ✅ | create_room과 나머지 operation family 확장 |
| create_room atomic handler | `2b456a3`; Codex focused room-family 228 tests | ✅ | group_state/worldline family 확장 |
| group_state/worldline atomic handlers | `37e408c`, `f8e766b`, `06d401e`; Codex focused 41 tests | ✅ | versioned AI state family preflight |
| versioned AI state atomic handlers | `f7195f3`, `da5b201`, `b69d8ee`, `04c9197`; Codex focused 222 tests | ✅ | turn/bubble family preflight |
| turn/bubble atomic handlers | `2875ef4`, `7328825`, `60594d8`; Codex focused 64 tests | ✅ | create_attachment handler·route preflight |
| attachment atomic handler | `ea731c7`; Codex focused 249 tests | ✅ | operation HTTP route envelope |
| D1 transaction·CAS·idempotency | `0008` ledger와 runtime-enabled operation 15개 atomic handler | ✅ | HTTP route와 Phase 2 다중 isolate 합성 검증 |
| operation HTTP route | `d71d5eb`, `981490b`; Codex focused 20 tests | ✅ | local R2 attachment routes |
| R2 attachment state machine | canonical schema·Worker API의 6-state·12,582,946-byte 계약, `5299b27` persistence | 🟡 | M06 ledger 뒤 local R2 state transition test |
| Android phone attachment entry | `0b6d318`, `f5a87da` | ✅ | M05 이후 cross-device upload 연결; release 실기기 방향 재확인 |
| pull·bootstrap·cursor | Worker API 초안 | 🟡 | local pagination/crash fixture |
| 앱 durable outbox·remote UI | canonical schema의 계약만 존재 | ⏳ | Worker·D1 synthetic test 통과 뒤 |
| Phase 3 실제 data shadow upload | 사용자 별도 승인 없음 | ⏳ | Phase 0~2 gate 및 명시 승인 |

## 🔍 Phase 1 통합 gate

Phase 1을 “계약·local boundary가 구현 가능한 상태”라고 판정하려면 아래 항목이 모두 필요하다.

### Worker HTTP boundary

- [x] `@cloudflare/vitest-plugin` + Vitest 4.1 이상으로 local test stack 전환
- [x] operation별 `op`·`entity_type`·target ID·revision 규칙을 table-driven validator로 고정
- [x] 초기 runtime에서 `delete_turn`·`delete_bubble` 거부
- [x] 평문 top-level `relationship_policy` 제거
- [x] canonical Base64를 decode→re-encode equality까지 검사 (`e83bce1`)
- [x] 실제 RFC 3339 UTC 날짜·시간 값 검사
- [x] 기존 health·content-free error·배포 방지 test 유지
- [x] `group_state` target에서 `worldline_id`를 금지 (`e83bce1`)
- [x] 후속 handler가 operation table을 복제하지 않도록 read-only 재사용 경로 제공 (`e83bce1`)
- [x] canonical device token parse·hash lookup·revoked 거부 경계 (`fa49ed1`)

### D1 persistence boundary

- [x] M00 harness와 M01 account/device·FK local migration (`def5260`, `515c036`)
- [x] M02 room·group_state·worldline primary·FK·`CHECK` contract (`381000f`)
- [x] `worldline_key = COALESCE(worldline_id, '')` 일치 test (`381000f`)
- [ ] tombstone 행이 identity·`bubble_order`를 계속 보존하는 test
- [ ] CAS failure가 canonical row·sequence·operation/change log 전체를 rollback하는 test
- [ ] idempotent replay가 sequence를 추가 소비하지 않는 test
- [x] M01·M02 tenant/account 경계를 D1 FK로 강제
- [x] M05 attachment DDL·bubble account-scoped FK rebuild (`5299b27`)
- [x] M06 account sequence·operation/change ledger·transaction guard DDL (`4a8bf26`)
- [x] patch_room CAS failure·replay·revoked·cross-space write의 전체 rollback (`f712c8e`, `62a83f4`)
- [ ] attachment state transition test

### Integration evidence

- [ ] Swift·Kotlin E2EE fixed vector 교차 복호화
- [ ] local Worker + local D1 + local R2 synthetic end-to-end test
- [ ] request·error·metric에서 content/token/ciphertext가 새지 않는 test
- [ ] 실데이터 없이 fixture만 사용했다는 commit-level 확인

## ⚠️ 지금 하면 안 되는 일

- Cloudflare account 로그인, D1·R2 생성, deploy 또는 `--remote` migration
- 실제 대화 archive·첨부·복구 문구를 test fixture로 복사
- Worker의 opaque ciphertext를 복호화하거나 분석하기
- Phase 3 shadow upload 또는 Phase 5 양방향 write 활성화

## ✍️ 소유 경계

| 담당 | 현재 소유 범위 | 완료 산출물 |
| --- | --- | --- |
| Claude Code | `cloudflare/sync-worker/`의 runtime operation transaction service | entity family별 atomic handler와 focused tests |
| Codex | canonical schema, Worker API, 이 matrix, [D1 migration plan](PHASE1_D1_MIGRATION_PLAN.md), [Phase 2 합성 계획](PHASE2_SYNTHETIC_SYNC_TEST_PLAN.md), synthetic fixture와 test | family별 identity·CAS·replay 위험 검토와 통합 판정 |
| 사용자 | 실제 데이터 접근·원격 resource 생성·업로드 승인 | 별도 명시 지시 |

M03~M05, device token 인증, M06 ledger DDL, runtime-enabled operation 15개의 atomic handler와 `POST /v1/sync/operations` HTTP route는 모두 승인됐다. 다음은 별도 allocation route 없이 local R2 upload·complete·download state flow를 연다. Upload·complete는 origin space device에 한정하고, ready 전이만 account sequence와 attachment change event를 발행한다.

## 🔗 관련 문서

- [사용자 결정 기록](CROSS_DEVICE_SYNC_USER_DECISIONS.md)
- [기술 합의문](CROSS_DEVICE_SYNC_AGREEMENT.md)
- [canonical schema 통합 초안](PHASE1_CANONICAL_SCHEMA_DRAFT.md)
- [Worker API 초안](PHASE1_WORKER_API_DRAFT.md)
- [Worker scaffold Codex 검토](2026-08-28-phase1-worker-scaffold-codex-review.md)
- [Worker validator Codex 통합 검토](2026-08-28-phase1-worker-validator-codex-review.md)
- [D1 migration 선행 계획](PHASE1_D1_MIGRATION_PLAN.md)
