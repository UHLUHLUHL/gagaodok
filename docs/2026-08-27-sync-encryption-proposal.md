# 동기화 암호화(E2EE) 설계 제안

## 문서 상태

- 작성일: 2026-08-27
- 작성: Claude Code
- 상태: **설계 제안 / Codex 교차검증 대기 / 구현 승인 아님**
- 선행: [CROSS_DEVICE_SYNC_AGREEMENT.md](CROSS_DEVICE_SYNC_AGREEMENT.md), [CROSS_DEVICE_SYNC_USER_DECISIONS.md](CROSS_DEVICE_SYNC_USER_DECISIONS.md)
- 이 문서를 쓰며 앱 코드·실제 대화 데이터·Cloudflare 리소스는 변경하지 않았다.

이 문서는 두 부분이다. **1부**는 사용자가 이번 라운드에서 새로 확정·변경한 제품 결정 기록이고, **2부**는 그중 1번(암호화)을 실제로 구현하기 위한 기술 설계 제안이다. 1부는 기존 결정 기록에 병합되어야 하며, 병합 작업은 Codex가 맡는다(같은 파일을 두 에이전트가 동시에 고치지 않기 위함).

---

# 1부 · 이번 라운드의 사용자 결정

## 1.1 변경된 결정

| 번호 | 이전 | 변경 후 |
| ---: | --- | --- |
| 1 | 잠그지 않는다 | **암호화한다 (E2EE)** |
| 14 | 즉시 알림(real-time)을 사용한다 | **앱이 열려 있을 때의 갱신만 사용한다. OS push(FCM/APNs)는 만들지 않는다** |

14번 변경 근거: 이 앱에는 사용자에게 말을 거는 제3자가 없다. 다른 기기에 새 내용이 생기는 경우는 사용자 본인이 그 기기에서 대화한 경우뿐이므로, 잠금화면 push는 이미 아는 사실을 알리는 것에 그친다. 선제 메시지(proactive message) 기능을 실제로 만들 때 재검토한다.

## 1.2 새로 확정된 결정

| 번호 | 항목 | 결정 |
| ---: | --- | --- |
| 16 | 모든 기기 분실 시 복구 수단 | **복구 문구(recovery phrase)를 최초 설정 시 1회 제시하고 사용자가 보관한다** |
| 17 | 암호화 범위 | **방 이름·persona·요약·본문·첨부까지 전부 암호화한다. 서버에는 식별자·순번·시각만 평문으로 남긴다** |

## 1.3 해소된 항목

**9번(호감도 공유)** — 추가 결정 불필요. 코드 확인 결과 호감도·단톡방·세계선은 폰 전용 기능이다.

- Mac 모델(`Sources/KakaoSapiens/Models/*.swift`)에 `affection`·`heartChange`·`GroupChat`·`worldline` 정의가 0건이다.
- 태블릿 flavor는 `ChatsScreen.kt`의 `BuildConfig.TABLET_MENTOR` 분기에서 "새 단톡방" 메뉴 자체가 노출되지 않는다.

따라서 단톡방 하트는 `PHONE_SPACE` 안에만 존재하고, 3번 결정(폰 방은 백업하되 다른 space에 숨김)에 의해 Mac·태블릿에 노출되지 않는다. **9번의 "공유하지 않음"은 자동으로 충족된다.**

동시에 4번 결정의 범위도 축소된다. **4번의 "단톡방·세계선을 처음부터 포함"은 canonical scope와 D1 백업 대상에 포함한다는 뜻이며, Mac·태블릿이 group/worldline semantics를 이해하도록 만든다는 뜻이 아니다.** 이전 검토에서 Claude Code가 "Mac·태블릿이 단톡방을 이해하는 작업이 Phase 1에 들어온다"고 한 것은 과대평가였다. 정정한다.

## 1.4 조건이 붙은 결정

**11번 · 삭제 시 호감도** — 하트를 되돌리되, **되돌릴 `heartChanges` 기록이 없는 경우에는 되돌리지 않고 삭제만 수행한다.** 기록이 없는 경우는 (a) `heartChanges` 필드 도입 이전 대화, (b) 해당 anchor bubble이 이미 삭제된 대화다.

**12번 확장 · 요약 + 말투 로직 통일** — 사용자가 12번의 규칙을 persona/말투 로직에도 적용하기로 했다.

> 챗봇 모드는 Android 폰 기준, 멘토 모드는 Mac 기준으로 **압축 설정과 말투 로직을 함께** 통일한다.

이를 위해 Mac 모델에 `suppressedExpressions`와 `sampleEvidence` 필드를 추가해야 한다. 기존 방 호환성은 확인했다 — 두 필드 모두 기본값이 빈 목록이고, `selectRuntimePersonaSamples`([PersonaSourcePipeline.kt:180](../android/app/src/main/java/com/sapiens/gagaodok/service/PersonaSourcePipeline.kt))가 evidence가 비었을 때 `diversifyTexts(samples)`로 갈라지도록 이미 짜여 있다. **옛 방은 기능이 비활성 상태가 될 뿐 깨지지 않는다.**

단 12번 본체와 같은 주의가 적용된다. **기존 Mac 챗봇 방의 응답 결이 실제로 바뀐다.** 동기화 구현에 포함시키지 말고 별도 변경으로 다루며, `compactionProfileId`/`compactionContractFingerprint` versioning이 선행되어야 한다. 말투 로직도 profile 식별자에 반영해야 한다.

**8번 · 미지원 방 처리** — 결정(다른 방식 대답 허용)은 유지한다. 12번 확장으로 현재 알려진 divergence는 사라지지만, 향후 한쪽에만 기능이 생길 때를 대비해 규칙은 남긴다. 안내 표시는 매 턴 팝업이 아니라 **방 진입 시 1회 또는 방 목록의 상시 표기**로 하고, 구체적 형태는 UI 구현 시 정한다.

**2번 · 첨부 접근 보호** — 결정이 아니라 구현 규칙으로 기록한다.

1. R2 객체에 공개 접근 경로를 만들지 않는다.
2. 앱이 첨부를 요청하면 Worker가 device token을 검증한 뒤에만 단기 유효한 접근 경로를 발급하거나 Worker가 중계한다.
3. **기기 종속이 아니다.** 계정에 속한 기기임이 증명되면 어느 기기에서든 접근 가능하다.

**13번** — 기기 간 Gemini cache 공유만 하지 않는다. 각 기기가 자기 로컬 cache를 쓰는 동작은 유지한다.

**4·10·11 조합** — 사용자 확인 완료. 단톡방에서 AI 응답 하나를 `delete_turn`하면 여러 화자의 bubble이 함께 삭제되고 여러 참여자의 하트가 함께 되돌아가는 것이 의도된 동작이다.

---

# 2부 · 암호화 설계 제안

## 2.1 범위와 원칙

1. **암호화 경계는 동기화 경계다.** 로컬 JSON 저장은 현재 형식을 유지한다. 합의문의 "기존 저장 codec을 바꾸지 않는다" 원칙과 일치하며, 로컬 검색·압축·렌더가 영향을 받지 않는다.
2. **서버는 평문을 어떤 형태로도 보지 않는다.** Worker는 라우팅·순서·권한만 판정한다.
3. **fail closed.** 암호화에 실패하면 평문으로 저장하지 않고 작업을 실패시킨다. 복호화에 실패하면 빈 값으로 대체하지 않고 오류 상태로 표시한다.
4. **두 구현(Swift·Kotlin)은 규격이 한 바이트도 어긋나면 안 된다.** 이 저장소는 이미 같은 실수를 겪었다 — prefix cache fingerprint가 Swift는 정렬 JSON, Android는 삽입 순서 JSON을 해싱해 교차 호환이 깨져 있다. 그 구현을 본으로 삼지 않는다.
5. **키·복구 문구·평문을 로그·오류 메시지·분석 payload에 남기지 않는다.**

## 2.2 키 계층

```text
recovery_phrase            사용자 보관. 128비트 엔트로피의 단어 목록
   │
   │  HKDF-SHA256(ikm = phrase_bytes, salt = account_salt, info = ...)
   │
   ├── content_key      (32B)  콘텐츠 암호화용. 서버는 절대 보지 않음
   └── recovery_auth    (32B)  복구 시 계정 소유 증명용
                               서버는 SHA-256(recovery_auth)만 보관
```

`account_salt`는 계정 생성 시 만든 16바이트 난수이며 서버가 평문 보관한다(비밀이 아님).

### 2.2.1 KDF를 PBKDF2/Argon2가 아니라 HKDF만 쓰는 이유

복구 문구는 **사람이 고른 비밀번호가 아니라 기기가 생성한 128비트 난수**다. 사전 공격 대상이 아니므로 메모리 하드 KDF로 늘릴 이득이 없다. 반대로 Argon2id는 두 플랫폼 모두 외부 라이브러리를 요구하고, 파라미터가 어긋나면 서로 다른 키가 나오는 새 실패 지점을 만든다.

HKDF는 macOS 14의 CryptoKit에 내장되어 있고, Android는 HMAC-SHA256 기반으로 20줄 내외로 구현되거나 Tink로 대체 가능하다. **엔트로피가 128비트 미만인 문구를 허용하는 경우에는 이 판단이 뒤집힌다.** 검증 필요.

### 2.2.2 접근 인증과 암호 키의 분리

Codex의 지적대로 둘은 다른 문제다. 본 제안은 분리하되 같은 문구에서 유도한다.

| | 용도 | 서버 보관 |
| --- | --- | --- |
| device token | 평상시 API 접근 | 해시만 |
| `recovery_auth` | 모든 기기 분실 시 재발급 | 해시만 |
| `content_key` | 콘텐츠 복호화 | **없음** |

- 기기 1대 분실 → 해당 device token만 폐기. `content_key`는 무관.
- 전 기기 분실 → 복구 문구로 `recovery_auth`를 재계산해 새 device token을 발급받고, 같은 문구로 `content_key`를 복원한다.

## 2.3 레코드 암호화

- 알고리즘: **AES-256-GCM**
  - Swift: CryptoKit `AES.GCM` (macOS 14 ✓)
  - Kotlin: `javax.crypto.Cipher` `"AES/GCM/NoPadding"` (minSdk 26 ✓)
  - 두 플랫폼 모두 내장이므로 새 의존성이 없다.
- nonce: 레코드마다 **12바이트 CSPRNG 난수**. 재사용 금지.
- 인증 태그: 16바이트.

### 2.3.1 scope별 하위 키

nonce 재사용 위험을 줄이기 위해 conversation scope마다 하위 키를 유도한다.

```text
scope_key = HKDF-SHA256(content_key, info = "gagaodok/v1/scope/" || space_id || "/" || room_id || "/" || worldline_id_or_empty)
```

단일 키에 랜덤 nonce만 쓰는 방식도 이 앱 규모에서는 안전 범위지만, 하위 키 유도는 비용이 거의 없고 분석 부담을 없앤다. **대안(단일 키 유지)과의 비교 검토 필요.**

### 2.3.2 AAD 결속

ciphertext가 다른 레코드 자리로 옮겨지는 것을 막기 위해 AAD로 identity를 묶는다.

```text
AAD = "gagaodok/v1" || space_id || room_id || worldline_id_or_empty
      || turn_id || message_id || field_name
```

서버 버그나 공격자가 레코드를 뒤바꿔도 복호화가 실패한다.

### 2.3.3 봉투 형식

```text
[0] version   1 byte   (0x01)
[1] alg       1 byte   (0x01 = AES-256-GCM)
[2..13] nonce 12 bytes
[14..] ciphertext || tag
```

텍스트 컬럼에 넣을 때는 base64(표준, 패딩 포함)로 감싼다. **base64 변형(URL-safe 여부, 패딩)을 규격에 못 박는다.**

## 2.4 무엇을 잠그고 무엇을 남기나 (결정 17-나)

### 평문으로 남기는 것 — 라우팅·순서에 필요한 값만

`space_id`, `room_id`, `worldline_id`, `turn_id`, `bubble_order`, `message_id`,
`revision`, `base_revision`, `server_seq`, `operation_id`,
tombstone 표시, `created_at`/`updated_at`,
attachment의 바이트 크기, `import_batch_id`, `account_salt`

### 암호화하는 것

| 영역 | 대상 |
| --- | --- |
| 방 | `title`, `statusMessage`, `musicTitle`, `musicArtist` |
| Persona | `description`, `samples`, `styleGuide`, `suppressedExpressions`, `sampleEvidence` |
| 메시지 | `text`, `canonicalText`, `kind` 외 표시 내용 |
| 요약 | checkpoint의 `segments[].text`, `summary_text` |
| 관계 | `heartChanges[].reason` |
| 첨부 | 파일 바이트, `fileName`, `mimeType` |
| 아바타 | 이미지 바이트 |

### 미결 — Codex 판단 필요

`engineProfile`, `compactionProfileId`, `compactionContractFingerprint`, `mode`, `modelIdentifier`를 평문으로 둘지 암호화할지. 합의문상 호환성 판정은 client가 하므로 **서버가 읽을 필요는 없다.** 다만 평문이면 운영·디버깅이 쉽고, 암호화하면 "이 방은 챗봇 모드"라는 정보까지 감춰진다. 사용자 우려(대화 성격 노출)를 고려하면 암호화 쪽이 일관적이나, checkpoint 호환성 게이트 구현이 복잡해질 수 있다.

**타임스탬프는 평문으로 두는 것을 제안하되 한계를 명시한다.** 대화 시각 분포와 빈도는 노출된다. 순서를 `server_seq`만으로 세울 수 있다면 암호화도 가능하나, 방 목록 정렬용 `lastMessageTime`이 파생값이라 정리가 필요하다.

## 2.5 첨부와 R2 — 봉투 암호화

파일마다 독립 키를 쓰고, 그 키를 `scope_key`로 감싸 레코드에 저장한다.

```text
file_key = CSPRNG(32B)
R2 객체 = AES-256-GCM(file_key, 파일 바이트)
레코드에 저장 = AES-256-GCM(scope_key, file_key)   ← 감싼 키
R2 객체 이름 = 내용과 무관한 난수 UUID
```

- 큰 파일을 다시 암호화하지 않고도 상위 키를 바꿀 수 있다.
- 2번 규칙(Worker 경유 접근 통제)은 그대로 적용된다. 암호화는 두 번째 방어선이다.
- **base64 인라인 첨부는 D1에 넣지 않는다.** 행당 2MB 제한 때문이며, 이는 결정 2와 일치한다.

## 2.6 복구 문구

- 엔트로피 128비트, 12단어. BIP-39 영어 wordlist 재사용을 제안한다(검증된 목록, 체크섬 내장, 두 플랫폼에 구현이 흔함).
- **한국어 wordlist는 권하지 않는다.** 유니코드 정규화·띄어쓰기·유사 자모 문제를 새로 만든다.
- 최초 설정 시 1회 제시하고, 사용자가 옮겨 적었는지 확인하는 재입력 단계를 둔다.
- 앱은 문구를 저장하지 않는다. 유도한 키만 Keychain(macOS) / EncryptedSharedPreferences 또는 Keystore(Android)에 둔다.
- **문구 분실 = 클라우드 사본 영구 손실.** 로컬 데이터는 무관하다. 이 문구를 UI에 명시한다.
- 문구 교체(키 회전)는 전체 재암호화를 요구하므로 초기 범위에서 제외한다. 봉투 구조 덕에 이후 추가 가능하다.

## 2.7 정규화 규격 — 가장 깨지기 쉬운 부분

복구 문구에서 키를 유도할 때 두 플랫폼이 **같은 바이트열**을 입력해야 한다. 한국어 환경과 macOS 파일 시스템 특성상 유니코드 정규화가 어긋날 실질적 위험이 있다.

규격으로 못 박는다.

1. 문구는 **NFKD가 아니라 NFC**로 정규화한다.
2. 앞뒤 공백 제거, 단어 사이는 단일 U+0020, 전부 소문자.
3. UTF-8 인코딩, BOM 없음.
4. `info` 문자열과 AAD 구성 요소도 UTF-8, 구분자는 `/`와 `||`로 고정하고 각 요소를 그대로 이어붙인다. UUID는 **대문자 하이픈 형식**으로 통일한다(기존 `Codec.kt` 규약과 일치).

메시지 본문 자체는 바이트를 그대로 암·복호화하므로 정규화 대상이 아니다. 정규화는 **키 유도와 AAD에만** 적용한다.

## 2.8 교차 구현 contract test (Phase 1 필수)

1. **고정 테스트 벡터** — 주어진 phrase·salt·nonce·평문에 대한 기대 ciphertext를 hex로 문서에 박고, Swift·Kotlin 양쪽이 동일 결과를 내는지 확인한다.
2. **교차 복호** — Swift가 암호화한 것을 Kotlin이 풀고, 그 반대도 통과해야 한다.
3. **AAD 불일치 거부** — identity를 바꾼 ciphertext는 복호화에 실패해야 한다.
4. **한글 문자열 왕복** — 조합형·완성형이 섞인 입력이 정확히 복원되어야 한다.
5. **fail closed 검증** — 키가 없을 때 평문이 저장되지 않음을 확인한다.
6. **비파괴 importer와의 결합** — 암호화는 업로드 경로에서만 일어나고 원본 로컬 파일의 byte·mtime·hash가 변하지 않아야 한다.

이 시험이 통과하기 전에는 실제 대화를 올리지 않는다. 합의문 Phase 3 게이트에 이 항목을 추가한다.

## 2.9 합의문에 추가되어야 할 절

이 제안이 승인되면 합의문에 다음이 신설되어야 한다.

- **기기 인증·연결 계약** — 현재 합의문에 통째로 없다. `created_by_device_id`를 여러 곳에서 쓰지만 기기 신원의 출처가 정의되어 있지 않다. pairing, device token 발급·보관·폐기, 복구 경로를 포함해야 한다.
- **암호화 계약** — 2부 전체.
- **결정 16·17** — 제품 결정 표에 추가.

## 2.10 Codex에게 요청하는 검토 항목

1. HKDF 단독 사용 판단이 타당한가. 복구 문구 엔트로피를 128비트로 강제할 수 있는가.
2. scope별 하위 키와 단일 `content_key` 중 어느 쪽이 나은가.
3. AAD 구성 요소가 충분한가. `bubble_order`·`revision`을 포함해야 하는가(포함 시 재정렬·수정 때 재암호화가 필요해진다).
4. `engineProfile`·`compactionProfileId`·`fingerprint`를 평문으로 둘지.
5. 타임스탬프 평문 유지의 노출 범위가 수용 가능한가. `lastMessageTime`을 `server_seq` 파생으로 대체할 수 있는가.
6. 봉투 형식에 `key_generation` 필드를 지금 넣어둘지(나중 키 회전 대비).
7. Android에서 HKDF를 직접 구현할지 Tink를 도입할지.
8. 복구 문구 재입력 확인 UX가 Phase 몇에 들어가야 하는가.
9. E2EE 상태에서 Phase 3 Shadow Upload의 hash manifest 검증을 어떻게 구성할 것인가(평문 hash와 ciphertext hash를 분리해야 하는가).
10. 이 제안보다 단순한 구성으로 같은 보호 수준을 얻을 수 있는가.
