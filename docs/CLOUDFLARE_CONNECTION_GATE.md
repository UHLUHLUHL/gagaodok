# Cloudflare 연결 gate

_2026-08-29 — 실제 데이터 없이 local 구현을 원격 합성 환경으로 옮길 때의 승인 경계_

## 현재 판정

**이 gate는 2026-08-29에 통과했다.** 합성 전용 D1·private R2·Worker를 만들고,
서로 다른 CSPRNG secret 두 개를 주입하고, migration 0001~0010을 적용한 뒤
합성 데이터만으로 원격 smoke 46개 검사를 전부 통과시켰다. 결과와 남은 한계는
[Cloudflare 합성 smoke 결과](CLOUDFLARE_SYNTHETIC_SMOKE_RESULT.md)에 있다.

실제 대화·첨부·복구 문구는 여전히 0건이다. production namespace는 만들지 않았고,
기존 Cloudflare resource는 수정·삭제하지 않았으며, 앱 동기화는 기본 비활성이다.

이 연결로 **local에서는 보이지 않던 결함 하나가 드러났다.** `complete` route가
실제 연결에서 오는 body 없는 POST를 거부해 첨부가 원격에서 `ready`가 될 수
없었다. local suite 877개가 모두 통과하는 상태였는데도 그랬다. 원격 연결이
가치를 만든 지점이며, 앞으로도 local 통과를 원격 근거로 대신하지 않는다.

## 이 gate에서 실행한 항목

1. Cloudflare 계정에 로그인했다. 비밀번호·2FA는 사용자가 직접 입력했다.
2. production이 아닌 합성 전용 D1과 private R2 bucket을 만들었다.
3. local placeholder와 다른 무작위 `CURSOR_MAC_KEY`, `RATE_LIMIT_MAC_KEY`를 주입했다.
4. 별도 config로 migration 0001~0010을 적용하고 Worker를 배포했다.
5. 합성 account·device·room·attachment만으로 원격 smoke test를 실행했다.

기존 `wrangler.jsonc`의 zero UUID, `do-not-create` bucket, placeholder secret은 local
안전장치이므로 원격 값으로 덮어쓰지 않는다. 원격 설정은 별도 파일·환경으로 둔다.

## 첫 원격 smoke gate — 결과

| 항목 | 결과 |
| --- | --- |
| health와 content-free error | ✅ |
| 최초 enrollment replay, revoked device 거부 | ✅ |
| 한 room의 operation CAS·idempotent replay | ✅ |
| R2 upload→complete→download checksum | ✅ 바이트 완전 일치 |
| changes와 bootstrap projection 일치 | ✅ identity별 비교 |
| rate limit | ✅ 경계 직전 통과, 초과 `429`, 다른 scope 무영향 |
| scheduled cleanup | ⚠️ 부분 — 아래 참조 |
| 같은 revision·bubble order 경합에서 한 요청만 commit | ✅ 단, **독립 원격 요청** 경합까지만 |
| response·log에 token·ciphertext·object key·SQL·stack 없음 | ✅ |

경합 검증은 별도 OS 프로세스 두 개에서 보냈다. Cloudflare가 이를 서로 다른
isolate로 처리했는지는 이쪽에서 관측할 수 없으므로 **다중 isolate 통과라고
표현하지 않는다.**

cleanup은 보존 규칙(`ready`·참조된 object·유예 전 object)과 `allocated→abandoned`
전이, 만료된 pairing child-first 삭제까지 원격에서 확인했다. **유예를 넘긴
orphan object의 실제 삭제만 원격 근거가 없다** — R2 업로드 시각을 뒤로 조작할 수
없기 때문이며, 이 경로의 근거는 여전히 local test다.

실패하면 원격 합성 namespace를 폐기할 수 있지만 production namespace나 실제 앱
데이터에는 손대지 않는다. 합성 resource는 자동으로 지우지 않으며 제거 절차는
결과 문서에 적어 둔다.

## 이 gate 뒤에도 자동 승인되지 않는 항목

- 실제 대화·첨부의 inventory/import/shadow upload
- Mac·phone·tablet 앱에서 동기화 기본 활성화
- 앱 설치·데이터 삭제
- production namespace 생성 또는 기존 로컬 대화 write-back

원격 합성 smoke가 통과한 뒤 앱에는 합성 계정용 onboarding 화면과 명시적 활성화
단계를 붙인다. 실제 데이터 shadow upload는 별도의 사용자 승인으로만 열린다.
