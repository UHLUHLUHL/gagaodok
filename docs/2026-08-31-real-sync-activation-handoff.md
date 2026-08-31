# 실제 동기화 활성화 인수인계

## 현재 완료 상태

- 합성 Cloudflare Worker/D1/R2는 배포돼 있으며 Worker version은
  `aa4a0ed8-9caa-4e6d-af42-22d7c9406cbd`이다. 원격 migration은 실행하지 않았다.
- macOS release 앱과 Android phone/tabletMentor release APK를 같은 서명으로
  데이터 보존 업데이트했다. uninstall, clear, downgrade는 하지 않았다.
- 세 앱은 같은 합성 account에 합류했고 `GET /v1/account/devices` 실기기 화면에서
  서로의 활성 등록을 확인했다. 실제 대화 동기화는 아직 `enabled=false`이다.
- 현재 커밋은 연결된 기기 목록 API와 세 플랫폼 UI만 포함한다. 사용자 대화 본문,
  암호문, token, 복구 문구를 읽거나 커밋하지 않았다.

## 검증 증거

- Worker: 38 files / 882 tests, typecheck 통과.
- Swift: sync/E2EE coordinator script 전체 통과, release build 통과.
- Android: phone/tabletMentor client·device-list 단위 test와 두 debug compile 통과,
  두 release APK 빌드 및 같은 signer의 기존 앱에 `install -r` 성공.
- 원격 read-only device-list 요청은 HTTP 200, active device 1건을 반환했다.
- phone/tablet 실기기에서 동일 account의 활성 기기 5건과 각 current marker를 확인했다.
  5건 중 일부는 이전 합성 시험의 중복 등록이며 실제 데이터는 아니다.

## 다음 필수 게이트

현재 합성 account의 최초 복구 문구를 아무도 기록하지 않았고 entropy도 저장하지
않았으므로 기존 문구는 재표시할 수 없다. 실제 대화 shadow upload 전에 인증된
복구 회전을 구현해야 한다. 기존 account master key는 바꾸지 않고 새 16-byte
entropy로 lookup/auth/verifier/wrap key를 만들고 동일 master key를 새 recovery
version으로 감싼다. 서버에는 master key와 평문 문구를 보내지 않는다.

권장 API는 인증된 `POST /v1/recovery/rotate`이다. active device token으로 인증하고,
요청의 다음 recovery version과 lookup, auth verifier, wrapped master key만 받아 기존
active recovery row를 revoke한 뒤 새 row를 원자적으로 active로 만든다. R2 object는
create-only로 저장한다. 동시 요청은 한 건만 이기고, 동일 payload 재전송은 replay,
stale 또는 다른 payload는 `RECOVERY_CONFLICT`여야 한다. 응답·로그에는 lookup,
wrapped key, object key, token, phrase가 없어야 한다. D1 실패 뒤 생긴 R2 object는
Phase 1 orphan 정책을 따른다.

필수 시험은 success/replay/stale conflict/revoked token/동시 single winner/D1 rollback/
비밀 비노출이다. 구현 뒤 macOS에서 새 문구를 한 번 표시하고 사용자가 직접 기록한
뒤 재입력하여 복구가 실제로 되는지 확인한다. 이 사용자 확인 전에는 실제 대화에
접근하거나 sync를 켜지 않는다.

복구 gate 통과 뒤 canonical Phase 3대로 local conversation -> encrypted shadow outbox
-> D1/R2 단방향 복사를 먼저 연다. 원본에는 write-back하지 않고 import_batch_id,
local count/hash와 remote projection을 합성·최소 metadata로 대조한다. 그 다음 지정한
시험방 한 곳만 양방향으로 열고, 성공 후에만 범위를 넓힌다. phone-only room 노출,
device-separated Gemini cache/호감도, 초기 edit/delete 금지 정책은 유지한다.

## 금지와 작업 경계

- push/merge, 앱 데이터 삭제, 실제 데이터의 로그 출력, raw ciphertext/token/phrase 출력,
  destructive migration 금지.
- 현재 dirty/untracked 9건은 사용자 작업이므로 수정·stage·삭제하지 않는다.
- 이미 배포된 합성 자원만 사용하며 production resource를 만들지 않는다.
- 실제 대화 접근과 sync 활성화는 복구 문구 기록·재입력 gate 이후에만 수행한다.
