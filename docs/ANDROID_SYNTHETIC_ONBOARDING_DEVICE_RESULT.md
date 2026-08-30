# Android 합성 onboarding 실기기 검증 결과

_2026-08-30 — phone과 tabletMentor 두 기기에서 합성 계정 연결 흐름을 눌러 본 기록_

## 요약

무선 디버깅으로 연결한 실제 phone(SM-S938N)과 tablet(SM-X910)에서, 합성 전용
Cloudflare Worker를 상대로 연결 준비 → 복구 문구 → enrollment → 합성 snapshot →
재실행 복원 → 연결 해제 확인까지 두 기기 각각 완주했다.

**실제 대화·첨부·복구 문구는 0건이다.** 앱 내부 대화 파일은 본문을 열지 않고
경로·크기·수정시각·SHA-256만 전후 비교했다. 동기화는 끝까지 꺼진 상태다.

**두 기기는 서로 다른 합성 account를 쓴다.** Mac이 쓰는 account와도 다르다.

## 설치와 신원

| | phone | tablet |
| --- | --- | --- |
| package | `com.sapiens.gagaodok` | `com.sapiens.gagaodok.tabletmentor` |
| version | 13 / `1.9-phone` | 1 / `2.0-tablet-mentor` |
| signer | 기존·debug·release 전부 동일 | 기존·debug·release 전부 동일 |
| UID | 10634 → 끝까지 10634 | 10057 → 끝까지 10057 |
| 최종 설치본 | HEAD release APK | HEAD release APK |

`run-as`로 설정을 넣기 위해 같은 signer의 debug를 데이터 보존 업데이트로
설치했고, 시험 뒤 uninstall 없이 release로 되돌렸다. 앱 데이터 삭제는 0건이다.

## 단계별 결과 (두 기기 동일)

| 단계 | 결과 |
| --- | --- |
| 탭 진입 | "연결 안 됨", 버튼 1개, host만 표시. `files/sync` 없음 = 저장·전송 0건 |
| 연결 준비 | 복구 문구 1회 표시. **이 시점에도 `files/sync` 없음** |
| 문구 확인 | enrollment 성공. `connection.json`과 Keystore 보관물 생성 |
| 연결 상태 | `enabled`는 기본값 `false`이며 파일에 기록되지 않는다 = 꺼짐 |
| **같은 세션 snapshot** | **성공.** `bootstrapComplete=true`, watermark 0, 항목 0개 |
| 다음 페이지 | 제공되지 않음 |
| 재실행 | "합성 자료 준비됨" 유지 |
| 연결 해제 | 확인 카드만. 키·연결·replica 그대로 |
| release 복귀 | 상태 그대로 복원 |

새로 만든 account에는 row가 없으므로 항목 0개는 정상이다. 합성 row를 만들려고
token을 꺼내거나 원격 harness로 account를 건드리지 않았다.

## macOS가 확인하지 못한 것을 여기서 확인했다

macOS에서는 bootstrap이 이미 끝나 있어, "token이 저장되기 전에 만들어진 화면이
나중에 저장된 token을 쓰는가"를 실기기에서 재현하지 못했다. Android에서는 앱을
켠 채로 연결하고 곧바로 snapshot을 받아 **두 기기 모두 성공**했다. `5c414b6`의
provider 경로가 실제 기기에서 동작한다는 증거다.

`f1389bd`(빈 snapshot 완료 유지)도 두 기기의 재실행에서 확인했다.

## 발견하고 고친 결함

`1a67d52` — **APK가 네 variant 모두 빌드되지 않았다.** `build.gradle.kts:92`가
이미 Swift 리소스 폴더를 assets로 잡고 있는데 `e4fb618`에서 같은 단어 목록을
`app/src/main/assets/`에도 넣어 "Duplicate resources"로 병합이 멈췄다. 사본을
지워 해결했다.

놓친 이유는 분명하다. 그때 compile과 unit test만 돌리고 APK를 만들어 보지
않았다. assets 병합은 `assemble`에서만 일어난다. **Android를 고치면 최소 한 번은
assemble까지 해야 한다.**

## 남은 위험

- **복구 문구를 두 기기 모두 아무도 받아 적지 않았다.** 합성 계정이고 항목이
  0개라 잃은 것은 없고, master key는 각 기기 Keystore에 그대로 있어 연결도
  멀쩡하다. macOS도 같은 상태다.

  그러나 이것은 사용자의 부주의가 아니라 **화면의 결함이 드러난 것이다.** 문구는
  한 번 보여주고 사라지는데, 화면은 사용자가 적을 준비가 됐는지 확인하지 않고
  "문구를 적어 두었습니다" 버튼 하나만 둔다. 세 번의 실기기 검증에서 세 번 모두
  아무도 적지 않았다면, 실제 계정에서도 그럴 것이라고 보는 편이 맞다.

  실제 대화 연결 전에 정해야 한다. 후보는 세 가지였다. (A) 확인을 2단계로
  만들어 몇 개 단어를 되묻는다. (B) 연결 뒤에도 일정 기간 다시 볼 수 있게 한다.
  (C) 현행 유지하고 경고 문구만 강화한다.

  **사용자는 (B)를 선호한다고 밝혔다.** 최종 판단은 Codex에 있다. (B)를 택하면
  설계할 때 함께 정해야 할 것이 있다. 다시 볼 수 있는 기간, 그 기간에 문구가
  화면에 다시 나타난다는 사실(어깨너머로 보일 수 있다), 기간이 끝난 뒤에도
  master key는 기기에 남으므로 재열람만 막히고 연결은 유지된다는 점, 그리고
  재열람에 기기 잠금 해제를 요구할지 여부다.
- phone에서 `ink_documents.json` 하나가 수정시각만 바뀌었다. 내용(SHA-256)은
  같고 앱 시작 시 빈 파일을 다시 쓴 것으로, 동기화와 무관하다.
- Android Keystore 보관물은 존재만 확인했다. 값은 읽지 않았고 wrapping 강도는
  이번 범위에서 검증하지 않았다.

## 기기 합류(pairing) 화면 후속 검증

위에서 확인한 화면 부재는 `6a8f85c`~`c6a4a53`에서 Mac host QR·SAS UI와
Android 앱 내부 CameraX·ML Kit scanner를 추가해 닫았다. 기존 정식 앱 데이터를
건드리지 않기 위해 phone과 tablet에는 각각 별도 package의 `pairingTest` APK를
나란히 설치했고, Mac은 현재 HEAD 앱으로 교체했다.

두 기기 모두 다음 흐름을 실기기에서 통과했다.

1. Android의 명시적 스캔 동작 뒤에만 카메라 권한 요청
2. 앱 내부 카메라로 Mac의 메모리 QR 인식
3. Mac과 Android의 6자리 SAS 일치 확인
4. Mac 명시 승인 뒤 Android가 1회 redeem
5. Mac·Android 모두 "합류 완료·동기화 꺼짐" 표시
6. 저장된 account가 Mac과 일치하고, secret blob과 connection이 재실행 뒤에도 생존

실기기 과정에서 승인 대기 상태가 SAS 숫자를 잃는 결함을 발견했다. `be7b8e8`이
최초 숫자를 계속 표시하도록 고쳤고 phone·tablet focused test와 두 시험 APK
assemble을 통과했다. 두 정식 Android package와 시험 package는 UID·저장소가
서로 다르며, 정식 앱 데이터는 수정하거나 삭제하지 않았다.

이 검증은 합성 account에 device 두 개를 추가했을 뿐이다. 실제 대화는 읽거나
전송하지 않았고 sync는 양쪽 모두 기본값 `false`다. 다음 제품 gate는 이미 다른
계정에 연결된 정식 앱이 데이터를 지우지 않고 명시적으로 계정을 전환하는 UX다.

## 정식 앱 account 전환 구현 상태

`8e52b30`~`dafd772`에서 위 gate의 코드 경계를 구현했다. Swift와 Android 모두
active/candidate secure slot, durable transition journal, 원자적 commit·rollback과
중단 지점별 crash recovery를 갖는다. Android 정식 설정 화면은 candidate shadow
bootstrap 뒤 계정을 교체하며, Mac 정식 설정 화면은 안전한 local 연결 해제를 제공한다.
현재 연결을 바꾸기 전에 명시적 확인을 요구하고, sync가 켜져 있거나 durable outbox가
남아 있으면 전환과 연결 해제를 제시하지 않는다. Mac이 다른 host account에 합류하는
입력 UI는 이번 제품 흐름에 포함하지 않았다.

연결 해제는 이 기기의 active sync 자격과 shadow replica만 비활성화하는 local
동작이다. 원격 account, 다른 기기, 기존 local conversation은 삭제하지 않는다.
Android의 기존 계정 합류는 candidate token으로 snapshot을 임시 private storage에
끝까지 받은 뒤에만 active slot을 교체하며, 실패·재실행 시 journal이 old 또는 new
한 계정으로 수렴시킨다. 완료 뒤에도 sync 기본값은 `false`다.

이 구현은 unit test와 phone·tabletMentor compile까지 통과했지만 정식 Android
package를 설치하거나 실제 기기에서 account 전환을 실행하지는 않았다. 따라서
현재 판정은 **코드 경계 완료·실기기 gate 대기**다. 다음 검증에는 동일 signer의
update 설치와 합성 account만 사용해야 하며, app data 삭제·실제 대화 접근·sync
활성화·Cloudflare resource 변경은 허용되지 않는다.

## 경계

Cloudflare resource 구성은 만들거나 지우거나 바꾸지 않았다. 후속 pairing
검증에서는 기존 원격 합성 account에 phone·tablet 시험 device를 등록했다. Worker
코드 변경이 없어 원격 smoke는 반복하지 않았다. Android 정식 앱 uninstall·데이터
삭제는 0건이다. 실제 대화 연결과 동기화 활성화는 여전히 별도 승인 대상이다.
