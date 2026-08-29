# Cloudflare 합성 smoke 결과

_2026-08-29 — 격리된 합성 전용 환경에서 수행한 최초 원격 검증_

## 요약

local-only였던 동기화 Worker를 Cloudflare의 **합성 전용** 환경에 처음 연결했다.
D1·R2·Worker를 새로 만들고 migration 0001~0010을 적용한 뒤, 합성 식별자와
의미 없는 고정 바이트만으로 46개 원격 검사를 통과시켰다.

**실제 대화·첨부·복구 문구는 0건이다.** 앱의 기존 대화 저장소는 열지 않았고,
production namespace는 만들지 않았으며, 앱 동기화는 여전히 기본 비활성이다.

## 만든 합성 resource

| 종류 | 논리 이름 | 상태 |
| --- | --- | --- |
| Worker | `gagaodok-sync-synthetic` | 배포됨, `workers.dev` endpoint만 사용 |
| D1 | `gagaodok-sync-synthetic` | migration 0001~0010 적용 |
| R2 | `gagaodok-sync-synthetic-attachments` | private, public access·custom domain 없음 |

이 계정에는 이전에 D1·R2·Worker가 하나도 없었다. 따라서 이름 충돌로 기존
resource를 덮어쓸 위험이 없었고, 기존 resource를 수정하거나 삭제하지 않았다.

secret `CURSOR_MAC_KEY`와 `RATE_LIMIT_MAC_KEY`는 서로 다른 CSPRNG 값으로
생성해 Cloudflare secret binding으로만 주입했다. 값은 터미널·문서·Git·URL에
남기지 않았고 local placeholder를 재사용하지 않았다.

`wrangler.jsonc`는 그대로 두었다. zero UUID, `do-not-create` bucket,
placeholder var는 실수로 `wrangler deploy`가 실제 계정에 닿는 것을 막는
장치이므로 원격 값으로 덮어쓰지 않고 별도 config를 `--config`로 쓴다.
실제 database id가 든 사본은 git에서 제외하고 template만 커밋한다.

## 원격 migration

새로 만든 빈 database에만 적용했다. 실행 전 대상 이름과 미적용 목록을 다시
확인했고, 실행 후 ledger가 정확히 10개인지 확인했다.

- migration ledger: 10
- table: 26, index: 42
- account·device·room·bubble·attachment row: 모두 0

## 통과한 원격 smoke

한 번의 실행에서 **46개 검사 전부 통과**했다. 각 검사는 status code와 불변식으로
판정하며 response body·암호문·token·object key를 출력하지 않는다.

- health, unknown path와 잘못된 method의 content-free 404
- 최초 enrollment와 같은 raw bytes의 replay
- token 없는 요청 거부, enrollment된 token으로 인증 성공
- room create, 같은 raw bytes replay(같은 sequence 반환)
- 현재 revision에 대한 patch 성공
- stale revision CAS 거부와 ledger 불변
- attachment allocate → R2 PUT → complete → download
- download의 `application/octet-stream`·`private, no-store`·길이·**바이트 완전 일치**
- turn create, ready attachment를 참조하는 bubble create
- changes drain이 watermark까지 도달
- bootstrap이 여러 page로 나뉘고 snapshot이 page 사이에서 움직이지 않음
- changes와 bootstrap이 identity별 current projection에서 일치
- revoked device가 write·changes·bootstrap·download 네 경로 모두에서 거부
- 두 번째 account에 첫 번째 account의 row·snapshot·attachment가 보이지 않음
- 모든 response에 token·object key·SQL·stack 없음

## 독립 원격 요청 경합

두 개의 **별도 OS 프로세스**에서 동시에 요청을 보냈다. 이것은 한 event loop
안의 `Promise.all`과 다르지만, Cloudflare가 이 요청들을 서로 다른 isolate로
처리했는지는 이쪽에서 관측할 수 없다. 따라서 **"독립 원격 요청 경합"까지만**
주장하며 다중 isolate 통과라고 표현하지 않는다.

- 같은 revision에 대한 서로 다른 patch: 정확히 하나만 commit, 다른 하나는 `REVISION_CONFLICT`
- 같은 `bubble_order`를 노린 서로 다른 bubble: 정확히 하나만 commit
- 같은 `operation_id`와 같은 raw bytes: 두 번 적용되지 않음
- 같은 `operation_id`와 다른 raw bytes: `OPERATION_REPLAY_MISMATCH`
- 경합 뒤 changes와 bootstrap이 여전히 일치

승자는 sleep으로 고정하지 않고 결과 ledger를 읽어 판정했다. 경합에 쓸
`bubble_order`도 고정값이 아니라 read path에서 읽어 정한다.

## rate limit

원격 secret이 실제로 적용되어 동작한다.

- `pairing_redeem`(5분 10건): 10건 성공, 11·12번째 `429`
- 같은 시점에 `sync_read`는 영향 없이 `200` — scope가 함께 막히지 않는다
- 저장되는 것은 64자 hash 하나뿐이고 원문 주소·token·UUID는 남지 않는다

## scheduled cleanup

cron(`17 * * * *`)이 합성 Worker에만 붙어 있고, 실제 예약 실행을 기다려
전후 상태를 비교했다. 수동 호출이 아니라 Cloudflare가 스스로 돌린 결과다.

| 항목 | 전 | 후 |
| --- | ---: | ---: |
| `allocated` (유예 초과, object 없음) | 1 | 0 |
| `abandoned` | 0 | 1 |
| `ready` | 1 | 1 |
| 만료된 pairing session | 1 | 0 |
| 그 session의 claim | 1 | 0 |
| room / turn / bubble | 1 / 1 / 2 | 1 / 1 / 2 |

- 유예를 넘긴 `allocated` 행 중 object가 없는 것 → `abandoned`로 전이
- `ready` attachment와 그 object → 보존. cleanup 뒤에도 download가 `200`이고
  업로드한 바이트와 완전히 일치한다
- recovery record와 그 object → 보존 (참조되고 있음)
- 24시간 유예 전 object → 보존
- 만료된 pairing claim이 session보다 먼저 삭제되어 FK가 깨지지 않았다
- **대화 성격의 row는 하나도 지워지지 않았다**

**유예를 넘긴 orphan object의 실제 삭제는 원격에서 재현하지 못했다.** R2의
업로드 시각은 뒤로 조작할 수 없고 handler는 실제 시계를 쓰기 때문이다. 이
경로의 근거는 지금도 local test뿐이며, 원격 증거는 24시간이 지난 뒤에만 얻을
수 있다.

## 발견해 고친 결함

`POST /v1/attachments/{id}/complete`가 **정상 요청을 전부 거부**했다.
body가 없는 POST도 실제 연결에서는 `request.body`가 빈 stream으로 도착하는데,
handler는 그것을 "body가 있다"로 읽고 `VALIDATION_FAILED`를 냈다. local test는
직접 만든 Request의 body가 `null`이라 이 차이를 볼 수 없었다.

선언된 `Content-Length`만으로 판정하도록 고쳤다. 길이를 선언한 body는 여전히
거부하며, 어느 경우에도 body를 읽거나 해석하지 않는다. 회귀 test는 실제 wire가
만드는 모양(빈 stream + `Content-Length: 0`)을 직접 구성한다.

이 결함은 원격 연결이 아니었으면 드러나지 않았다. local suite 877개가 전부
통과하는 상태에서도 첨부는 원격에서 절대 `ready`가 될 수 없었다.

## 남아 있는 것과 되돌리는 방법

합성 resource는 **지금도 남아 있다.** 자동으로 지우지 않았다.

필요하면 아래 순서로 제거할 수 있으며, 각 단계는 사용자 승인이 필요하다.

1. `wrangler delete --config wrangler.synthetic.jsonc` — Worker와 cron 제거
2. `wrangler r2 bucket delete gagaodok-sync-synthetic-attachments` — 비운 뒤 삭제
3. `wrangler d1 delete gagaodok-sync-synthetic`

합성 데이터만 비우려면 `node scripts/remote-smoke.mjs --reset`이 내는 SQL을
합성 config로 적용한다. schema는 남고 행만 사라진다.

## 앱 합성 onboarding 화면 (2026-08-29)

원격 endpoint가 확정된 뒤 macOS와 Android 양쪽에 합성 계정 전용 onboarding
화면을 붙였다. 상태 기계는 화면이 아니라 별도 model이 갖는다. 화면 진입은
저장된 상태를 읽고 끝나며, 요청 전송·secret 저장·replica 기록은 모두 버튼
뒤에 있다. 버튼 목록도 화면의 조건문이 아니라 model의 `actions`에서 나오므로
화면이 안전하지 않은 동작을 제시할 수 없다.

화면이 가질 수 있는 상태는 아홉 가지다: 연결 안 됨, 연결 준비 중, 복구 문구
확인 필요, 등록 요청 중, 연결됨·동기화 꺼짐, 합성 스냅샷 받는 중, 합성 자료
준비됨, 재연결 필요, 다시 시도할 수 있는 오류.

고정한 규칙:

- 복구 문구는 한 번만 보여주고 메모리에만 둔다. 파일·설정·로그에 남기지 않는다.
- 사용자가 보관을 확인하기 전에는 등록 요청을 보내지 않는다.
- 서버가 받아들이기 전에는 secret도 연결 정보도 저장하지 않는다.
- 등록이 거부되면 journal의 **같은 bytes로만** 다시 보낸다. "처음부터 다시"는
  제공하지 않는다. 이미 만들어졌을 수 있는 계정에 두 번째 등록을 보내는 것은
  재시도가 아니기 때문이다.
- 연결에 성공해도 동기화는 꺼진 상태다.
- 받은 page는 shadow replica에만 적용한다. 실패한 page는 cursor를 전진시키지
  않고 같은 위치부터 다시 받는다.
- 키와 연결 정보가 어긋나면 재연결 필요로만 표시하고 새 키를 만들지 않는다.
- 연결 해제는 확인 화면까지만이며 이 버전은 아무것도 지우지 않는다.
- 오류 문구는 원인만 말하고 endpoint·token·문구·암호문·서버 메시지를 담지 않는다.
- endpoint는 소스에 없다. 기기에 둔 설정 파일에서 읽고, 없거나 형식이 틀리면
  화면은 아무것도 제안하지 않는다. 화면에는 host만 표시한다.

각 회귀는 sync 상태 파일 옆에 둔 대화 fixture를 매번 다시 읽어 바이트가
같은지 확인한다. "이 화면은 실제 대화를 건드리지 않는다"는 주장을 가정이 아니라
관측으로 남기기 위해서다. macOS 10건, Android 10건이 통과했고 Android는 phone과
tabletMentor 양쪽에서 컴파일·통과했다.

phone과 tablet에 같은 section을 노출한다. canonical 사용자 결정은 **어떤 방이
어느 기기에 보이는가**를 정하지, 기기 등록 자체를 한쪽 전용으로 만들지 않는다.
여기서 한쪽을 가리는 것은 규칙을 따르는 것이 아니라 새로 만드는 일이 된다.
다만 등록하는 space와 platform은 flavor를 따른다.

## 이 gate 뒤에도 자동 승인되지 않는 항목

- 실제 대화·첨부의 inventory·import·shadow upload
- Mac·phone·tablet 앱에서 동기화 기본 활성화
- production namespace 생성
- 기존 local 대화 저장소로의 write-back
- 앱 설치·앱 데이터 삭제

원격 합성 smoke가 통과했다는 것은 **서버 계약이 원격에서 성립한다**는 뜻이지,
앱을 실제 데이터에 연결해도 좋다는 뜻이 아니다. 두 상태는 계속 구분해 기록한다.

## 관련 문서

- [Cloudflare 연결 gate](CLOUDFLARE_CONNECTION_GATE.md)
- [Phase 1 통합 acceptance matrix](PHASE1_INTEGRATION_ACCEPTANCE_MATRIX.md)
- [Phase 2 합성 sync test 계획](PHASE2_SYNTHETIC_SYNC_TEST_PLAN.md)
