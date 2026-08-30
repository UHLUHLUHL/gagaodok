# 동기화 계정 전환·연결 해제 설계

## 목적

이미 동기화 계정에 연결된 macOS·Android 앱이 로컬 대화와 일반 앱 설정을
보존하면서 다음 세 동작을 명확히 구분하도록 한다.

1. 동기화만 끄고 같은 계정 연결을 유지한다.
2. 이 기기의 동기화 연결을 해제하고 독립적인 로컬 앱으로 돌아간다.
3. 기존 연결을 안전하게 보존한 채 다른 동기화 계정에 합류한다.

새 독립 동기화 계정 시작은 연결 해제 뒤의 별도 흐름이다. 이 설계는 실제 대화
업로드나 동기화 활성화를 승인하지 않는다.

## 불변 조건

- 로컬 대화·첨부·앱 설정·Gemini 문맥과 캐시는 읽거나 이동하거나 삭제하지 않는다.
- 계정 전환이 실패하거나 취소되면 기존 동기화 연결이 그대로 동작해야 한다.
- 새 계정의 인증과 shadow bootstrap이 성공하기 전에는 활성 자격 증명을 교체하지
  않는다.
- 계정 전환·연결 해제 뒤에도 동기화는 자동으로 켜지지 않는다.
- 미전송 outbox가 있으면 연결 해제와 계정 전환을 거부한다.
- 비밀키·device token·복구 문구를 로그, 오류, UI 진단 정보 또는 일반 파일에
  노출하지 않는다.
- 한 기기에서 두 동기화 계정의 비밀키를 장기간 보관하지 않는다.

## 사용자 동작

### 동기화 끄기

활성 계정·비밀키·connection·shadow replica·cursor·outbox를 유지하고 네트워크
송수신만 중단한다. 다시 켜면 같은 계정에서 이어갈 수 있다.

### 이 기기 연결 해제

확인 화면에서 다음 사실을 명시한다.

- 이 기기의 서버 송수신이 중단된다.
- 로컬 대화와 일반 앱 자료는 유지된다.
- 이 기기의 동기화 키, connection, shadow replica, cursor와 비어 있는 outbox는
  제거된다.
- 원격 계정과 다른 기기의 자료는 삭제하지 않는다.
- 이후 기존 계정에 다시 합류하거나 새 독립 계정을 시작할 수 있다.

outbox가 비어 있지 않으면 해제 버튼을 실행하지 않고 미전송 변경이 남아 있음을
알린다. v1은 이를 버리는 선택지를 제공하지 않는다.

### 다른 계정에 합류

이미 연결된 앱에서는 QR 스캔 뒤 즉시 기존 저장소를 덮어쓰지 않는다. 새 pairing
결과는 전환 전용 임시 저장소에 둔다. SAS 확인, host 승인, 1회 redeem, 새 계정의
인증, 빈 shadow bootstrap 완료를 모두 통과해야 commit할 수 있다.

commit 시 새 secret·connection·replica·cursor를 하나의 전환 단위로 활성화하고
`enabled=false`로 고정한다. 성공한 뒤 기존 동기화 비밀키와 기존 shadow 상태를
제거한다. 로컬 대화 저장소는 이 단위에 포함하지 않는다.

취소·네트워크 실패·인증 실패·bootstrap 실패·저장 실패에서는 임시 자료만
폐기하고 기존 활성 계정으로 돌아간다. 부분 교체 상태는 허용하지 않는다.

### 새 독립 계정 시작

연결이 없는 상태에서만 제공한다. 계정 생성과 키 보관까지 완료해도 동기화는
꺼진 상태다. 로컬 대화를 새 계정에 올리는 동작은 별도 화면과 별도 사용자 승인
없이는 실행하지 않는다.

## 저장 구조와 전환 저널

정상 상태의 플랫폼별 보안 저장소에는 활성 secret 한 세트만 둔다. 전환 중 새
secret은 별도 staging slot에 보관하고 일반 파일에는 쓰지 않는다. commit 직전
기존 active secret은 rollback slot에 복제한다. rollback slot은 서로 다른 보안
저장소와 파일시스템 사이의 crash 복구에만 사용하며 성공·취소·복구 직후 반드시
제거한다. 따라서 여러 계정의 비밀키를 정상 상태에서 장기 보관하지 않는다.

일반 sync 디렉터리에는 비밀이 없는 전환 저널을 둔다. 저널은 단계, 기존·신규
account ID, staging 파일 이름과 생성 시각만 기록하며 token이나 key material을
포함하지 않는다. replica·cursor는 활성 파일과 staging 파일을 분리한다.

commit 순서는 다음과 같다.

1. staging secret·connection·replica·cursor의 완전성을 다시 검사한다.
2. active secret을 rollback 보안 slot에 복제하고 다시 읽어 일치 여부를 검사한다.
3. 저널을 `committing`으로 원자 기록한다.
4. 활성 비밀과 활성 sync 파일을 staging 세트로 교체한다.
5. 새 connection의 `enabled=false`를 다시 확인한다.
6. rollback secret·기존 shadow 세트와 저널을 제거한다.

재실행 시 저널이 있으면 활성 connection과 secret의 account 일치를 검사한다.
commit 전 단계는 staging을 폐기하고 기존 계정을 유지한다. commit 중 단계에서
새 세트가 완전하면 commit을 마치고, 그렇지 않으면 rollback slot과 기존 파일
세트로 복원한다. 어느 쪽도 완전하지 않으면 네트워크를 차단하고 복구 필요 상태를
표시한다. 복구가 끝나면 staging·rollback slot과 저널이 남아 있지 않아야 한다.

## 구성 요소 경계

- `SyncAccountTransitionCoordinator`: 사전 조건, staging, bootstrap, commit, 재실행
  복구를 소유한다.
- secret vault: active/staging/일시적 rollback slot의 검증·승격·복원·폐기를
  제공한다.
- connection/replica/pull/outbox store: 계정 전환용 snapshot·검증·교체 API를
  제공하되 로컬 대화 저장소를 참조하지 않는다.
- onboarding·pairing UI model: coordinator가 허용한 action만 노출한다.
- 화면: 설명과 확인만 소유하며 저장소를 직접 수정하지 않는다.

Swift와 Kotlin은 같은 상태와 실패 의미를 사용한다. 플랫폼별 파일 API나 보안
저장소 구현은 달라도 wire 계약과 사용자 결과는 같아야 한다.

## 상태와 오류

필수 상태는 `idle`, `preparing`, `awaitingSAS`, `awaitingHost`, `redeeming`,
`verifying`, `bootstrapping`, `readyToCommit`, `committing`, `completed`,
`cancelled`, `recoverableError`, `manualRecoveryRequired`다.

사용자 오류에는 비밀이나 account 전체 식별자를 넣지 않는다. 미전송 outbox,
기존 sync 활성, QR 만료, host 거부, 인증 실패, bootstrap 실패, 로컬 저장 실패를
서로 구분한다. 네트워크 재시도는 같은 pairing·staging bytes를 재사용하며 새
enrollment를 조용히 만들지 않는다.

## UI

연결된 상태에서는 다음 동작을 분리해 표시한다.

- `동기화 끄기` 또는 `동기화 켜기`
- `다른 계정에 이 기기 합류`
- `이 기기 연결 해제`

계정 전환 확인 화면은 로컬 대화가 유지되고, 기존 동기화 연결은 성공 전까지
유지되며, 완료 뒤에도 동기화가 꺼져 있음을 보여준다. 연결 해제 확인 화면은
원격 계정이나 다른 기기를 삭제하지 않는다고 명시한다.

Android의 카메라 권한은 사용자가 QR 스캔을 누른 뒤에만 요청한다. macOS host
QR은 기존과 같이 메모리에서만 렌더링한다.

## 검증

양 플랫폼에서 다음 회귀를 같은 의미로 고정한다.

- 기존 secret·connection·replica·cursor·outbox와 로컬 대화 fixture의 전후 비교
- outbox가 남거나 sync가 켜진 상태의 전환·해제 거부
- SAS 거부, host 거부, redeem 실패, bootstrap 실패, 각 저장 단계 실패에서 기존
  활성 계정 불변
- 성공 commit 뒤 새 account 일치, `enabled=false`, staging·저널·기존 secret 제거
- commit 각 경계에서 강제 종료한 뒤 기존 또는 신규의 완전한 한 세트로만 복구
- 재실행 뒤 action과 상태 복원
- secret·token·복구 문구·대화·암호문 비노출 검사
- phone·tabletMentor 양 variant와 macOS focused test

실기기 검증은 별도 승인 뒤 합성 계정으로만 수행한다. 동일 서명 업데이트 설치만
허용하며 앱 데이터 삭제, 실제 대화 접근, sync 활성화와 production Cloudflare
변경은 포함하지 않는다.

## 이번 구현 범위 밖

- 실제 대화 import·shadow upload·remote UI 활성화
- 계정 간 대화 병합
- 미전송 outbox 강제 폐기
- 여러 동기화 계정의 장기 보관과 계정 선택기
- 원격 계정 삭제 또는 다른 기기 강제 로그아웃
- 복구 문구 재열람 저장소와 소유자 인증 UI
