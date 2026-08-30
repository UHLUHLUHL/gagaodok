# Mac host → Android join pairing UI 설계

## 목표

이미 합성 계정에 연결된 Mac 가가오독이 합류 QR을 표시하고, 아직 연결되지 않은
Android phone 또는 tabletMentor 가가오독이 앱 내부 카메라로 이를 스캔하여 같은
암호화 계정에 합류할 수 있게 한다. 합류가 끝나도 `enabled = false`를 유지하며 실제
대화는 읽거나 전송하지 않는다.

## 이번 범위

- macOS는 host 역할만 제공한다. 기존 연결의 account ID·device token으로 5분짜리
  pairing session을 만들고 QR과 안전 경고, claim 대기, 6자리 SAS 확인, 승인 결과를
  설정의 동기화 화면에 표시한다.
- Android phone과 tabletMentor는 joiner 역할만 제공한다. 사용자가 “기존 계정에
  합류”를 누른 뒤에만 카메라 권한을 요청하고, 앱 내부 scanner가 QR payload text를
  전달한다. submit·SAS 확인·redeem이 끝나면 스캔된 account ID와 새 기기 전용
  secret을 저장하되 sync는 켜지 않는다.
- macOS QR은 Core Image의 `CIQRCodeGenerator`로 그린다. QR 원문은 URL, clipboard,
  파일, log에 쓰지 않고 화면 이미지 생성 과정에서만 메모리에 둔다.
- Android scanner는 CameraX preview/analyzer와 ML Kit barcode scanning을 사용한다.
  QR 값은 첫 canonical payload 하나만 소비하고 즉시 분석을 멈춘다. 화면·예외·log에
  raw payload를 표시하지 않는다.
- 기존 `SyncPairingHostCoordinator`, `SyncPairingJoinerCoordinator`, canonical payload,
  SAS 및 one-time redeem 계약을 재사용한다. 화면은 coordinator 규칙을 다시
  구현하지 않고 전용 UI model이 내놓는 state/action만 소비한다.

## 상태와 동작

### Mac host

`idle → openingSession → showingQR/waitingClaim → verifySAS → approving → completed`
이며 만료와 재시도 가능한 오류를 별도 상태로 둔다. QR을 연 뒤 claim poll은 한 번에
하나만 수행하고 화면이 사라지면 중단한다. SAS 일치 확인 버튼은 `verifySAS`에서만
보이며 사용자 확인 전에는 approve를 호출할 수 없다.

### Android joiner

`idle → requestingCamera → scanning → qrAccepted → submitting → verifySAS →
waitingApproval → redeeming → linkedSyncOff` 순서다. 카메라 거부·잘못된 QR·만료·통신
실패는 secret이나 connection을 만들지 않고 다시 스캔 가능한 오류로 돌아간다.
SAS 확인 전 redeem을 호출할 수 없고, 성공 후 scanner 화면은 닫힌다.

## 데이터와 안전 경계

- host는 저장된 합성 연결이 `enabled = false`인 경우에만 이 시험 UI를 제공한다.
- joiner는 secret과 connection이 모두 없는 상태에서만 시작한다. 기존 연결 또는
  relink-required 상태를 덮어쓰지 않는다.
- QR에는 contract의 endpoint origin, account ID, session ID, pairing secret만 있다.
- QR·token·master key·claim secret·recovery entropy·ciphertext를 log나 사용자 오류
  메시지에 넣지 않는다.
- pairing 성공은 shadow connection만 만든다. local conversation, outbox, replica,
  Cloudflare resource 설정은 변경하지 않는다.
- 이번 구현 검증은 합성 fixture와 local transport double만 사용한다. APK 설치,
  앱 데이터 삭제, 원격 pairing, 실제 대화 접근, sync 활성화, push는 하지 않는다.

## 구성 요소

- `SyncPairingHostUIModel` / Android `SyncPairingJoinerUiModel`: coordinator 호출,
  state transition, 중복 tap 방지, content-free 오류를 소유한다.
- macOS QR view: payload text를 받아 메모리에서 QR 이미지만 만든다. 실패하면 raw
  text 없이 “QR을 만들지 못했습니다” 상태를 반환한다.
- Android scanner screen: permission과 CameraX lifecycle을 소유하고 첫 QR 문자열만
  model로 넘긴다. pairing protocol 해석은 `SyncPairingPayload`만 담당한다.
- 기존 synthetic settings host가 실제 store/client/coordinator를 조립한다. View는
  state와 action을 표시할 뿐 network·storage를 직접 호출하지 않는다.

## 검증

- Swift model test: 연결되지 않은 host 거부, QR 생성 전 network 없음, session 이후
  QR state, SAS 전 승인 불가, 만료·오류 재시작, 완료 후 sync 비활성.
- Android model test: 사용자 tap 전 권한·network 없음, camera 거부, malformed QR,
  submit 전 저장 없음, SAS 전 redeem 불가, vault/config 실패 시 연결 완료 표시 금지,
  성공 후 같은 account·sync 비활성.
- QR renderer는 canonical fixture를 실제 image로 만들고 빈 payload를 거부한다.
- scanner adapter는 analyzer가 첫 QR만 전달하고 payload·secret을 log하지 않는 동작을
  단위 경계에서 검증한다. 카메라 프레임 해독 자체는 ML Kit의 책임으로 둔다.
- affected Swift tests와 `swift build`, Android phone/tabletMentor unit test 및 debug
  compile을 실행한다. 실기기 UX는 별도 설치 승인 뒤 gate로 남긴다.

## 이번 범위 밖

- Android가 QR을 표시하거나 Mac이 웹캠으로 스캔하는 역방향
- 복구 entropy의 실제 escrow 저장소·소유자 인증·만료 청소
- 실제 대화 mutation adapter와 sync 활성화
- APK·Mac 앱 설치 및 원격 합성 pairing 실행
