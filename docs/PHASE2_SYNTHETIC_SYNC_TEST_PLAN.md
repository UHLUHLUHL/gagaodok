# Phase 2 합성 동기화 시험 계획

_실제 대화나 원격 Cloudflare resource 없이 Worker·D1·R2 계약을 검증하기 위한 local-only 계획 — 2026-08-28_

## 목적과 경계

Phase 2는 Phase 1에서 고정한 wire·identity·migration 계약을 **결정적 합성 자료**로 연결해 검증한다. 이 단계의 성공은 실제 사용자 data 업로드나 양방향 동기화 승인이 아니다.

- 입력은 `tools/synthetic_sync_fixture.py`가 생성한 합성 fixture만 사용한다.
- Worker와 D1은 opaque envelope의 구조와 byte 보존만 다룬다. 복호화, AAD 의미 검사, nonce 재사용 판정, AEAD tag 검증은 하지 않는다.
- D1·R2·Worker는 local emulator만 사용한다. Cloudflare 로그인, remote binding, resource 생성, deploy, `--remote` migration을 하지 않는다.
- 본문, 암호문 전체, token, 복구 문구, 전체 UUID를 request·error·metric·test log에 출력하지 않는다.
- Phase 0 집계 문서는 sizing 참고일 뿐 fixture source가 아니다. 실제 archive를 열거나 복사하지 않는다.

## 현재 진입 상태

| 경계 | 현재 근거 | 상태 |
| --- | --- | --- |
| canonical identity·nullable worldline | `PHASE1_CANONICAL_SCHEMA_DRAFT.md`, contract fixture | 완료 |
| Worker operation shape·canonical Base64 | `e83bce1` | 완료 |
| M00 local D1 harness | `def5260` | 완료 |
| M01 account/device와 device-account FK | `def5260`, `515c036` | 완료 |
| M02 conversation scope | `381000f` | 완료 |
| M03 turn·bubble·extension | `8bd7f68`, `6bffb35` | 완료 |
| M04 versioned AI state | `3c462b5`, `b2a93c6` | 완료 |
| M03~M04 persistence | `8bd7f68`, `6bffb35`, `3c462b5`, `b2a93c6` | 완료 |
| M05 persistence | `5299b27` attachment DDL·validator·bubble FK rebuild | 완료 |
| device auth boundary | `fa49ed1` canonical token hash lookup·revoked 거부 | 완료; route 연결은 M06 이후 |
| M06 ledger persistence | `4a8bf26` account sequence·operation/change log·guard | 완료 |
| M06 patch_room handler | `8d7a8fd`, `f712c8e`, `62a83f4` auth·space·replay·CAS·atomic batch | 완료 |
| M06 remaining handlers | create_room 포함 runtime operation family | 구현 대기 |
| local R2 attachment flow | source 12,582,912 / binary ciphertext 12,582,946 계약·합성 metadata fixture | M06 ledger·endpoint 대기 |
| Swift·Kotlin fixed-vector 교차 검증 | 통합 증거 없음 | 대기 |

물리 migration 파일 `0002_device_account_fk.sql`은 논리 M02가 아니라 **M01 account boundary의 FK 보완**이다. 논리 M02는 `room`·`group_state`·`worldline`이다.

## 합성 fixture 계약

`tools/synthetic_sync_fixture.py`의 출력은 다음 특성을 가진다.

1. 같은 코드와 입력에서 canonical JSON byte가 항상 같다.
2. 예약된 합성 account 두 개와 합성 device·room·worldline identity만 쓴다.
3. `MAC_SPACE`·`PHONE_SPACE`·`TABLET_SPACE`를 모두 포함한다.
4. 동일 room UUID를 account와 space별로 분리해 tenant/scope 격리를 시험할 수 있다.
5. `group_state`는 `PHONE_SPACE`에만 있고 worldline identity를 갖지 않는다.
6. `worldline`은 null `worldline_id → worldline_key = ''`와 UUID `worldline_id → 동일 key` 두 경우를 포함한다.
7. revoked device는 저장 상태로만 표현한다. DDL trigger가 write를 거부한다고 가정하지 않는다.
8. 최소 34-byte v1 AES-GCM envelope **모양 sentinel**을 canonical padded Base64로 제공한다. 이는 실제 암호문이나 유효한 AEAD 결과가 아니다.
9. CLI는 출력 파일의 record 수와 SHA-256만 보고하며 identity나 envelope 전체를 출력하지 않는다.

fixture는 미래 D1 row의 완성형 schema가 아니다. 아직 고정되지 않은 M03~M06 column이나 handler response를 미리 발명하지 않고, 각 migration이 소비할 공통 구조 계약만 제공한다.

## 단계별 시험 순서

| 순서 | 대상 | 합성 검증 | 진입 조건 |
| ---: | --- | --- | --- |
| P2-00 | fixture 자체 | 결정성, synthetic provenance, 금지 field 부재, 안전한 CLI 출력 | 즉시 가능 |
| P2-01 | M00·M01 | migration replay, account/device FK, 기존 row 보존, tenant isolation | 진입 가능 |
| P2-02 | M02 | room parent FK, PHONE-only group/worldline, checked `worldline_key` | 진입 가능 |
| P2-03 | M03 | turn/bubble key, scope-wide `bubble_order`, tombstone·unknown extension 보존 | M03 커밋 승인 |
| P2-04 | M04 | immutable engine/persona revision, mutable head/checkpoint CAS | M04 커밋 승인 |
| P2-05 | M05 + local R2 | attachment identity, size 상한, lifecycle, orphan 보고 | DDL 완료; M06 뒤 local R2 구현 |
| P2-06 | M06 handler | atomic row·sequence·operation/change log, replay, CAS rollback | M06 migration·handler 구현 |
| P2-07 | pull/bootstrap | stable pagination, tombstone projection, crash 뒤 재적용 | pull handler 구현 |
| P2-08 | crypto clients | Swift↔Kotlin fixed-vector 교차 복호화와 AAD 일치 | 두 client crypto 구현 |
| P2-09 | 연결 E2E | local Worker→D1→R2 왕복과 비노출 검사 | P2-00~08의 관련 gate 통과 |

뒤 단계는 앞 단계의 schema나 handler를 흉내 낸 mock으로 통과시키지 않는다. 아직 구현되지 않은 단계는 `대기`로 남긴다.

## 핵심 acceptance 시나리오

### Tenant와 scope

- 같은 room UUID가 다른 account에서 충돌하거나 조회에 섞이지 않는다.
- 같은 account의 같은 room UUID가 다른 space에서 독립 key를 가진다.
- 다른 account의 device·room·operation을 빌려 쓴 write를 거부한다.
- group/worldline row는 `PHONE_SPACE`가 아니면 거부한다.

### Nullable worldline

- API·AAD는 nullable `worldline_id`를 보존한다.
- D1은 null을 빈 `worldline_key`로 materialize한다.
- UUID worldline은 ID와 key가 byte-for-byte 같아야 한다.
- non-null worldline ID는 `PHONE_SPACE`에서만 허용하고 MAC/TABLET에서는 거부한다.
- null default scope는 세 canonical space에서 모두 허용한다.
- 불일치 pair와 sentinel UUID fallback을 거부한다.

### Atomic write와 replay

- CAS mismatch 시 canonical row, account sequence, operation log, change log가 모두 불변이다.
- 같은 operation ID와 같은 raw-body fingerprint는 최초 결과를 재사용하며 sequence를 추가 소비하지 않는다.
- 같은 operation ID와 다른 fingerprint는 mismatch다.
- concurrent identical operation은 한 번만 적용된다.
- `account.next_server_seq`와 ledger 검증은 M06 전에는 수행 완료로 표시하지 않는다.
- `next_server_seq`는 다음 미할당 값이며 초기값 1, 실제 최대 할당값 `2^53-1`, 내부 `2^53`은 소진 sentinel이다.
- 성공한 v1 runtime operation 하나는 `change_log` 한 행과 sequence 하나를 만들며 `change_kind`는 `upsert|tombstone`이다.
- change identity는 entity별 nullable storage-key 축의 정확한 non-null 조합을 검증하고 serialized identity나 실제 content를 포함하지 않는다.

### Attachment와 local R2

- attachment identity는 `(account_id, attachment_id)`이고 `space_id`는 `origin_space_id` metadata다.
- allocated→uploaded→ready 전이와 size/hash metadata를 검증한다.
- Worker는 body를 복호화하거나 AEAD를 검증하지 않는다.
- R2 성공 뒤 D1 complete 실패는 Phase 2에서 자동 삭제하지 않고 orphan으로 보고한다.
- source 상한은 12,582,912 bytes, §7.1 binary envelope ciphertext 상한은 12,582,946 bytes다. fixture는 payload 없이 metadata와 34-byte 차이만 검증한다.

### Pull, crash recovery, logging

- `(account_id, server_seq)` cursor가 stable page ordering을 제공한다.
- page 적용 중 crash 후 같은 page를 재적용해도 결과가 같다.
- tombstone projection이 삭제를 누락하거나 physical delete로 바뀌지 않는다.
- 성공·실패·replay·CAS·pagination 모든 경로에서 content, token, recovery material, envelope 전체가 log에 없다.
- correlation이 필요하면 전체 account/device UUID 대신 짧은 비가역 식별자와 random request ID만 쓴다.

## 검증 명령과 증거

fixture 자체의 focused 검증:

```sh
python3 -m unittest tools.tests.test_synthetic_sync_fixture
python3 tools/synthetic_sync_fixture.py --output /tmp/gagaodok-synthetic-sync-fixture.json
git diff --check
```

`/tmp` 출력은 개발 중 local 확인용이며 커밋하지 않는다. 이후 각 migration·handler 구현자는 자신이 소유한 focused suite를 실행한다. Codex 리뷰는 구현자가 이미 실행한 전체 suite를 이유 없이 반복하지 않고, disputed 또는 고위험 경계만 재검증한다.

각 증거에는 commit hash, 실행 명령, 실제 test 수와 결과, local/remote 구분을 남긴다. build 성공만으로 runtime E2E를 통과했다고 선언하지 않는다.

## Phase 2 종료 gate

다음이 모두 충족돼야 Phase 2를 완료로 판정한다.

- [x] 결정적 synthetic fixture와 focused test
- [x] M01 FK 명칭·upgrade 경계 통합 승인 (`515c036`)
- [x] M02 conversation scope local migration 통합 승인 (`381000f`)
- [ ] M02~M06 local migration과 각 focused acceptance test
- [ ] local Worker handler의 CAS·idempotency·account sequence 원자성
- [ ] local R2 attachment lifecycle과 확정된 ciphertext 상한
- [ ] pull/bootstrap pagination·crash recovery
- [ ] Swift·Kotlin E2EE fixed-vector 교차 검증
- [ ] local Worker + D1 + R2 synthetic E2E
- [ ] request·error·metric 민감정보 비노출 검증
- [ ] 모든 fixture가 합성 자료뿐이라는 commit-level 확인

이 gate를 통과해도 Phase 3 실제 data shadow upload는 자동 승인되지 않는다. 실제 data 접근, Cloudflare resource 생성, remote migration과 upload는 사용자의 별도 명시 승인이 필요하다.
