# Cloudflare 연결 gate

_2026-08-29 — 실제 데이터 없이 local 구현을 원격 합성 환경으로 옮길 때의 승인 경계_

## 현재 판정

Worker·D1·R2, enrollment·recovery·pairing, operation·changes·bootstrap,
rate limit·scheduled cleanup과 양 플랫폼 crypto·key custody·outbox·client·shadow
replica가 local 합성 시험을 통과했다. 아직 Cloudflare 로그인, 원격 resource 생성,
deploy, remote migration, 실제 대화 업로드는 한 번도 수행하지 않았다.

## 사용자 승인이 있어야 실행할 항목

1. Cloudflare 계정에 로그인한다.
2. production이 아닌 합성 전용 D1 database와 private R2 bucket을 만든다.
3. local placeholder와 다른 무작위 `CURSOR_MAC_KEY`, `RATE_LIMIT_MAC_KEY` secret을 주입한다.
4. 별도 production 설정으로 migration 0001~0010을 적용하고 Worker를 배포한다.
5. 합성 account·device·room·attachment만으로 원격 smoke test를 실행한다.

기존 `wrangler.jsonc`의 zero UUID, `do-not-create` bucket, placeholder secret은 local
안전장치이므로 원격 값으로 덮어쓰지 않는다. 원격 설정은 별도 파일·환경으로 둔다.

## 첫 원격 smoke gate

- health와 content-free error
- 최초 enrollment replay, revoked device 거부
- 한 room의 operation CAS·idempotent replay
- R2 upload→complete→download checksum
- changes와 bootstrap projection 일치
- rate limit과 scheduled cleanup의 count-only 결과
- 두 isolate에서 같은 revision·bubble order를 경합시켜 한 요청만 commit되는지 확인
- response와 log에 token·ciphertext·object key·SQL·stack이 없는지 확인

실패하면 원격 합성 namespace를 폐기할 수 있지만 production namespace나 실제 앱
데이터에는 손대지 않는다.

## 이 gate 뒤에도 자동 승인되지 않는 항목

- 실제 대화·첨부의 inventory/import/shadow upload
- Mac·phone·tablet 앱에서 동기화 기본 활성화
- 앱 설치·데이터 삭제
- production namespace 생성 또는 기존 로컬 대화 write-back

원격 합성 smoke가 통과한 뒤 앱에는 합성 계정용 onboarding 화면과 명시적 활성화
단계를 붙인다. 실제 데이터 shadow upload는 별도의 사용자 승인으로만 열린다.
