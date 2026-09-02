# 완전 동기화 합성 원격 gate 결과

_2026-09-02 · 상위 계획 Task 15 · 설계 `superpowers/specs/2026-09-01-complete-sync-task11-15-design.md`_

**실제 대화·첨부·복구 문구 접근 0건.** production namespace를 만들지 않았고 기존
production 자원을 수정·삭제하지 않았다. 애초에 이 계정에는 **D1이 합성 것 하나뿐이고
production DB는 존재하지 않는다.**

## 승인

사용자가 **합성 Worker 배포, 원격 D1 migration `0011`·`0012`, 합성 smoke**를 이름으로
지목해 승인했다. 진행 중 발견한 원장 어긋남 때문에 **합성 DB 초기화**를 별도로 승인받았다.

Cloudflare 로그인은 이미 되어 있어(`gksdnf020902@gmail.com`) 추가 로그인이 필요 없었다.

## 자원

| 항목 | 값 |
| --- | --- |
| Worker | `gagaodok-sync-synthetic` |
| URL | `https://gagaodok-sync-synthetic.gagaodok-sync-worker.workers.dev` |
| 배포 버전 | `fe0908d9-e9c1-49c0-acac-bf84c77986ae` |
| D1 | `gagaodok-sync-synthetic` (`db9df584-7d96-4061-842a-b34c1bb6bc49`) |
| R2 | `gagaodok-sync-synthetic-attachments` |
| cron | `17 * * * *` |

로컬 안전장치(`wrangler.jsonc`의 zero UUID·`do-not-create` 버킷·placeholder secret)는
그대로 두었다.

## 진행 중 발견한 것 — 원장이 저장소와 어긋나 있었다

migration을 적용하기 전에 원격 상태를 확인해서 잡았다. **그대로 적용했으면 실패했다.**

| | 원격(발견 당시) | 이 저장소 |
| --- | --- | --- |
| 원장 마지막 | `0011_room_origin.sql` | `0011_room_origin_expand.sql` + `0012_room_origin_enforce.sql` |
| 트리거 | `room_origin_insert_contract`<br>`room_origin_authority_delete_guard`<br>`room_origin_identity_is_immutable` | `room_origin_insert_guard`<br>`room_origin_identity_immutable` |

`0011_room_origin.sql`은 **이 저장소의 어느 브랜치·이력에도 없다.** 커밋 전에 이름이
바뀌고 둘로 쪼개진 것으로 보인다. 트리거는 이름만이 아니라 개수와 내용이 달랐다.

`wrangler d1 migrations apply`는 파일명으로 비교하므로 `0011_room_origin_expand.sql`을
미적용으로 보고 `ALTER TABLE room ADD COLUMN origin_space_id`를 시도했을 것이고, 그
컬럼은 이미 있으므로 실패했을 것이다.

**해결:** 사용자 승인을 받아 합성 DB를 비우고 `0001`~`0012`를 처음부터 적용했다.
데이터는 전부 합성이었다(계정 5·기기 10·방 3·말풍선 41·첨부 1, 모두 8/29 smoke 산물).
이제 원격이 저장소의 migration 파일과 정확히 일치한다.

## 적용 순서와 각 단계 확인

계획대로 **확장 → 배포 → 강제** 순서를 지켰다. 한 스크립트로 뭉뚱그리지 않았다.

| 단계 | 명령 | 확인한 것 |
| --- | --- | --- |
| 초기화 | 내부 테이블(`_cf_KV`·`sqlite_sequence`) 뺀 26개 `DROP TABLE` | 남은 테이블 2개, `d1_migrations` 없음 |
| 0001–0011 | `wrangler d1 migrations apply DB --remote` | 원장 11건, 마지막 `0011_room_origin_expand.sql`, `origin_space_id` 컬럼 있음, **room_origin 트리거 0개** |
| 배포 | `wrangler deploy --config wrangler.synthetic.jsonc` | 버전 `fe0908d9`, cron 등록, `/v1/health` = `{"ok":true,"protocol_version":1}`, 없는 경로는 내용 없는 `NOT_FOUND` |
| 0012 | `wrangler d1 migrations apply DB --remote` | 원장 12건, 트리거가 `room_origin_insert_guard`·`room_origin_identity_immutable` 정확히 둘, 임시 `_room_origin_migration_guard` 테이블 잔여 0 |

## smoke — 52/52 통과

`SYNTHETIC_WORKER_URL`을 배포 URL로 두고 실행했다.

기존 `scripts/remote-smoke.mjs`(44건, enrollment 2건은 건너뜀)에 **새 검사 8건**을 더했다.

**새로 쓴 것 — 이번에 바뀐 것만 겨냥했다:**

| 검사 | 왜 필요한가 |
| --- | --- |
| MAC-origin 방 생성, PHONE-origin 방 생성 | `0011`·`0012`가 강제하는 규칙이다. 강제 migration을 넣고 강제를 확인하지 않을 수 없다 |
| 다른 space를 origin으로 주장하면 거부 | `0012` 트리거의 핵심 |
| 같은 모양의 정직한 요청은 통과 | **위 거부가 origin 때문임을 증명하는 대조 검사.** 처음엔 body 직렬화 버그로 거부돼 엉뚱한 이유로 통과하고 있었다 |
| 두 기기의 change feed가 같은 identity 집합 | Task 9–13이 만든 핵심 동작. 어긋나면 기기마다 다른 대화를 본다 |
| MAC·PHONE 방이 각자 자기 origin을 보고 | projection이 origin을 정확히 실어 보내는지 |

**의도적으로 새로 쓰지 않은 것과 근거:** `0011`·`0012`를 읽어 확인한 결과 둘 다 `room`
테이블만 건드리며 `rate_limit`·`device`를 한 번도 언급하지 않는다.

- 첨부 원격 검사 — Worker·R2 경로를 기존 스크립트가 끝까지 덮는다(create → PUT →
  complete → download, 길이 일치, 바이트 일치, `private, no-store`)
- device 폐기 — 기존 스크립트가 네 endpoint 전부에서 `DEVICE_REVOKED`를 확인한다
- rate limit `429` 능동 시험 — migration이 건드리지 않고, 능동 시험은 합성 환경의
  rate 예산을 소진해 같은 실행의 나머지를 흔든다

## 스크립트에 고친 것

반복 실행이 불가능했던 결함을 고쳤다.

- **`--partial-reset` 모드 추가.** 전체 초기화 뒤에는 시딩이 FK로 막힌다. 폐기된
  태블릿이 account A에 속하는데 그 account를 만드는 것이 enrollment이기 때문이다.
  계정·기기·`enrollment_log`·`rate_limit_bucket`을 남기고 대화만 지우면 `SMOKE_SKIP_ENROLLMENT=1`로
  몇 번이든 다시 돌릴 수 있다.
- **PHONE 기기를 시딩에 추가.** origin matrix와 답장 수렴은 한 계정에 활성 기기가 둘
  있어야 시험되는데, enrollment는 시간당 다섯 번으로 묶여 있어 매번 만들 수 없다.

재현 절차:

```bash
export SYNTHETIC_WORKER_URL="https://gagaodok-sync-synthetic.gagaodok-sync-worker.workers.dev"
node scripts/remote-smoke.mjs --partial-reset > /tmp/partial.sql
npx wrangler d1 execute DB --config wrangler.synthetic.jsonc --remote --file /tmp/partial.sql
SMOKE_SKIP_ENROLLMENT=1 node scripts/remote-smoke.mjs
```

## 유지보수 점검 — 24시간을 기다리지 않았다

`wrangler dev --config wrangler.synthetic.jsonc --remote --test-scheduled`로 띄우고
`/__scheduled`를 직접 호출했다. 응답은 `Ran scheduled event`, 200.

| 검사 | 결과 |
| --- | --- |
| 예약 이벤트가 실제 binding으로 실행되는가 | ✅ |
| 하루 이전 `allocated` + 업로드 없음 → `abandoned` | ✅ `70000000-…-0000000000AA`가 `abandoned`로 전이 |
| `ready` 행이 그대로인가 | ✅ 건드리지 않음 |
| **참조된 R2 객체가 살아 있는가** | ✅ Worker 다운로드 경로로 `200`, **130 bytes**(96 + 34) |

### 확인하지 못한 것 — 고아 R2 객체 삭제

**이 항목은 원격에서 검증하지 못했다.** 실패한 것이 아니라 **잴 수 없었다.**

- 이 wrangler 버전에는 `r2 object list`가 없다
- `r2 bucket info`의 수치가 정체돼 있다 — 5개에 458 B이면 평균 92 B인데 우리가 올린
  객체는 130 B다. 현재 상태를 반영하지 않는다
- R2 객체의 업로드 시각을 과거로 조작할 수 없어, 24시간 유예를 넘긴 고아를 만들 수 없다

고아 삭제 로직 자체는 로컬 `test/maintenance-cleanup.spec.ts`가 덮는다
("deletes only old unreferenced R2 objects and abandons missing allocations" —
참조된 객체는 남기고 고아만 지우는 것을 확인한다). **원격에서 이 경로가 실제로 도는
것은 아직 증명되지 않았다.**

## 로컬 회귀

스크립트를 고친 뒤 로컬 검사를 다시 돌렸다.

- `npm test -- --run` — 45개 파일 **922개 통과**, 실패 0
- `npm run typecheck` — 통과

## 남은 경계

| 항목 | 상태 |
| --- | --- |
| `real-data` | 0건 |
| `remote` | 합성 자원만 |
| `install` | 이번 gate에서 없음 |
| `push` | 없음 |

## 다음 gate

Task 16(실제 방 rollout·앱 설치), Task 17(production 자원 생성), Task 18(최종 서명
릴리스)은 **각각 별도 승인이 필요하다.** 이 문서는 그 승인을 대신하지 않는다.

Task 16 전에 정리할 것:

1. 원격 고아 R2 삭제를 증명할 방법을 정한다(객체 목록 조회 수단 확보, 또는 Worker에
   진단 경로 추가 여부 결정)
2. 첨부 UI 4상태와 `unsupportedReason` 읽기 전용 표시는 실제 원격 방이 있어야
   확인된다. 여전히 미검증이다
