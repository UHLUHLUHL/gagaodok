# Gagaodok Phase 1 Sync Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 합성 데이터만으로 canonical schema, E2EE 계약, local Worker/D1/R2 API를 검증해 Mac·Android client 구현을 시작할 수 있는 Phase 1 기반을 만든다.

**Architecture:** 계약 검증과 Worker local implementation을 먼저 완성한 뒤 Mac과 Android adapter를 서로 다른 소유 범위에서 붙인다. 모든 write는 device 인증, operation idempotency, CAS, account-wide sequence를 거쳐 D1에 원자적으로 반영하며 attachment는 R2 상태 기계로 분리한다.

**Tech Stack:** Python 3 표준 라이브러리 contract fixture, TypeScript ES modules, Cloudflare Workers, D1, R2, Wrangler JSONC, Vitest 4.1+, `@cloudflare/vitest-plugin`, Swift/CryptoKit, Kotlin/Android Keystore

**Spec:** `docs/PHASE1_CANONICAL_SCHEMA_DRAFT.md`, `docs/PHASE1_WORKER_API_DRAFT.md`, `docs/2026-08-27-sync-encryption-proposal.md`

## Global Constraints

- 실제 대화·archive를 test fixture로 사용하지 않는다. UUID·본문·첨부는 합성값만 쓴다.
- remote Cloudflare resource 생성·binding·deploy는 별도 사용자 승인 전 금지한다.
- `wrangler dev --remote`, `wrangler d1 ... --remote`, `wrangler deploy`를 실행하지 않는다.
- local 설정에는 D1 zero UUID와 생성되지 않을 전용 R2 이름을 명시하고 `workers_dev: false`, route 없음으로 둔다. binding 항목을 생략해 Wrangler auto-provision 대상이 되게 하지 않는다.
- v1 source attachment/avatar 상한은 `12 * 1024 * 1024 = 12,582,912 bytes`다.
- `space_id`는 `MAC_SPACE`, `PHONE_SPACE`, `TABLET_SPACE`만 허용한다.
- `bubble_order`와 `server_seq`는 `0...2^53-1` 안전 정수 범위다.
- E2EE UUID는 대문자 하이픈 36-byte ASCII, base64는 표준·패딩 포함이다.
- Worker log에 token, 복구 문구, 암호문, nonce, content, 이름, 전체 UUID를 남기지 않는다.
- 초기 Phase 5 전까지 message edit, `delete_bubble`, remote room create는 runtime에서 비활성이다.
- 한 agent가 소유한 파일을 다른 agent가 동시에 수정하지 않는다. 상세 commit이 인수인계 단위다.

---

## 작업 분해와 소유권

| Sub-project | Owner | 결과 | 시작 gate |
| --- | --- | --- | --- |
| A. Canonical Python fixture | Claude Code | schema validator·SQLite 합성 시험 | 현재 진행 |
| B. Worker local foundation | Claude Code, Codex review | local-only Worker·D1·R2 | A 승인 뒤 |
| C. E2EE Swift/Kotlin vectors | Codex integration, 플랫폼별 구현 분배 | 교차 암복호화 | B API type 고정 뒤 |
| D. Mac sync adapter | 별도 Codex task | local outbox·remote replica | C 통과 뒤 |
| E. Android phone/tablet adapter | 별도 Claude task | 공통 store adapter·variant test | C 통과 뒤 |
| F. Synthetic cross-device integration | Codex lead | Mac↔Worker↔Android 합성 왕복 | D·E 통과 뒤 |

이 문서는 Sub-project B를 실행 가능한 수준으로 상세화한다. C~F는 B의 실제 interface와 측정 결과가 확정된 뒤 각각 별도 계획·승인을 받는다. 이 분리는 E2EE·앱 저장소·Worker를 한 커밋에서 함께 바꾸는 것을 막는다.

---

### Task 1: Claude fixture 결과 통합 gate

**Files:**
- Read: `docs/2026-08-27-phase1-schema-claude-review.md`
- Read: `tools/canonical_schema_contract.py`
- Read: `tools/tests/test_canonical_schema_contract.py`
- Modify only if a defect is accepted: `docs/PHASE1_CANONICAL_SCHEMA_DRAFT.md`
- Modify only if encryption classification changes: `docs/2026-08-27-sync-encryption-proposal.md`

**Interfaces:**
- Consumes: Claude commit hash와 contract test 결과
- Produces: Worker 구현에 사용할 확정 enum, identity, bounds, extension grammar

- [ ] **Step 1: Claude commit의 파일 범위를 확인한다**

Run:

```bash
git show --stat --oneline <CLAUDE_COMMIT>
git diff <CLAUDE_COMMIT>^ <CLAUDE_COMMIT> -- \
  tools/canonical_schema_contract.py \
  tools/tests/test_canonical_schema_contract.py \
  docs/2026-08-27-phase1-schema-claude-review.md
```

Expected: 세 소유 파일 외 변경 없음.

- [ ] **Step 2: Python contract test를 실행한다**

Run:

```bash
python3 -m unittest tools.tests.test_canonical_schema_contract
python3 -m unittest tools.tests.test_e2ee_contract_vectors
```

Expected: 두 suite 모두 PASS, 대화 본문·실제 UUID 출력 없음.

- [ ] **Step 3: 차단 defect만 source contract에 통합한다**

허용 기준:

```text
blocking = 같은 합성 input이 플랫폼별로 다른 identity/AAD/storage key를 만들거나,
           CAS/idempotency/암호화 경계를 깨뜨리는 경우
nonblocking = 이름·설명·향후 최적화
```

Expected: 차단 defect가 없으면 source contract를 수정하지 않는다.

- [ ] **Step 4: 통합 결과를 커밋한다**

```bash
git add docs/PHASE1_CANONICAL_SCHEMA_DRAFT.md \
        docs/2026-08-27-sync-encryption-proposal.md
git commit -m "Phase 1 schema fixture 검토 결과를 통합"
```

Expected: 실제 수정이 있을 때만 commit. 빈 commit 금지.

---

### Task 2: Local-only Worker project와 health contract

**Files:**
- Create: `cloudflare/sync-worker/package.json`
- Create: `cloudflare/sync-worker/tsconfig.json`
- Create: `cloudflare/sync-worker/wrangler.jsonc`
- Create: `cloudflare/sync-worker/vitest.config.ts`
- Create: `cloudflare/sync-worker/src/index.ts`
- Create: `cloudflare/sync-worker/src/env.ts`
- Create: `cloudflare/sync-worker/test/health.spec.ts`

**Interfaces:**
- Consumes: Task 1 확정 protocol version `1`
- Produces: `Env`, Worker default `fetch`, `GET /v1/health`

- [ ] **Step 1: 실패하는 health test를 작성한다**

```ts
import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

describe("health", () => {
  it("returns protocol version without storage content", async () => {
    const response = await exports.default.fetch("https://example.test/v1/health");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, protocol_version: 1 });
  });
});
```

- [ ] **Step 2: test가 실패하는지 확인한다**

Run: `cd cloudflare/sync-worker && npm test -- --run test/health.spec.ts`

Expected: Worker entrypoint 또는 route가 없어 FAIL.

- [ ] **Step 3: 최소 Worker와 local bindings를 만든다**

```ts
export interface Env {
  DB: D1Database;
  ATTACHMENTS: R2Bucket;
  CURSOR_MAC_KEY: string;
}

export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/v1/health") {
      return Response.json({ ok: true, protocol_version: 1 });
    }
    return Response.json({ error: { code: "NOT_FOUND", retryable: false } }, { status: 404 });
  },
} satisfies ExportedHandler<Env>;
```

`wrangler.jsonc`는 `compatibility_date`, local D1 binding `DB`, local R2 binding `ATTACHMENTS`를 선언한다. D1 `database_id`는 `00000000-0000-0000-0000-000000000000`, R2 `bucket_name`은 `gagaodok-sync-local-do-not-create`, `workers_dev`는 `false`, route는 없음으로 둔다. 실제 resource id를 넣거나 binding 항목을 생략해 auto-provision 대상이 되게 하지 않는다. `package.json`에는 deploy script를 만들지 않는다.

- [ ] **Step 4: health test와 typecheck를 통과시킨다**

Run:

```bash
npm test -- --run test/health.spec.ts
npm run typecheck
```

Expected: PASS.

- [ ] **Step 5: Worker scaffold만 커밋한다**

```bash
git add cloudflare/sync-worker
git commit -m "Local-only 동기화 Worker 기반을 추가"
```

---

### Task 3: Canonical wire validator

**Files:**
- Create: `cloudflare/sync-worker/src/contracts/identity.ts`
- Create: `cloudflare/sync-worker/src/contracts/operation.ts`
- Create: `cloudflare/sync-worker/src/contracts/error.ts`
- Create: `cloudflare/sync-worker/test/contracts.spec.ts`

**Interfaces:**
- Consumes: `space_id`, nullable worldline, extension grammar, safe integer bounds
- Produces: `parseOperationRequest(value: unknown): OperationRequest`, `ApiError`

- [ ] **Step 1: 잘못된 identity를 거부하는 test를 작성한다**

```ts
it.each([
  { space_id: "tablet" },
  { space_id: "mac_space" },
  { space_id: "UNKNOWN" },
])("rejects non-canonical space: %j", (target) => {
  expect(() => parseOperationRequest(makeOperation({ target }))).toThrowError("VALIDATION_FAILED");
});

it("rejects unsafe bubble order", () => {
  expect(() => parseOperationRequest(makeBubble({ bubble_order: 9_007_199_254_740_992 })))
    .toThrowError("VALIDATION_FAILED");
});
```

- [ ] **Step 2: test가 validator 부재로 실패하는지 확인한다**

Run: `npm test -- --run test/contracts.spec.ts`

Expected: FAIL.

- [ ] **Step 3: 실제 validator를 구현한다**

```ts
export const SPACES = ["MAC_SPACE", "PHONE_SPACE", "TABLET_SPACE"] as const;
export const MAX_SAFE_SYNC_INTEGER = Number.MAX_SAFE_INTEGER;
const EXTENSION_KEY = /^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){2}$/;

export function worldlineKey(worldlineId: string | null): string {
  return worldlineId ?? "";
}
```

validator는 UUID uppercase, operation별 필수 field, `set`/`clear` 중복 path, PHONE_SPACE group restriction, `_enc`가 아닌 canonical wire path를 검사한다. 외부 validation dependency는 추가하지 않는다.

- [ ] **Step 4: positive·negative test를 통과시킨다**

Run: `npm test -- --run test/contracts.spec.ts`

Expected: PASS.

- [ ] **Step 5: validator를 커밋한다**

```bash
git add cloudflare/sync-worker/src/contracts cloudflare/sync-worker/test/contracts.spec.ts
git commit -m "Canonical sync operation 검증기를 추가"
```

---

### Task 4: D1 migration과 natural key 제약

**Files:**
- Create: `cloudflare/sync-worker/migrations/0001_initial.sql`
- Create: `cloudflare/sync-worker/src/storage/schema.ts`
- Create: `cloudflare/sync-worker/test/schema.spec.ts`
- Modify: `cloudflare/sync-worker/vitest.config.ts`

**Interfaces:**
- Consumes: `worldlineKey`, account-aware identities
- Produces: D1 tables, `transaction_guard`, hot-path indexes

- [ ] **Step 1: key·CHECK·unique 실패 test를 작성한다**

```ts
it("rejects mismatched nullable worldline key", async () => {
  await expect(env.DB.prepare(`
    INSERT INTO turn_entity
      (account_id, space_id, room_id, worldline_id, worldline_key, turn_id, revision, server_seq)
    VALUES (?, ?, ?, NULL, ?, ?, 1, 1)
  `).bind(A, "PHONE_SPACE", R, "WRONG", T).run()).rejects.toThrow();
});

it("rejects duplicate scope-wide bubble order", async () => {
  await insertBubble({ turnId: T1, messageId: M1, bubbleOrder: 4 });
  await expect(insertBubble({ turnId: T2, messageId: M2, bubbleOrder: 4 })).rejects.toThrow();
});
```

- [ ] **Step 2: migration 전 test 실패를 확인한다**

Run: `npm test -- --run test/schema.spec.ts`

Expected: table 없음으로 FAIL.

- [ ] **Step 3: migration을 작성한다**

필수 table:

```text
account, device, room, group_state, worldline, turn_entity, bubble,
persona_snapshot, persona_snapshot_head, engine_profile, checkpoint,
extension_field, attachment, operation_log, change_log, transaction_guard
```

필수 constraint:

```sql
CHECK (worldline_key = COALESCE(worldline_id, ''))
UNIQUE (account_id, space_id, room_id, worldline_key, bubble_order)
UNIQUE (account_id, space_id, room_id, worldline_key, message_id)
PRIMARY KEY (account_id, operation_id)
PRIMARY KEY (account_id, server_seq)
```

index는 change pull, operation replay, entity projection에 실제 쓰는 것만 둔다. test에서 `EXPLAIN QUERY PLAN`이 `change_log` full scan이 아닌 index search인지 확인한다.

- [ ] **Step 4: local D1 schema test를 통과시킨다**

Run: `npm test -- --run test/schema.spec.ts`

Expected: null/UUID mapping, tenant duplicate, order duplicate, FK/PK test PASS.

- [ ] **Step 5: migration을 커밋한다**

```bash
git add cloudflare/sync-worker/migrations cloudflare/sync-worker/src/storage cloudflare/sync-worker/test/schema.spec.ts cloudflare/sync-worker/vitest.config.ts
git commit -m "Canonical D1 schema와 key 제약을 추가"
```

---

### Task 5: Device authentication middleware

**Files:**
- Create: `cloudflare/sync-worker/src/auth/device-auth.ts`
- Create: `cloudflare/sync-worker/src/http/router.ts`
- Create: `cloudflare/sync-worker/test/device-auth.spec.ts`
- Modify: `cloudflare/sync-worker/src/index.ts`

**Interfaces:**
- Produces: `authenticateDevice(request, env): Promise<AuthContext>`
- `AuthContext`: `accountId`, `deviceId`, `spaceId`, `keyGeneration`

- [ ] **Step 1: token 부재·폐기·body device 불일치 test를 작성한다**

```ts
it.each([
  [undefined, 401, "AUTH_INVALID"],
  ["Device revoked-token", 403, "DEVICE_REVOKED"],
])("rejects invalid auth", async (authorization, status, code) => {
  const response = await workerRequest("/v1/sync/operations", { authorization });
  expect(response.status).toBe(status);
  expect((await response.json()).error.code).toBe(code);
});
```

- [ ] **Step 2: test 실패를 확인한다**

Run: `npm test -- --run test/device-auth.spec.ts`

- [ ] **Step 3: token hash 조회와 context 결속을 구현한다**

token 원문을 D1에 저장하지 않는다. Worker가 SHA-256 token digest로 device row를 찾고 timing-safe byte 비교가 필요한 verifier에는 별도 helper를 쓴다. request log에는 authorization header를 전달하지 않는다.

- [ ] **Step 4: auth test를 통과시킨다**

Run: `npm test -- --run test/device-auth.spec.ts`

- [ ] **Step 5: auth middleware를 커밋한다**

```bash
git add cloudflare/sync-worker/src/auth cloudflare/sync-worker/src/http cloudflare/sync-worker/src/index.ts cloudflare/sync-worker/test/device-auth.spec.ts
git commit -m "Device token 인증 경계를 추가"
```

---

### Task 6: Atomic operation push와 CAS/idempotency

**Files:**
- Create: `cloudflare/sync-worker/src/storage/apply-operation.ts`
- Create: `cloudflare/sync-worker/src/http/sync-operations.ts`
- Create: `cloudflare/sync-worker/test/sync-operations.spec.ts`
- Modify: `cloudflare/sync-worker/src/http/router.ts`

**Interfaces:**
- Consumes: `OperationRequest`, `AuthContext`
- Produces: `applyOperation(env, auth, operation, requestFingerprint): Promise<ApplyResult>`

- [ ] **Step 1: atomicity·replay test를 작성한다**

```ts
it("does not consume sequence on CAS conflict", async () => {
  const before = await accountSequence();
  const response = await push(makePatch({ base_revision: 999 }));
  expect(response.status).toBe(409);
  expect(await accountSequence()).toBe(before);
  expect(await operationCount()).toBe(0);
  expect(await changeCount()).toBe(0);
});

it("replays identical operation without a new sequence", async () => {
  const first = await push(OP);
  const second = await push(OP);
  expect(second.result.status).toBe("replayed");
  expect(second.result.server_seq).toBe(first.result.server_seq);
});
```

- [ ] **Step 2: test 실패를 확인한다**

Run: `npm test -- --run test/sync-operations.spec.ts`

- [ ] **Step 3: guard·sequence·mutation·logs 한 batch를 구현한다**

```ts
export interface ApplyResult {
  status: "applied" | "replayed";
  operationId: string;
  serverSeq: number;
  revision: number;
}
```

HTTP handler는 body를 최대 `2,000,000 bytes`까지만 읽고, JSON parse·schema 검증 전에 원본 bytes의 SHA-256을 계산한다. 그 fingerprint를 parsed operation과 함께 storage layer에 넘긴다. CAS 불일치는 `transaction_guard CHECK`를 실패시켜 rollback한다. unique race는 기존 operation fingerprint를 다시 읽어 replay/mismatch로 분류한다. client retry는 outbox에 보관한 동일 bytes를 재전송해야 한다.

- [ ] **Step 4: 동시 identical request를 포함해 통과시킨다**

Run: `npm test -- --run test/sync-operations.spec.ts`

Expected: `Promise.all` 동시 push 중 하나만 applied, 나머지는 replayed.

- [ ] **Step 5: push 경로를 커밋한다**

```bash
git add cloudflare/sync-worker/src/storage/apply-operation.ts cloudflare/sync-worker/src/http cloudflare/sync-worker/test/sync-operations.spec.ts
git commit -m "CAS와 idempotency를 갖춘 sync push를 추가"
```

---

### Task 7: Pull과 bootstrap cursor

**Files:**
- Create: `cloudflare/sync-worker/src/http/sync-changes.ts`
- Create: `cloudflare/sync-worker/src/http/sync-bootstrap.ts`
- Create: `cloudflare/sync-worker/src/sync/cursor.ts`
- Create: `cloudflare/sync-worker/test/sync-pull.spec.ts`
- Modify: `cloudflare/sync-worker/src/http/router.ts`

**Interfaces:**
- Produces: `GET /v1/sync/changes`, `GET /v1/sync/bootstrap`
- Cursor: MAC된 account-bound opaque base64url token

- [ ] **Step 1: crash replay·cursor 변조 test를 작성한다**

```ts
it("reapplying a page is idempotent", async () => {
  const page = await pull(0, 2);
  const first = applyReplica(page);
  const second = applyReplica(page, first);
  expect(second).toEqual(first);
});

it("rejects a bootstrap cursor from another account", async () => {
  const cursor = await firstBootstrapCursor(ACCOUNT_A);
  const response = await bootstrapAs(ACCOUNT_B, cursor);
  expect(response.status).toBe(400);
});
```

- [ ] **Step 2: endpoint 부재 실패를 확인한다**

Run: `npm test -- --run test/sync-pull.spec.ts`

- [ ] **Step 3: pull과 cursor를 구현한다**

pull cursor는 `scanned_through_seq`, bootstrap cursor는 `account_id`, `snapshot_high_watermark_seq`, `last_entity_type`, `last_storage_key`를 MAC한다. cursor는 비밀이 아니지만 변조와 account 재사용을 거부한다.

- [ ] **Step 4: bootstrap 중 concurrent write test를 통과시킨다**

Run: `npm test -- --run test/sync-pull.spec.ts`

Expected: bootstrap 완료 후 watermark부터 pull하면 최종 replica가 Worker 최신 projection과 같음.

- [ ] **Step 5: pull 경로를 커밋한다**

```bash
git add cloudflare/sync-worker/src/http/sync-changes.ts cloudflare/sync-worker/src/http/sync-bootstrap.ts cloudflare/sync-worker/src/sync cloudflare/sync-worker/test/sync-pull.spec.ts
git commit -m "Account cursor 기반 pull과 bootstrap을 추가"
```

---

### Task 8: R2 attachment 상태 기계

**Files:**
- Create: `cloudflare/sync-worker/src/attachments/service.ts`
- Create: `cloudflare/sync-worker/src/http/attachments.ts`
- Create: `cloudflare/sync-worker/test/attachments.spec.ts`
- Modify: `cloudflare/sync-worker/src/http/router.ts`

**Interfaces:**
- Produces: allocate, upload, complete, download endpoints
- States: `allocated`, `uploaded`, `ready`, `abandoned`, `tombstoned`, `garbage_collected`

- [ ] **Step 1: size·state·account access test를 작성한다**

```ts
it("rejects oversized ciphertext before reading the body", async () => {
  const response = await upload(ATTACHMENT, {
    contentLength: MAX_ENCRYPTED_OBJECT_BYTES + 1,
  });
  expect(response.status).toBe(413);
  expect(await env.ATTACHMENTS.get(objectKey(ATTACHMENT))).toBeNull();
});

it("does not expose uploaded content before complete", async () => {
  await uploadValidCiphertext();
  expect((await download()).status).toBe(409);
});
```

- [ ] **Step 2: test 실패를 확인한다**

Run: `npm test -- --run test/attachments.spec.ts`

- [ ] **Step 3: streaming R2 put/get과 D1 상태 전이를 구현한다**

```ts
const object = await env.ATTACHMENTS.put(r2Key, request.body, {
  customMetadata: { attachment_id: attachmentId, key_generation: String(keyGeneration) },
});
```

`Content-Length` 필수, public URL 금지, download는 `private, no-store`. complete는 `head()` size를 D1 metadata와 비교한다. R2 payload를 log나 JSON으로 변환하지 않는다.

- [ ] **Step 4: R2/D1 한쪽 실패 test를 통과시킨다**

Run: `npm test -- --run test/attachments.spec.ts`

Expected: orphan은 ready가 되지 않으며 재시도 또는 inventory로 탐지 가능.

- [ ] **Step 5: attachment 경로를 커밋한다**

```bash
git add cloudflare/sync-worker/src/attachments cloudflare/sync-worker/src/http/attachments.ts cloudflare/sync-worker/test/attachments.spec.ts
git commit -m "인증된 R2 attachment 상태 기계를 추가"
```

---

### Task 9: Pairing·recovery Worker contract

**Files:**
- Create: `cloudflare/sync-worker/src/pairing/service.ts`
- Create: `cloudflare/sync-worker/src/http/pairing.ts`
- Create: `cloudflare/sync-worker/src/http/recovery.ts`
- Create: `cloudflare/sync-worker/test/pairing.spec.ts`
- Modify: `cloudflare/sync-worker/src/http/router.ts`

**Interfaces:**
- Consumes: E2EE `claim_redeem_verifier` fixed vector
- Produces: session, claim, approval, redeem, recovery lookup endpoints

- [ ] **Step 1: E2EE negative 9건을 HTTP test로 옮긴다**

필수 사례:

```text
QR bearer claim 조회 거부
다른 account device 조회 거부
승인 전 package 거부
다른 claim package 거부
만료 session 거부
재사용 claim 거부
잘못된 redeem auth 거부
다른 claim verifier 거부
동시 redeem 하나만 성공
```

- [ ] **Step 2: endpoint 부재 실패를 확인한다**

Run: `npm test -- --run test/pairing.spec.ts`

- [ ] **Step 3: verifier를 constant-time 비교하고 원자 소비한다**

Python vector의 literal verifier `9f7c4f2294826ca2618ee42b6bb617dfd1699bb735fcd529c9725007a2bfdc88`을 TypeScript fixture에서 재현한다. 승인과 key package 생성 순서는 분리하지 않는다. redeem 성공 시 claim·package consumed를 같은 D1 batch에서 처리한다.

- [ ] **Step 4: pairing suite와 E2EE Python suite를 모두 통과시킨다**

Run:

```bash
npm test -- --run test/pairing.spec.ts
cd ../.. && python3 -m unittest tools.tests.test_e2ee_contract_vectors
```

- [ ] **Step 5: pairing/recovery를 커밋한다**

```bash
git add cloudflare/sync-worker/src/pairing cloudflare/sync-worker/src/http/pairing.ts cloudflare/sync-worker/src/http/recovery.ts cloudflare/sync-worker/test/pairing.spec.ts
git commit -m "QR pairing과 recovery Worker 계약을 구현"
```

---

### Task 10: Local Phase 1 통합 검증과 handoff

**Files:**
- Create: `cloudflare/sync-worker/test/integration.spec.ts`
- Create: `docs/PHASE1_WORKER_LOCAL_RESULT.md`
- Modify only if measured facts differ: `docs/PHASE1_WORKER_API_DRAFT.md`

**Interfaces:**
- Consumes: Tasks 2~9
- Produces: 앱 client sub-project C~E의 고정 API handoff

- [ ] **Step 1: 합성 account 1개·device 3개 fixture를 작성한다**

```text
MAC_SPACE device 1
PHONE_SPACE device 1
TABLET_SPACE device 1
nullable worldline room과 PHONE_SPACE group/worldline
multi-bubble AI turn
extension unknown key
6.59MB synthetic avatar byte pattern
```

본문은 `SYNTHETIC_SENTINEL_TEXT`, 첨부는 반복 byte로 만들고 실제 archive를 읽지 않는다.

- [ ] **Step 2: end-to-end test를 작성하고 실행한다**

Run:

```bash
npm test -- --run
npm run typecheck
npx wrangler deploy --dry-run --outdir /tmp/gagaodok-sync-worker-dry-run
```

Expected: remote deploy 없음. Worker bundle size·startup 정보만 기록.

- [ ] **Step 3: privacy scanner를 실행한다**

test log를 임시 파일에 저장하고 다음 literal이 없는지 검사한다.

```text
SYNTHETIC_SENTINEL_TEXT
BASE64_ENVELOPE
Authorization
claim_redeem_auth
```

Expected: 0건. UUID 전체 출력도 금지한다.

- [ ] **Step 4: 결과 문서를 작성한다**

반드시 기록:

- 실행한 test와 pass count
- D1 rows read/written과 `EXPLAIN QUERY PLAN`
- Worker CPU·memory는 local에서 확인 가능한 값과 remote 미측정 구분
- 6.59MB avatar stream peak memory 측정 여부
- API 변경점과 남은 blocker
- remote resource 0개, 실제 데이터 0건

- [ ] **Step 5: 통합 결과를 커밋한다**

```bash
git add cloudflare/sync-worker/test/integration.spec.ts docs/PHASE1_WORKER_LOCAL_RESULT.md docs/PHASE1_WORKER_API_DRAFT.md
git commit -m "Phase 1 Worker local 합성 통합을 검증"
```

---

## Worker 완료 후 플랫폼 작업 순서

1. **Sub-project C:** Python fixed vector를 Swift/CryptoKit과 Kotlin/JCA에 이식하고 양방향 교차 복호화를 통과시킨다.
2. **Sub-project D:** Mac에 raw read importer, durable outbox, remote replica store를 추가한다. 기존 JSON은 projection target이며 source file을 inventory/import 중 쓰지 않는다.
3. **Sub-project E:** Android 공통 module에 같은 adapter를 넣고 phone/tablet variant를 각각 합성 fixture로 검증한다. 실제 기기 설치는 별도 사용자 승인 뒤다.
4. **Sub-project F:** Mac 생성 → Worker → phone/tablet 복호화와 역방향을 합성 방 하나로 검증한다.
5. Phase 2 결과와 rollback 증거가 모두 통과한 뒤에만 Phase 3 실데이터 shadow upload 승인을 다시 요청한다.

## Plan self-review 결과

- Schema §1~15의 각 결정은 Tasks 3~8 중 하나에 acceptance가 있다.
- E2EE key derivation 자체는 Worker가 하지 않으며 Task 9는 verifier와 접근 통제만 담당한다.
- D1/R2 remote 생성 명령은 없다. dry-run만 Task 10에 있다.
- Mac·Android는 Worker interface가 측정되기 전 구현하지 않도록 별도 sub-project로 분리했다.
- `TBD`, `TODO`, “적절히 처리” 같은 placeholder를 사용하지 않았다.

## 현재 도구chain 근거

- [Workers Vitest integration](https://developers.cloudflare.com/workers/testing/vitest-integration/write-your-first-test/)
- [D1 local development와 `--remote` 주의](https://developers.cloudflare.com/d1/best-practices/local-development/)
- [Wrangler JSONC configuration](https://developers.cloudflare.com/workers/wrangler/configuration/)
