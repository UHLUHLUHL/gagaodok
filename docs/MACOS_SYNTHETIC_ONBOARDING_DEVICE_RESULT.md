# macOS 합성 onboarding 실기기 검증 결과

_2026-08-30 — 설치된 앱에서 합성 계정 연결 흐름을 처음부터 끝까지 눌러 본 기록_

## 요약

합성 전용 Cloudflare Worker를 상대로, 설치된 `/Applications/가가오독.app`에서
연결 준비 → 복구 문구 확인 → enrollment → 합성 snapshot → 재실행 복원 →
연결 해제 확인까지 12단계를 실제로 눌러 검증했다.

**실제 대화·첨부·복구 문구는 0건이다.** 대상 18개 대화 파일은 본문을 열지
않고 크기·수정시각·SHA-256만 비교했으며, 흐름 전 구간에서 변경 0건이었다.
동기화는 끝까지 `enabled=false`다.

**단위 test가 전부 통과하는 상태에서 결함 3개가 실기기에서만 드러났다.**

## 발견하고 고친 결함

| # | 증상 | 원인 | commit |
| --- | --- | --- | --- |
| 1 | "연결 준비"가 항상 실패 | 복구 단어 목록을 `.main`에서 찾음. 실제 위치는 SwiftPM 리소스 번들 | `5ec6576` |
| 2 | 실패 뒤 버튼이 전부 사라짐 | `actions`가 `.storageFailed`를 다루지 않아 `default`로 떨어짐 | `4572f75` |
| 3 | 연결 직후 snapshot 거부 | 화면 생성 시 0으로 채운 token을 붙잡고 교체 불가 | `ebb8cfd` |

셋 다 단위 test로는 잡히지 않는 종류다. 1은 번들 배치, 2는 상태 조합, 3은
객체 수명이라 각각 실제 설치·실제 실패·실제 세션이 있어야 드러난다. 1은
Android에서 이미 같은 종류(자산 누락)로 한 번 나왔다.

## 단계별 결과

| 단계 | 결과 |
| --- | --- |
| 설정 파일 배치 | 지정 경로, HTTPS workers.dev, 새 대문자 UUID 3개, 권한 600, secret·token·문구 없음 |
| 탭 진입 | "연결 안 됨", 버튼 1개, host만 표시. sync 폴더·Keychain·connection·pull·replica 전부 없음 |
| 연결 준비 | (결함 1 수정 후) 복구 문구 1회 표시. 이 시점까지 저장·전송 0건 |
| 문구 확인 | enrollment 성공. Keychain 2개 항목 생성, `connection.json` 기록 |
| 연결 상태 | `enabled=false`. 파일에 token·key·문구 필드 없음 |
| snapshot | (결함 3 재현) 같은 세션에서 거부 → 재실행 후 같은 버튼으로 완료 |
| bootstrap 완료 | `bootstrapComplete=true`, watermark 0, 합성 항목 0개 |
| 재실행 복원 | "연결됨·동기화 꺼짐"으로 복원, 이어서 "합성 자료 준비됨" |
| 연결 해제 | 확인 카드만 표시. Keychain·connection·replica 그대로 |
| 대화 원본 | 18개 파일 크기·수정시각·SHA-256 전 구간 동일 |

새로 만든 account에는 row가 없으므로 합성 항목 0개는 정상이다. 합성 row를
만들려고 token을 꺼내거나 원격 harness로 account를 건드리지 않았다.

## 남은 위험

- **결함 3의 수정은 실기기에서 확인하지 못했다.** 회귀 test로는 고정했지만,
  다시 눌러 보려면 bootstrap이 끝나지 않은 상태가 필요하고 그러려면 두 번째
  합성 계정을 만들거나 앱 데이터를 지워야 해서 이번 범위를 벗어난다.
  **설치된 앱은 결함 1·2만 고친 빌드다.**
- Keychain 항목은 login keychain에 들어갔다. 코드가 지정한
  `WhenUnlockedThisDeviceOnly`는 data protection keychain의 속성이라, 지금
  서명·entitlement 구성에서는 항목 속성으로 확인되지 않는다. 항목이 이 Mac의
  login keychain에만 있다는 것까지가 확인 가능한 범위다.
- 앱이 ad-hoc 서명이라 재설치할 때마다 코드 identity가 바뀐다. 다시 설치하면
  기존 Keychain 항목 접근에 사용자 허용이 필요할 수 있다.
- 복구 문구는 이번 검증에서 아무도 받아 적지 않았다. 합성 계정이라 잃어도
  잃을 것이 없지만, 실제 계정 흐름에서는 사용자가 반드시 적어야 한다.

## 경계

원격 Cloudflare resource는 만들지도 지우지도 바꾸지도 않았다. migration·deploy
없음, Worker 코드 변경 없음이라 원격 smoke는 반복하지 않았다. Android는 손대지
않았다. 실제 대화 연결과 동기화 활성화는 여전히 별도 승인 대상이다.
