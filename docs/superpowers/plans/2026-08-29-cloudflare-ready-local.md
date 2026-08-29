# Cloudflare 연결 직전 local 완성 계획

**목표:** 원격 Cloudflare resource를 만들기 전에, 최초 계정 설정부터 기기 연결,
복구, durable outbox, 동기화 UI, 운영 안전 경계까지 합성 local 환경에서 끝낸다.

**안전 경계:** 실제 대화·실제 복구 문구·실제 token을 사용하지 않는다. deploy,
remote migration, Cloudflare 로그인·resource 생성, 앱 설치·데이터 삭제, push는 하지
않는다.

## Gate 1 — Pairing·recovery crypto

- [x] 공용 artifact에 recovery HKDF/verifier와 pairing claim/delivery/SAS vector 추가
- [x] account-wide recovery envelope용 AAD를 room scope와 분리해 canonical 문서에 고정
- [ ] Swift·Kotlin이 같은 recovery·pairing vector를 생성·검증
- [ ] secret·package·ciphertext가 test output과 error에 노출되지 않는 회귀

## Gate 2 — 최초 계정·pairing·recovery Worker

- [ ] 최초 기기 등록 endpoint의 exact wire·rate-limit·idempotency 계약 고정
- [ ] recovery record, pairing session, pairing claim의 D1 schema와 TTL/consumed 제약
- [ ] 기존 device session 생성 → bearer claim 제출 → device 조회/승인 → 1회 redeem
- [ ] recovery lookup/auth constant-time 검증과 새 device token 발급
- [ ] 다른 account·claim·session, 승인 전, 만료, revoke, 동시 redeem negative suite

## Gate 3 — Client key custody와 onboarding

- [ ] macOS Keychain wrapping key와 Android Keystore wrapping key로 master key 보관
- [ ] backup restore 뒤 wrapping key 부재를 조용한 재생성이 아닌 recovery-required로 처리
- [ ] 최초 설정 recovery phrase 생성·재입력 확인 전 remote upload 금지
- [ ] QR은 앱 전용 payload이며 URL·clipboard·log에 secret을 넣지 않음

## Gate 4 — Durable sync clients

- [ ] local content와 outbox operation을 복구 가능한 순서로 durable하게 기록
- [ ] operation replay, bubble_order conflict 재암호화, CAS conflict reconciliation
- [ ] changes cursor, bootstrap watermark, attachment upload/complete/download client
- [ ] Mac·phone·tablet에서 unsupported space를 숨기고 opaque field를 보존

## Gate 5 — 운영 전 local 안전성

- [ ] endpoint별 bounded local rate limit과 content-free 429
- [ ] allocated attachment TTL·R2 orphan inventory와 안전한 cleanup dry run
- [ ] 다중 Worker isolate에 해당하는 D1 경합 probe 또는 명시적 한계 판정
- [ ] 12 MiB attachment memory 측정과 단일 AES-GCM 유지 여부 판정
- [ ] 전체 합성 onboarding→pairing→write→pull→recovery E2E

## 종료 조건

모든 gate가 local 합성 자료로 통과하고 canonical matrix가 갱신되면 작업을 멈춘다.
그 다음 단계는 사용자의 별도 승인 아래 Cloudflare 로그인, D1/R2 생성, secrets 설정,
remote migration, synthetic smoke test 순서다. 실제 데이터 shadow upload는 그 뒤에도
별도 승인을 요구한다.
