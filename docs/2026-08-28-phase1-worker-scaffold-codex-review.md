# Phase 1 Worker scaffold Codex 통합 검토

_검토 대상: `7c4cb32`, `7044ffc` — 2026-08-28_

---

## 📋 판정

| 커밋 | 판정 | 이유 |
| --- | --- | --- |
| `7c4cb32` | 승인 | 실제 `source_space` 값과 Base64·AEAD envelope 산술이 계약 및 표준 라이브러리 결과와 일치 |
| `7044ffc` | 조건부 승인 | local-only 실행 기반과 기본 validator는 유효하지만, Worker operation 경계에 차단 사항 4건과 보완 2건이 남음 |

`7044ffc`는 되돌리지 않는다. health endpoint, content-free 오류 envelope, canonical space·UUID·safe integer 검사, local D1·R2 binding, 배포 방지 설정은 후속 작업의 좋은 기반이다. 다만 현재 `parseOperationRequest()`를 실제 push endpoint에 연결해서는 안 된다.

이번 판정은 local scaffold와 계약 validator에 한정한다. Cloudflare 리소스 생성, 배포, D1 migration, 앱 networking, 실제 데이터 업로드를 승인하지 않는다.

## ✅ 독립 재검증

| 검증 | 결과 |
| --- | --- |
| `python3 -m unittest tools.tests.test_canonical_schema_contract` | 64 tests OK |
| `python3 -m unittest tools.tests.test_sync_inventory tools.tests.test_e2ee_contract_vectors tools.tests.test_canonical_schema_contract` | 76 tests OK |
| `python3 -m py_compile ...` | 이상 없음 |
| `npm test -- --run` | 2 files, 40 tests OK |
| `npm run typecheck` | 오류 없음 |
| 배포 방지 설정 | `workers_dev: false`, route·`account_id` 없음, D1 zero UUID, R2 `do-not-create`, deploy script 없음 확인 |
| 원격 Cloudflare 접근 | 실행하지 않음 |

`7c4cb32`의 `base64_encoded_length(n) = 4 * ceil(n / 3)`과 34-byte envelope 계산은 Python 표준 라이브러리 출력과 일치한다. 정확한 D1 text 크기를 `P`와 `F`만으로 하나의 값처럼 쓰지 않고 범위로 내린 보정도 타당하다.

## 🚫 통합 차단 사항

### 1. 초기 runtime이 `delete_turn`을 허용한다

[`PHASE1_WORKER_API_DRAFT.md`](PHASE1_WORKER_API_DRAFT.md)는 사용자 결정 15에 따라 `delete_turn`을 schema에만 정의하고 초기 runtime에서는 거부하도록 고정한다. 그러나 `operation.ts`의 `OPERATIONS`에는 `delete_turn`이 포함되어 있고 `parseOperationRequest()`가 그대로 받아들인다.

다음처럼 schema 지원 목록과 현재 runtime 허용 목록을 분리해야 한다.

- `SCHEMA_OPERATIONS`: 미래 호환 문서에 정의된 operation 포함
- `RUNTIME_ENABLED_OPERATIONS`: 첫 테스트에서 실제 수용하는 operation만 포함
- `delete_turn`·`delete_bubble`은 삭제 기능 flag가 명시적으로 열린 뒤에만 runtime 목록에 추가

회귀 시험은 `delete_turn`이 올바른 target·`base_revision`을 가져도 초기 runtime에서 거부되는지를 확인해야 한다.

### 2. 암호화 필드인 `relationship_policy`가 평문 top-level로 되살아났다

Canonical schema §4는 `relationship_policy`를 암호화 대상(`🔒`)으로 정하고 예시도 `ENC(...)`로 고정한다. 그런데 `operation.ts`는 이를 평문 top-level 필드로 허용하고 값까지 검사한다.

이 상태는 두 계약을 동시에 깨뜨린다.

- 정책 값과 변경 시점이 서버에 평문으로 노출됨
- `set.relationship_policy`의 암호문과 top-level 평문이 서로 다를 때 어느 쪽이 권위 원본인지 정의되지 않음

평문 top-level `relationship_policy`를 제거해야 한다. Worker는 `group_state`·`worldline` operation이 `PHONE_SPACE`에만 존재하는지는 검사할 수 있지만, 암호화된 engine profile 내부의 `relationship_policy = group` 값 자체는 읽을 수 없다. 따라서 canonical schema의 “Worker와 client 양쪽에서 값 검사” 문구도 E2EE 경계에 맞게 다음처럼 보정해야 한다.

- Client: 복호화한 `relationship_policy` enum과 space 제약 검사
- Worker: 평문 entity·space·권한 경계 검사
- Server가 암호화된 정책 값의 진위를 직접 확인하지 못한다는 한계를 명시

### 3. `op`·`entity_type`·target identity가 서로 결속되지 않는다

현재 `entity_type`은 소문자 정규식만 통과하면 된다. 예를 들어 `patch_room`에 `entity_type = worldline`을 붙여도 거부되지 않는다. target도 room·turn·bubble용 ID만 알고 있어 다음 canonical identity를 표현하거나 검증할 수 없다.

- `persona_snapshot_id` + `snapshot_revision`
- `engine_profile_id` + `profile_revision`
- `checkpoint_id`
- `attachment_id`

이 상태로 operation log·D1 handler를 붙이면 같은 body를 서로 다른 entity로 해석하거나, 필요한 ID가 없는 operation을 storage 계층까지 통과시킬 수 있다.

후속 구현 전에 operation별 명세표를 코드의 단일 source로 만들고 다음을 함께 검증해야 한다.

| 항목 | 요구 사항 |
| --- | --- |
| `op` ↔ `entity_type` | 정확히 한 조합만 허용 |
| required target fields | operation별 필수 ID·revision 고정 |
| forbidden target fields | 다른 entity의 ID가 섞이면 거부 |
| create/patch CAS | create와 immutable revision/head advance, mutable patch의 `base_revision` 규칙 분리 |
| scope restrictions | group/worldline은 `PHONE_SPACE` 전용 |

API 초안에도 각 operation의 정확한 target shape가 아직 한 표로 모여 있지 않으므로, 먼저 문서를 보정한 뒤 validator와 table-driven test를 같이 고친다.

### 4. 현재 공식 Cloudflare test stack보다 한 세대 이전 도구를 사용한다

현재 package는 `@cloudflare/vitest-pool-workers` 0.8과 Vitest 3.0.9를 사용한다. Cloudflare는 2026-08-19부터 이 package를 `@cloudflare/vitest-plugin`으로 교체했고, 현재 안내는 Vitest 4.1 이상을 요구한다.[^1][^2]

오래된 pool package가 `workerd` 2025-09-06을 고정해 `compatibility_date`도 2025-09-06으로 낮아졌다. 같은 lockfile의 최신 Wrangler는 `workerd` 2026-08-26을 사용하므로, 이것은 Worker 자체 제약이 아니라 test dependency가 만든 제약이다.

D1 migration과 transaction test를 쌓기 전에 다음을 먼저 수행한다.

- `@cloudflare/vitest-plugin` 1.x로 교체
- Vitest 4.1 이상으로 교체
- `cloudflareTest()` 기반 config로 전환
- plugin type 경로로 `tsconfig` 갱신
- 계획값 `compatibility_date = 2026-08-01` 복원 후 health·contract test 재실행

## ⚠️ 필수 보완 사항

### 5. 암호문 envelope를 Base64로 실제 검증하지 않는다

`parseSet()`은 값이 string인지와 JavaScript `string.length`만 검사한다. 따라서 공백·기호·Unicode가 든 문자열도 “base64 envelope”로 통과한다. 주석의 “byte length equals character count”도 ASCII Base64를 먼저 검증했을 때만 참이다.

다음 규칙을 추가한다.

- 표준 padded Base64 canonical form만 허용
- decode 후 최소 34-byte envelope 구조 확인
- version·algorithm byte와 envelope 총 길이 검증
- 단일 field 제한은 원본 HTTP bytes와 canonical Base64 길이 양쪽에서 검증
- 오류에는 값이나 field path를 넣지 않음

### 6. RFC 3339 검사가 달력·시각 유효성을 확인하지 않는다

현재 정규식은 `2026-99-99T99:99:99Z`도 통과시킨다. canonical timestamp로 저장하기 전 실제 UTC instant로 parse하고, 다시 canonical format으로 직렬화했을 때 계약과 일치하는지 검사해야 한다.

이 항목은 health scaffold를 막지는 않지만 operation log와 idempotency fixture를 만들기 전에 고친다.

## 🧹 저장소 위생

`.gitignore`에 `node_modules/`가 없어 `cloudflare/sync-worker/node_modules/`가 미추적으로 계속 나타난다. 후속 커밋에서 root `.gitignore`에 범용 `node_modules/`를 추가하되, 기존 미커밋 파일은 포함하지 않는다.

## ➡️ 다음 작업 경계

다음 Claude Code 작업은 `cloudflare/sync-worker/`와 Worker API 초안의 operation shape 절만 소유하도록 제한한다.

1. test stack을 공식 plugin·Vitest 4로 올린다
2. operation별 identity shape 표를 문서에 추가한다
3. table-driven validator로 `op`·entity·target·CAS를 결속한다
4. 초기 `delete_turn`을 runtime에서 거부한다
5. 평문 `relationship_policy`를 제거하고 E2EE상 서버 검사 한계를 문서화한다
6. Base64 envelope와 실제 RFC 3339 timestamp를 검증한다
7. 기존 40 tests를 유지하고 위 negative case를 추가한다

Codex는 이 작업과 겹치지 않게 Phase 1 문서 상태·통합 acceptance matrix 및 다음 D1 migration 경계를 정리한다.

## 📚 References

[^1]: Cloudflare. (2026). “Migrate to Vitest plugin.” _Cloudflare Workers Docs_. https://developers.cloudflare.com/workers/testing/vitest-integration/migration-guides/migrate-to-vitest-plugin/

[^2]: Cloudflare. (2026). “Write your first test.” _Cloudflare Workers Docs_. https://developers.cloudflare.com/workers/testing/vitest-integration/write-your-first-test/
