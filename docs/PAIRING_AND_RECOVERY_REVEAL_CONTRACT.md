# 기기 합류(pairing)와 복구 문구 재열람 계약

_2026-08-30 — 양 플랫폼이 함께 지키는 계약. 구현 이전에 합의해야 하는 것만 적는다._

## 왜 필요한가

복구 문구는 기기가 아니라 **계정**에 딸린다. 문구는 계정 master key를 감싸며,
사용자 결정 16번도 "최초 설정 때 1회"라고 못박는다. 따라서 계정 하나에 문구
하나이고, 둘째·셋째 기기는 계정을 새로 만드는 것이 아니라 **이미 있는 계정에
합류**해야 한다.

실기기 검증에서 기기마다 문구가 따로 나온 것은 계정을 셋 만들었기 때문이고,
그렇게 한 이유는 격리 요구도 있었지만 **다른 방법이 없기도 했다.** Worker에는
pairing이 구현돼 있으나 앱에는 합류하는 길이 없었다. 이 문서가 그 길의 계약이다.

## 역할

한 번의 합류에는 두 역할이 있고 서로 다른 것을 안다.

- **host** — 이미 계정에 연결된 기기. master key를 가지고 있고, 새 기기를
  들일지 판단한다.
- **joiner** — 아직 아무 계정에도 속하지 않은 기기. 자기 device 신원만 만든다.

Worker는 둘 사이의 우편함일 뿐이다. **평문 master key는 Worker를 지나가지
않는다.** joiner가 받는 것은 host가 봉인한 봉투이며, 그 봉투를 여는 열쇠는 QR로
직접 건넨 `pairing_secret`에서만 나온다.

## QR payload

QR에는 이것만 담는다.

| id | 내용 |
| --- | --- |
| 1 | protocol version (u32) |
| 2 | endpoint origin (ASCII, `https://`, query·fragment 없음) |
| 3 | account_id (대문자 UUID ASCII) |
| 4 | session_id (대문자 UUID ASCII) |
| 5 | pairing_secret (32바이트) |

인코딩은 magic `GDP1` + 필드 수(u16) + 필드마다 (id u16, type u8=1, length u32,
값). AAD·해시에 쓰는 `GDK1`과 **일부러 magic을 다르게 했다.** 스캔한 물건과
인증 입력은 다른 것이고, 둘 다 받아들이는 해독기는 하나를 다른 하나로 재생할
길을 열어 준다.

필드 수와 순서가 고정이므로 인코딩은 값만의 함수다. 그래서 해독기는 **읽은 것을
다시 인코딩해 바이트가 같은지 확인**하고, 다르면 거부한다. 여분 바이트,
필드 누락, 순서 뒤바뀜, non-canonical UUID는 모두 여기서 걸린다.

담지 않는 것: device token, master key, claim_secret, 복구 문구, 사용자 식별
정보. QR을 HTTP URL로 만들지 않고 clipboard·log에도 넣지 않는다. URL로 만들면
스캐너가 브라우저를 열어 `pairing_secret`이 전송 기록에 남는다.

`pairing_secret`은 **가진 사람이 곧 권한**이다. 그래서 host 화면은 QR을 띄우는
동안 "주변에서 보이지 않게 하라"고 알린다. 세션은 5분이면 닫힌다.

## 흐름

```
host                          Worker                        joiner
  │ session 만들기(인증)         │                              │
  ├─── POST /pairing/sessions ──▶│                              │
  │ QR 표시 ────────────────────────────────── 화면으로 직접 ──▶│
  │                              │◀── POST .../claims ──────────┤ claim 봉투
  │◀── GET .../claims (인증) ────┤                              │
  │ 봉투 열기 → SAS 6자리 표시    │                              │ SAS 6자리 표시
  │                                                             │
  │        ┌──────── 사람이 두 화면의 숫자가 같은지 확인 ────────┐
  │                                                             │
  │ 승인(인증) ──────────────────▶│                              │
  │  · 새 device token 생성, hash만 전달                          │
  │  · master key + token을 delivery 봉투로 봉인                  │
  │                              │◀── POST .../redeem (1회) ────┤
  │                              ├── delivery 봉투 ────────────▶│
  │                                                             │ 열어서 보관
```

SAS는 `pairing_secret`과 `claim_secret`을 함께 넣어 유도한다. 두 화면의 숫자가
같다는 것은 **같은 두 기기가 서로를 보고 있다**는 뜻이다. 중간에 누가 끼어들면
숫자가 갈린다. 그래서 **사람이 일치를 확인하기 전에는 승인할 수 없다.**

## 지켜야 하는 것

- host는 연결된 활성 기기만 session을 만든다.
- claim 목록 조회는 host token 인증이 필요하다. 다른 계정의 목록은 보이지 않는다.
- host는 **정확한 claim_id와 claim_lookup**에만 승인한다. 화면에 뜬 SAS가 나온
  그 claim이어야 한다. 여러 claim이 동시에 들어와도 승인은 하나를 지목한다.
- delivery 봉투의 AAD에는 session_id·claim_id·claim_lookup·용도가 들어간다.
  하나라도 바뀌면 복호화가 실패한다. 남의 claim 봉투를 가로채도 열리지 않는다.
- redeem은 **승인 뒤 한 번만** 된다. 두 번째는 거부되고 session은 닫힌다.
- joiner는 claim 제출 응답에서 암호문을 기대하지 않는다. 그 시점에는 아직 host가
  승인하지 않았다.
- joiner는 host와 **같은 account_id**를 저장한다. 저장하는 것은 master key와
  자기 token뿐이다.
- 합류에 성공해도 `enabled`는 `false`다. 합류는 연결이지 동기화가 아니다.
- 어느 단계든 실패하면 secret도 config도 **부분 저장하지 않는다.** 반쯤 연결된
  기기는 사용자가 고칠 방법이 없는 상태다.

## 상태

허용되는 동작은 화면이 아니라 model이 정한다. 화면이 조건을 따로 쓰면 상태
기계가 금지한 동작을 화면이 제시할 수 있다.

**host** — idle / sessionReady / waitingClaim / verifySAS / approving /
completed / expired / error

**joiner** — idle / qrAccepted / submitting / verifySAS / waitingApproval /
redeeming / linkedSyncOff / error

## 복구 문구 재열람 (계약만, 구현은 다음 단계)

실기기 검증 3회에서 3회 모두 아무도 문구를 적지 않았다. 사용자는 (B) 연결 뒤
일정 기간 재열람 허용을 선호했다. 계약은 이렇게 정한다.

- 보관하는 것은 **평문 문구가 아니라 recovery entropy 16바이트**다. 문구는 볼
  때마다 entropy에서 다시 만든다. 평문을 두면 화면에 없는 동안에도 문구가
  파일로 존재한다.
- 보관 위치는 **그 기기 안**이다. 동기화 대상이 아니고 Worker로 가지 않는다.
- 유효 기간은 enrollment 뒤 **7일**이다.
- 재열람할 때마다 **기기 소유자 인증**을 요구한다.
- 사용자가 "안전하게 기록함"을 고르거나 7일이 지나면 **삭제**한다.
- 삭제 뒤에도 **연결은 유지된다.** master key는 별도로 보관돼 있다. 없어지는
  것은 다시 볼 수 있는 능력뿐이다.
- entropy가 없으면 **새 문구를 만들지 않는다.** 새로 만들면 이전 문구로 열 수
  있던 계정을 소리 없이 잃는다. 없으면 없다고 말한다.

이번 범위에서는 protocol과 계약 test까지만 만든다. 실제 저장소·인증 화면·만료
청소는 다음 단계다.

## 이번 범위 밖

QR 렌더러와 스캐너 의존성, 카메라 권한, 실제 기기 검증, Cloudflare 연결.
