# 동기화 암호화(E2EE) 설계 제안 — 개정본

## 문서 상태

- 최초 작성: 2026-08-27 (Claude Code, commit `3b449dc`)
- 1차 개정: 2026-08-27 (Claude Code, commit `ea8b34f`)
- 2차 개정: 2026-08-27 (Codex)
- 3차 보정: 2026-08-27 (Claude Code) — R1·R2·`alg` AAD·Phase 0 실측값 반영
- 4차 통합: 2026-08-27 (Codex) — 고정 vector 독립 재현, redeem verifier 등록·결속 보완, Tablet 실측 통합
- 5차 구현 증거: 2026-08-29 (Codex) — 공용 AES-GCM artifact와 Swift·Kotlin fixed-vector 구현
- 상태: **field E2EE fixed-vector 구현·교차 검증 완료 / pairing·recovery·앱 동기화 연결 미완료 / Cloudflare 리소스 생성·실데이터 업로드 승인 아님**
- 재검토 이력: [`618d370`/`377b717` Claude Code 독립 재검토](2026-08-27-e2ee-2nd-revision-claude-review.md)(당시 이력, 본문 보존), [3차 보정 설명](2026-08-27-e2ee-3rd-revision-notes.md), [Codex 통합 검토](2026-08-27-e2ee-codex-integration-review.md)
- 선행: [합의문](CROSS_DEVICE_SYNC_AGREEMENT.md), [사용자 결정 기록](CROSS_DEVICE_SYNC_USER_DECISIONS.md), [Codex 교차검토](2026-08-27-sync-encryption-codex-review.md)
- 4차 문서 통합까지는 앱 코드를 변경하지 않았다. 5차에는 동기화에 아직
  연결되지 않은 local contract crypto module만 추가했으며, 실제 대화 데이터와
  Cloudflare 리소스는 계속 사용하지 않았다.

## 개정 요약

초판(`3b449dc`)은 복구 문구에서 `content_key`를 직접 유도했다. 외부 AI 검토와 Codex 교차검토에서 이 구조가 **실제로 동작하지 않는다**는 것이 확인되었다.

1. `account_salt`를 서버에서 받아야 키를 만드는데, 계정을 찾으려면 그 키가 필요하다 — 순환.
2. QR pairing은 device token만 넘기므로 새 기기는 암호문만 받고 읽지 못한다.
3. 복구 문구 교체가 전체 재암호화를 요구한다.

개정본은 **무작위 `account_master_key`를 중심에 두고 복구 문구는 그것을 감싸는 용도로만 쓰는 구조**로 교체한다. 그 밖의 보정 항목은 §11에 정리했다.

---

# 1부 · 확정된 사용자 결정

이 부는 [사용자 결정 기록](CROSS_DEVICE_SYNC_USER_DECISIONS.md)에 반영되어 있다. 여기서는 암호화 설계와 직접 얽힌 항목만 근거와 함께 남긴다.

## 1.1 변경·신설

| 번호 | 결정 |
| ---: | --- |
| 1 | **E2EE를 적용한다** (초안: 잠그지 않는다) |
| 14 | **앱이 열려 있을 때의 갱신만 사용한다.** OS push(FCM/APNs)는 만들지 않는다 |
| 16 | **복구 문구**를 최초 설정 시 1회 제시하고 사용자가 보관한다 |
| 17 | 방 이름·persona·요약·본문·첨부까지 **내용은 모두 암호화**한다. 서비스 동작상 불가피한 metadata만 최소한으로 평문 유지 |

14번 근거: 이 앱에는 사용자에게 말을 거는 제3자가 없다. 다른 기기에 새 내용이 생기는 경우는 사용자 본인이 그 기기에서 대화한 경우뿐이므로 잠금화면 push는 이미 아는 사실을 알린다. 선제 메시지 기능을 실제로 만들 때 재검토한다.

17번 표현 보정: 초판의 "식별자·순번·시각만 평문"은 부정확했다. 첨부 byte size, tombstone, operation metadata 등도 평문이 불가피하다. §8에 경계를 다시 정의한다.

## 1.2 코드로 해소된 항목 — 9번

호감도·단톡방·세계선은 **폰 전용 기능**이다.

- Mac 모델(`Sources/KakaoSapiens/Models/*.swift`)에 `affection`·`heartChange`·`GroupChat`·`worldline` 정의가 0건이다.
- 태블릿 flavor는 `ChatsScreen.kt`의 `BuildConfig.TABLET_MENTOR` 분기에서 "새 단톡방" 메뉴가 노출되지 않는다.
- `WorldlineState.participantHearts`는 Android 폰 전용 group state 안에 있다.

따라서 단톡방 하트는 `PHONE_SPACE` 안에만 존재하고, 3번 결정(폰 방은 백업하되 다른 space에 숨김)에 의해 자동으로 비공개가 된다. **9번은 추가 조치가 필요 없다.**

같은 이유로 4번의 범위도 축소된다. **4번의 "단톡방·세계선을 처음부터 포함"은 canonical scope와 D1 백업 대상에 포함한다는 뜻이며, Mac·태블릿이 group/worldline semantics를 이해하도록 만든다는 뜻이 아니다.** 초판에서 Claude Code가 "Mac·태블릿이 단톡방을 이해하는 작업이 Phase 1에 들어온다"고 한 것은 과대평가였다.

## 1.3 조건이 붙은 결정

**11번 · 삭제 시 호감도** — 하트를 되돌리되, 되돌릴 `heartChanges` 기록이 없으면 되돌리지 않고 삭제만 수행한다. 기록이 없는 경우는 (a) `heartChanges` 도입 이전 대화, (b) anchor bubble이 이미 삭제된 대화다.

**12번 확장 · 요약 + 말투 통일** — 챗봇 모드는 Android 폰 기준, 멘토 모드는 Mac 기준으로 **압축 설정과 말투 로직을 함께** 통일한다.

이 작업은 필드 두 개 추가로 끝나지 않는다.

- Mac `PersonaStyle`에 `suppressedExpressions`·`sampleEvidence`를 추가하려면 **`init(from:)`을 직접 구현해 `decodeIfPresent(...) ?? []`로 읽어야 한다.** 현재 `PersonaStyle`은 synthesized `Codable`을 쓰고, Swift의 자동 합성 디코더는 프로퍼티 선언의 기본값을 적용하지 않으므로 새 non-optional key가 없는 옛 JSON에서 `keyNotFound`가 난다. Codex가 로컬 Swift 실행으로 확인했다. 같은 파일의 `RoomProfile`이 이미 custom decoder 패턴을 쓰고 있다.
- 초판의 "옛 방은 기능이 비활성될 뿐"이라는 서술도 부정확했다. Android `selectRuntimePersonaSamples()`는 evidence가 비면 `diversifyTexts(samples)`로 진행하므로 **표본 다양화와 token budget 제한은 계속 작동한다.** 없어지는 것은 evidence 기반 우선순위뿐이다.
- 표본 선택·반복 억제·prompt contract를 Mac으로 옮기고 이를 `engineProfile`과 말투 contract fingerprint에 반영해야 한다.

**기존 Mac 챗봇 방의 응답 결이 실제로 바뀐다.** 동기화 구현에 포함시키지 말고 별도 변경으로 다루며, `compactionProfileId`/`compactionContractFingerprint` versioning이 선행되어야 한다.

**8번 · 미지원 방 처리** — 결정(다른 방식 대답 허용)은 유지한다. 12번 확장으로 현재 알려진 divergence는 사라지지만 향후를 위해 규칙은 남긴다. 안내는 매 턴 팝업이 아니라 방 진입 시 1회 또는 방 목록 상시 표기로 하고, 구체적 형태는 UI 구현 시 정한다.

**2번 · 첨부 접근 보호** — 구현 규칙으로 기록한다.

1. R2 객체에 공개 접근 경로를 만들지 않는다.
2. 앱이 첨부를 요청하면 Worker가 device token을 검증한 뒤에만 단기 유효 경로를 발급하거나 Worker가 중계한다.
3. **기기 종속이 아니다.** 계정에 속한 기기임이 증명되면 어느 기기에서든 접근 가능하다.

**13번** — 기기 간 Gemini cache 공유만 하지 않는다. 각 기기가 자기 로컬 cache를 쓰는 동작은 유지한다.

**4·10·11 조합** — 사용자 확인 완료. 단톡방에서 `delete_turn`하면 여러 화자의 bubble이 함께 삭제되고 여러 참여자의 하트가 함께 되돌아가는 것이 의도된 동작이다.

---

# 2부 · 암호화 설계

## 2. 범위와 원칙

1. **암호화 경계는 동기화 경계다.** 로컬 JSON 저장은 현재 형식(평문)을 유지한다. 합의문의 "기존 저장 codec을 바꾸지 않는다" 원칙과 일치하며 로컬 검색·압축·렌더가 영향을 받지 않는다.
   **따라서 이 설계가 제공하는 보호는 "클라우드 동기화 사본의 E2EE"이며 "기기 내부 데이터 암호화"가 아니다.** 사용자 안내에 이 경계를 명시한다.
2. **서버는 평문을 어떤 형태로도 보지 않는다.** Worker는 라우팅·순서·권한만 판정한다.
3. **fail closed.** 암호화 실패 시 평문으로 저장하지 않고 작업을 실패시킨다. 복호화 실패를 빈 값으로 대체하지 않고 오류 상태로 표시한다.
4. **두 구현(Swift·Kotlin)의 규격이 한 바이트도 어긋나면 안 된다.** 이 저장소는 이미 같은 실패를 겪었다 — prefix cache fingerprint가 Swift는 정렬 JSON, Android는 삽입 순서 JSON을 해싱해 교차 호환이 깨져 있다. 그 구현을 본으로 삼지 않는다.
5. **키·복구 문구·인증 비밀·평문을 로그·오류 메시지·URL·분석 payload에 남기지 않는다.**

## 3. 키 계층

```text
recovery_entropy (16B, CSPRNG)          사용자가 12단어로 보관
   │  HKDF-SHA256(IKM = recovery_entropy, salt = PROTOCOL_SALT, info, L = 32)
   │  (= Extract + Expand)
   ├── recovery_lookup    계정 조회용 locator
   ├── recovery_auth      복구 자격 증명용
   └── recovery_wrap_key  account_master_key를 감싸는 키

account_master_key (32B, CSPRNG)        복구 문구에서 유도하지 않는다
   │  ① scope_prk = HKDF-Extract-SHA256(salt = PROTOCOL_SALT,
   │                                     IKM  = account_master_key)
   │  ② scope_root_key = HKDF-Expand-SHA256(PRK = scope_prk,
   │                                         info = HKDFInfo(scope-root, scope_ctx),
   │                                         L = 32)
   └── scope_root_key     space/room/worldline 단위
        │  ③ child = HKDF-Expand-SHA256(PRK = scope_root_key,
        │                                info = HKDFInfo(child_label, null), L = 32)
        │     — 여기서 Extract를 다시 수행하지 않는다
        ├── field_aead_key
        ├── checkpoint_aead_key
        ├── attachment_wrap_key
        └── compat_tag_key
```

서버는 `account_master_key` 평문을 보관하지 않는다. `recovery_wrap_key`로 감싼 사본만 둔다.

이 구조의 이점:

- **복구 문구 교체가 전체 재암호화를 요구하지 않는다.** wrapped key 하나만 다시 만들면 된다.
- **새 기기에 master key를 전달할 경로를 만들 수 있다**(§5).
- 복구 문구는 평상시 어디에도 필요하지 않다.

### 3.1 BIP-39의 사용 범위

**BIP-39 표준 seed 생성(PBKDF2, NFKD)을 쓰지 않는다.** wordlist와 checksum만 빌린다.

1. CSPRNG가 16바이트 entropy를 만든다.
2. BIP-39 영어 wordlist와 4비트 checksum으로 12단어를 표현한다. **사람이 적기 위한 인코딩일 뿐이다.**
3. 복구 시 단어와 checksum을 검증하고 **원래 16바이트 entropy로 복원한다.**
4. HKDF의 IKM은 phrase 문자열이 아니라 **이 16바이트다.**

이 규칙이면 NFC/NFKD, 대소문자, 공백 차이가 키 파생 규격에 들어오지 않는다. PBKDF2도 필요 없다. 문서에는 "BIP-39 seed를 만든다"가 아니라 **"BIP-39 mnemonic으로 128비트를 인코딩한다"**로 적는다.

한국어 wordlist는 쓰지 않는다. 유니코드 정규화·유사 자모 문제를 새로 만든다.

### 3.2 고정 protocol salt와 domain separation

**서버에서 받아와야 하는 per-account salt를 두지 않는다.** 초판의 순환은 여기서 비롯됐다. 대신 양쪽 구현에 박아 넣은 고정 `PROTOCOL_SALT`를 쓴다.

- `PROTOCOL_SALT`의 정확한 byte는 UTF-8 `gagaodok/e2ee/v1/hkdf-salt`로 고정한다. 비밀이 아니다.
- 용도 분리는 아래 **완전한 ASCII label**을 HKDF `info`에 넣어 수행한다. 약칭이나 번역문을 쓰지 않는다.

| 용도 | HKDF `info` label |
| --- | --- |
| 계정 조회 | `gagaodok/e2ee/v1/recovery-lookup` |
| 복구 인증 | `gagaodok/e2ee/v1/recovery-auth` |
| master key 복구 봉투 | `gagaodok/e2ee/v1/recovery-wrap` |
| scope root | `gagaodok/e2ee/v1/scope-root` + §7.2 scope context |
| 수정 가능한 field | `gagaodok/e2ee/v1/field-aead` |
| checkpoint | `gagaodok/e2ee/v1/checkpoint-aead` |
| 첨부 file key 봉투 | `gagaodok/e2ee/v1/attachment-wrap` |
| compaction 호환 태그 | `gagaodok/e2ee/v1/compat-tag` |

`scope_root_key`를 AES-GCM과 HMAC에 직접 재사용하지 않는다. 각 하위 키를 위 label로 다시 유도한다. 두 구현은 label의 대소문자·`/`·길이까지 test vector로 검증한다.

#### 전역 표기 규칙 — Extract와 Expand를 섞지 않는다

문서 전체에서 아래 두 표기는 **서로 다른 연산**을 뜻한다. 하나를 다른 하나로 바꿔 구현하면 값이 달라진다.

| 표기 | 뜻 |
| --- | --- |
| `HKDF-SHA256(IKM, salt, info, L)` | RFC 5869 **HKDF-Extract + HKDF-Expand** 전체 |
| `HKDF-Expand-SHA256(PRK, info, L)` | 이미 만들어진 PRK에 대한 **Expand만** 수행 |

§4의 recovery 파생과 §5의 pairing 파생 표에 나오는 `HKDF-SHA256(...)`은 **모두 표준 Extract+Expand**를 뜻한다. 별도 언급이 없으면 `salt = PROTOCOL_SALT`, `L = 32`다.

#### `scope_root_key` 확정 파생식

```text
scope_prk =
    HKDF-Extract-SHA256(
        salt = PROTOCOL_SALT,
        IKM  = account_master_key
    )

scope_root_key =
    HKDF-Expand-SHA256(
        PRK  = scope_prk,
        info = HKDFInfo("gagaodok/e2ee/v1/scope-root", canonical_scope_context),
        L    = 32
    )
```

#### scope 하위 키 확정 파생식

**하위 키에서는 Extract를 다시 수행하지 않는다.** `scope_root_key`는 이미 HKDF 출력이므로 그대로 PRK로 쓴다.

```text
child_key =
    HKDF-Expand-SHA256(
        PRK  = scope_root_key,
        info = HKDFInfo(child_label, null),
        L    = 32
    )
```

대상 `child_label`은 `gagaodok/e2ee/v1/field-aead`, `gagaodok/e2ee/v1/checkpoint-aead`, `gagaodok/e2ee/v1/attachment-wrap`, `gagaodok/e2ee/v1/compat-tag` 네 개다.

Swift `CryptoKit`은 `HKDF.deriveKey(inputKeyMaterial:salt:info:outputByteCount:)`가 Extract+Expand, `HKDF.expand(pseudoRandomKey:info:outputByteCount:)`가 Expand 전용이다. 두 함수를 바꿔 쓰면 §3.5의 vector와 값이 달라지므로 contract test로 고정한다.

`scope-root`의 context는 LP v1로 다음과 같이 고정한다.

| field_id | 값 | type |
| ---: | --- | --- |
| 1 | `account_id` | UUID ASCII |
| 2 | `space_id` | UTF-8 enum string |
| 3 | `room_id` | UUID ASCII |
| 4 | `worldline_id` | nullable UUID ASCII |

`recovery_lookup`, `recovery_auth`, `recovery_wrap_key`와 모든 scope 하위 키의 출력 길이는 32바이트다.

### 3.3 고정 key derivation vector

아래 값은 표준 라이브러리만으로 구현한 독립 스크립트로 계산했다. 계산 전에 **RFC 5869 A.1 test vector로 HKDF 구현 자체를 먼저 검증**했고 null·empty·field ordering도 별도 시험했다. Swift·Kotlin contract test는 이 값을 그대로 기대값으로 사용한다. 저장소의 [`tools/e2ee_contract_vectors.py`](../tools/e2ee_contract_vectors.py), [고정 테스트](../tools/tests/test_e2ee_contract_vectors.py), [공용 artifact](../tools/fixtures/e2ee_contract_vectors.json)로 재현할 수 있다.

2026-08-29 기준 field·recovery·pairing vector를 포함한 공용 artifact의 SHA-256은
`c80a2e5bfa6813ca515d4f5eb71fccab7fab9513dda4296c960c7faf6efa2136`다.
Swift `CryptoKit` 구현(`a0dd551`)과 Android shared `src/main`의 JCA 구현
(`cd0999d`)은 같은 key·AAD·nonce·한글 plaintext에서 동일 envelope byte를
만들고 이를 각각 복호화한다. identity·field·`bubble_order`·algorithm·generation
변조와 non-canonical Base64는 양쪽 모두 fail-closed한다. `19ddf24`는 recovery
HKDF/verifier와 pairing claim/delivery/SAS 파생을 같은 artifact와 양 구현에 추가했다.

**시험 전용 입력이며 실제 배포 키가 아니다.**

| 항목 | 값 | byte |
| --- | --- | ---: |
| `PROTOCOL_SALT` (UTF-8) | `gagaodok/e2ee/v1/hkdf-salt` | 26 |
| `PROTOCOL_SALT` (hex) | `676167616f646f6b2f653265652f76312f686b64662d73616c74` | 26 |
| `account_master_key` | `000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f` | 32 |
| `account_id` | `11111111-1111-4111-8111-111111111111` | 36 |
| `space_id` | `MAC_SPACE` | 9 |
| `room_id` | `22222222-2222-4222-8222-222222222222` | 36 |
| `worldline_id` | null (`presence = 0`) | 0 |

`canonical_scope_context` (LP v1, 115 bytes) — **한 줄로 이어진 값이며 공백을 넣지 않는다**:

```text
47444b3100040001010000002431313131313131312d313131312d343131312d383131312d313131313131313131313131000201000000094d41435f53504143450003010000002432323232323232322d323232322d343232322d383232322d32323232323232323232323200040000000000
```


| 단계 | 결과 hex | byte |
| --- | --- | ---: |
| `scope_prk` | `d6f8acf0397895e14f62491a74bc964c9bee238cf4efab0016a1f5467b211048` | 32 |
| `scope_root_key` | `5633eaf345979da613efa3c7a785a48f5e4c60473ca806f772d79c62cc3d93a0` | 32 |

`HKDFInfo("gagaodok/e2ee/v1/scope-root", canonical_scope_context)` = `LP([1 = UInt16BE(1), 2 = UTF8(label), 3 = canonical_scope_context])` (171 bytes):

```text
47444b3100030001010000000200010002010000001b676167616f646f6b2f653265652f76312f73636f70652d726f6f740003010000007347444b3100040001010000002431313131313131312d313131312d343131312d383131312d313131313131313131313131000201000000094d41435f53504143450003010000002432323232323232322d323232322d343232322d383232322d32323232323232323232323200040000000000
```

scope 하위 키 (모두 `PRK = scope_root_key`, `L = 32`):

| child label | `HKDFInfo` byte | `child_key` hex |
| --- | ---: | --- |
| `gagaodok/e2ee/v1/field-aead` | 56 | `c96df08f1224ca6f8b3e96ac87f1e7d7327a4e5f0ae250c8752656bbe31c793f` |
| `gagaodok/e2ee/v1/checkpoint-aead` | 61 | `45759f66516548d112ef49ef261a49d8c5537f790772322c20afa560312c14bd` |
| `gagaodok/e2ee/v1/attachment-wrap` | 61 | `2368e886dbfacce439bab98ec99c049f0d5130fe2e0eb2bbe6b62fbe72f0068d` |
| `gagaodok/e2ee/v1/compat-tag` | 56 | `8cca8fd82e374d48e585bc3e250d317e0560905004bdd93f458d84f1713da9f4` |

`HKDFInfo(child_label, null)` 예 (`field-aead`, 56 bytes):

```text
47444b3100030001010000000200010002010000001b676167616f646f6b2f653265652f76312f6669656c642d6165616400030000000000
```

**단계를 틀리면 값이 실제로 달라진다.** 같은 스크립트로 확인한 오답이다.

| 잘못된 구현 | 결과 |
| --- | --- |
| `scope_root_key`에서 Extract 생략 | `41362c4745d268b073b701a554541ae2cb727cc2cbb468567c069f4cdd550ba9` — 확정값과 다름 |
| 하위 키에서 Extract 재수행 | `e50588ed325306340210f7af8cf7e87de08fc7ac6be44bf2b36db8065281d350` — 확정값과 다름 |

두 오답 모두 **자기 플랫폼 안에서는 일관되게 동작하므로 domain separation test(§13.7)를 통과한다.** 그래서 이 vector를 고정값으로 박아 두는 것이 유일한 방어다.

### 3.4 왜 PBKDF2·Argon2를 쓰지 않는가

IKM이 **사람이 고른 비밀번호가 아니라 기기가 생성한 128비트 난수**이므로 사전 공격 대상이 아니다. 메모리 하드 KDF는 두 플랫폼에 외부 의존성을 요구하고 파라미터 불일치라는 새 실패 지점을 만든다.

**단, 128비트 미만 입력이나 사용자가 직접 고른 문장을 허용하는 순간 이 판단은 무효가 된다.** 그런 입력을 규격 차원에서 금지한다.

## 4. 계정 복구 (모든 기기 분실)

```text
1. 사용자가 12단어를 입력
2. checksum 검증 → recovery_entropy 복원
3. recovery_lookup·recovery_auth·recovery_wrap_key 유도
4. request body로 recovery_lookup과 recovery_auth 제출
5. 서버가 recovery_auth_verifier를 constant-time 비교
6. 성공 시 account_id·wrapped_master_key·key_generation과 새 device token 반환
7. recovery_wrap_key로 wrapped_master_key 복호화 → account_master_key 획득
```

- `recovery_lookup`은 128비트 이상이어야 하며 계정 존재를 추측하기 어려워야 한다.
- `recovery_auth`는 복구 문구와 같은 급의 bearer credential이다. **요청 body·로그·분석·URL에 절대 남기지 않는다.**
- 서버는 평문 `recovery_auth`를 보관하지 않는다. 다음 32바이트만 저장한다.

```text
recovery_auth_verifier = LabeledHash(
    "gagaodok/e2ee/v1/recovery-auth-verifier",
    recovery_auth
)
```

- `LabeledHash`의 byte 규격은 §7.2에 정의한다. client가 보낸 `recovery_auth`에서 같은 verifier를 계산해 비교한다.
- 복구 endpoint에는 강한 rate limit, 일정한 실패 응답, constant-time 비교를 적용한다.
- 서버는 평문 master key를 어느 단계에서도 보지 않는다.

### 4.1 복구 문구 교체

복구 문구 교체는 `account_master_key`나 콘텐츠의 `key_generation`을 바꾸지 않고 같은 master key를 새 `recovery_wrap_key`로 다시 감싸는 작업이다.

1. 연결된 신뢰 기기에서 기기 재인증을 요구한다.
2. 새 entropy와 문구를 만들고 사용자에게 재입력시켜 checksum과 round-trip을 확인한다.
3. `recovery_version`을 1 올리고 새 lookup·auth verifier·wrapped master key를 만든 뒤, 새 R2 복구 사본을 versioned object로 먼저 올린다.
4. D1 transaction에서 새 recovery record를 삽입·활성화하고 기존 record를 폐기한다.
5. R2 upload나 D1 transaction이 실패하면 기존 record를 그대로 유지한다. D1 전환에 실패해 남은 R2 object는 orphan cleanup 대상으로만 기록한다.

새 문구 확인과 D1 전환이 끝나기 전에는 기존 recovery credential을 폐기하지 않는다. 이 절차는 master key rotation이 아니므로 v1의 `key_generation = 1`은 그대로다.

## 5. 기기 연결 (기존 기기가 남아 있을 때)

**복구 문구는 이 경로에 쓰지 않는다.** 문구 입력은 §4의 전체 분실 복구에서만 필요하다.

QR의 session 승인만으로는 부족하다. QR을 촬영한 다른 사람이 같은 session에 요청할 수 있으므로, 승인을 **정확한 새 기기의 claim**에 묶는다.

```text
1. 기존 기기 재인증 (Touch ID / 기기 자격 증명)
2. 기존 기기가 32B one-time pairing_secret 생성
3. pairing_session_lookup과 pairing_claim_key 유도
4. Worker에 짧은 TTL의 session 생성; QR에는 session_id와 pairing_secret 표시
5. 새 기기가 32B claim_secret과 UUID claim_id 생성
6. 새 기기가 device info·claim_secret을 pairing_claim_key로 암호화해 claim 제출
7. 새 기기는 `claim_redeem_verifier`를 계산해 claim과 함께 제출하고, Worker는 claim_id·claim_lookup·claim ciphertext·redeem verifier를 session에 저장
8. 기존 기기가 인증된 경로로 claim을 받아 복호화
9. 두 기기가 같은 6자리 SAS를 표시하고 사용자가 직접 비교
10. 기존 기기가 일치하는 claim_id를 승인
11. 기존 기기가 그 claim 전용 delivery_key로 master key package를 암호화
12. Worker는 승인된 claim_id·claim_lookup에 package와 device token을 결속
13. 새 기기가 claim_redeem_auth를 request body로 보내면 Worker가 verifier를 constant-time 비교하고, 일치하는 승인 claim을 원자적으로 1회 소비한 뒤 package를 반환한다. 새 기기는 master key를 로컬 복원
```

정확한 파생 규칙:

| 값 | 규칙 |
| --- | --- |
| `pairing_session_lookup` | HKDF-SHA256(`pairing_secret`, `PROTOCOL_SALT`, `gagaodok/e2ee/v1/pairing-session-lookup`, 32B) |
| `pairing_claim_key` | HKDF-SHA256(`pairing_secret`, `PROTOCOL_SALT`, `gagaodok/e2ee/v1/pairing-claim`, 32B) |
| `claim_lookup` | HKDF-SHA256(`claim_secret`, `PROTOCOL_SALT`, `gagaodok/e2ee/v1/claim-lookup`, 32B) |
| `claim_redeem_auth` | HKDF-SHA256(`claim_secret`, `PROTOCOL_SALT`, `gagaodok/e2ee/v1/claim-redeem-auth`, 32B) |
| `joint_secret` | LP v1 `field 1 = pairing_secret`, `field 2 = claim_secret` |
| `pairing_delivery_key` | HKDF-SHA256(`joint_secret`, `PROTOCOL_SALT`, `gagaodok/e2ee/v1/pairing-delivery`, 32B) |
| `pairing_sas_bytes` | HKDF-SHA256(`joint_secret`, `PROTOCOL_SALT`, `gagaodok/e2ee/v1/pairing-sas`, 4B) |

SAS는 `UInt32BE(pairing_sas_bytes) mod 1,000,000`을 앞자리 0을 포함한 6자리 숫자로 표시한다. Worker는 평문 `claim_redeem_auth`를 저장하지 않고 아래 verifier만 저장한다.

```text
claim_redeem_verifier = LabeledHash(
  "gagaodok/e2ee/v1/claim-redeem-verifier",
  LP([
    field 1 = session_id UUID ASCII,
    field 2 = claim_id UUID ASCII,
    field 3 = claim_lookup 32 bytes,
    field 4 = claim_redeem_auth 32 bytes
  ])
)
```

고정 시험 입력 `session_id = 33333333-3333-4333-8333-333333333333`, `claim_id = 44444444-4444-4444-8444-444444444444`, `claim_lookup = 00…1f`, `claim_redeem_auth = 20…3f`에서 verifier는 다음 32바이트다.

```text
9f7c4f2294826ca2618ee42b6bb617dfd1699bb735fcd529c9725007a2bfdc88
```

Verifier는 claim 제출 시 평문 metadata로 등록하지만 256-bit secret의 단방향 hash이며, session·claim·lookup에 결속된다. Worker는 redeem 요청의 `claim_redeem_auth`로 같은 값을 다시 계산해 constant-time으로 비교한다. URL·log·분석 payload에는 auth와 verifier를 넣지 않는다.

**승인은 반드시 key package 생성·배포 이전에 완료되어야 하며, session 전체가 아니라 `claim_id`와 `claim_lookup`에 결속되어야 한다.** 다른 claim이나 session bearer가 승인 결과를 받을 수 없어야 한다.

- pairing session과 claim은 짧은 만료, 1회 사용, 성공·실패 후 즉시 폐기를 적용한다.
- claim payload와 key package의 AAD에는 `session_id`·`claim_id`·`claim_lookup`을 포함한다. Redeem verifier는 AEAD payload가 아니므로 AAD라는 표현을 쓰지 않고, 위 LP hash 입력으로 같은 세 identity에 결속한다.
- claim 제출·승인·redeem의 race, QR 복제, 다른 claim의 package 탈취를 Phase 2 합성 시험으로 검증한다.
- `claim_redeem_auth`는 request body로만 보내고 URL·로그·분석 payload에 남기지 않는다.
- QR payload는 HTTP URL이 아닌 앱 전용 payload로 encode하며 `pairing_secret`을 universal-link query, clipboard, crash log에 남기지 않는다.
- QR을 본 사람은 pairing 요청을 보낼 수 있으므로 QR 화면에 **"주변에 보이지 않게 하십시오"**를 표시한다. SAS 비교를 생략하지 않는다.
- Mac·태블릿·폰 어느 신뢰 기기든 QR을 만들 수 있다. 최초 기준 기기를 특정 플랫폼으로 고정하지 않는다.

### 5.1 Claim ciphertext 접근 통제 계약 (v1 확정)

`claim_secret`은 QR에서 유도되는 `pairing_claim_key` 하나로만 보호된 채 Worker에 저장된다. 따라서 **claim ciphertext를 읽을 수 있는 주체는 `claim_secret`을 얻고, 이어서 `claim_redeem_auth`와 `pairing_delivery_key`를 모두 유도할 수 있다.** SAS는 공격자가 자기 claim을 밀어 넣는 치환을 잡는 장치이므로 이 경로를 막지 못한다. 사용자는 손에 든 진짜 기기의 claim을 정상 승인하고, 훔쳐지는 것은 그 승인 결과다.

v1은 이 경로를 **Worker 접근 통제로 막는다.** 아래는 권고가 아니라 규격이며, Worker 구현이 이를 만족하지 못하면 pairing을 활성화하지 않는다.

1. **Claim 제출은 QR의 session 자격으로 가능하다.** 새 기기는 계정에 아직 연결되지 않았으므로 device token을 요구할 수 없다.
2. **Claim ciphertext 조회와 claim 목록 조회는 해당 계정에 이미 연결된 기기의 유효한 device token으로만 허용한다.**
3. **`pairing_session_lookup`·`session_id`·QR payload만 가진 주체는 claim ciphertext를 읽거나 목록을 조회할 수 없다.** session lookup은 제출 경로의 주소 지정에만 쓰고 조회 권한 근거로 쓰지 않는다.
4. **Claim 제출 응답과 session 조회 응답에 claim ciphertext를 반환하지 않는다.** 제출자는 자기가 보낸 값을 이미 알고 있으므로 되돌려줄 이유가 없다.
5. **기존 기기가 claim을 조회할 때 Worker는 그 device token이 해당 pairing session의 account에 결속되어 있는지 확인한다.** 다른 계정의 유효한 token으로는 조회할 수 없다.
6. **기존 기기의 명시적 승인 이전에는 master key package를 만들지도 배포하지도 않는다.** 승인 전 package 생성 요청은 거부한다.
7. **Key package는 승인된 `claim_id`와 `claim_lookup`에만 결속한다.** session 단위 승인 flag를 두지 않는다.
8. **새 기기는 `claim_redeem_auth`로 자신의 승인된 package만 1회 redeem할 수 있다.** Worker는 claim에 저장된 verifier와 constant-time 비교하고, 성공 시 claim·package를 원자적으로 consumed 상태로 바꾼다. 다른 session·claim에서 가져온 verifier나 auth, 두 번째 redeem, 승인되지 않은 claim은 모두 거부한다.

이 계약이 뜻하는 것을 분명히 해 둔다. **claim payload의 암호화는 두 번째 방어선이고, 첫 번째 방어선은 위 접근 통제다.** 두 방어선이 독립적이지 않다는 점이 §10.7의 비보장 근거다.

### 5.2 v1에 넣지 않는 강화 선택지

아래는 위 접근 통제를 암호학적 보장으로 바꾸는 방법이며 **v1 범위 밖이다.** 향후 위협 모델이 바뀌거나 Worker 접근 통제를 신뢰할 수 없게 되면 재검토한다.

- **별도 `redeem_secret`.** 새 기기가 `claim_secret`과 별개의 secret을 만들어 claim payload에 넣지 않고, 제출 시 `LabeledHash(redeem_secret)` verifier만 평문으로 등록한다. claim ciphertext를 읽은 주체도 redeem할 수 없게 된다. 다만 `pairing_delivery_key`가 `joint_secret` 기반이므로 package 복호화는 여전히 가능하다.
- **Ephemeral ECDH.** 새 기기의 ephemeral 공개키를 claim에 실어 delivery key를 ECDH로 만든다. claim ciphertext 열람만으로는 package를 풀 수 없게 되어 접근 통제 의존이 사라진다. 대신 Swift·Kotlin 양쪽에 새 primitive와 test vector가 늘어난다.

v1이 접근 통제를 택한 이유는 이 앱의 QR pairing이 **사용자가 자기 기기 두 대를 마주 놓고 수행하는 동작**이고, 위 두 선택지가 Phase 1에서 검증해야 할 규격 표면을 넓히기 때문이다.

## 6. `wrapped_master_key` 보관과 `key_generation`

### 6.1 중복 보관

| 위치 | 성격 |
| --- | --- |
| D1 | 현재 recovery record의 사용 사본 |
| R2 | `recovery_version`별 복구용 암호화 사본 |
| 연결된 각 기기 | 기기 key로 감싼 로컬 암호화 사본 |

- 모든 사본에 `key_generation`과 무결성 검증값을 포함한다. D1·R2의 recovery-wrapped 사본에는 별도 `recovery_version`도 포함한다.
- **어느 곳에도 평문 master key를 저장하지 않는다.**
- D1과 R2는 같은 Cloudflare 계정 아래이므로 완전히 독립적인 백업이 아니다. 이 한계를 명시한다.
- D1 Free의 Time Travel은 **키가 오래되면 사라진다는 뜻이 아니라**, 실수로 삭제·손상된 것을 7일 이내에 발견해야 되돌릴 수 있다는 뜻이다. 장기 보존은 R2 export 같은 별도 백업이 담당한다.
- 계정 자체가 사라지는 상황까지 대비하는 사용자 보관용 복구 파일은 초기 범위에 넣지 않는다. **Cloudflare 데이터가 전부 사라지면 복호화할 암호문도 함께 사라지므로**, 키의 보관 내구성은 암호문의 내구성과 같은 수준이면 충분하다. 중복이 실제로 막는 것은 **키 레코드만 손상되는 부분 손실**이다.

### 6.2 v1은 단일 generation만 지원

- v1이 생성하는 모든 master-key 봉투와 콘텐츠 암호문은 **`key_generation = 1`**이다.
- v1 client는 다른 generation을 자동 선택하거나 이전 generation으로 후퇴하지 않고 **지원하지 않는 규격 오류**로 중단한다.
- 같은 generation 1의 사본이 여럿이면 무결성 검증을 통과한 것을 쓴다.
- 실제 master key rotation, 여러 generation keyring, old ciphertext 재암호화 완료 판정과 key 폐기는 v1 범위 밖이다.
- 복구 문구 교체는 같은 master key를 다시 감싸므로 generation을 올리지 않는다.

봉투에 `key_generation`을 지금부터 넣는 이유는 향후 rotation 도입 시 기존 암호문 형식을 다시 바꾸지 않기 위해서다. v1에서 rotation을 지원하는 것처럼 안내해서는 안 된다.

## 7. 레코드 암호화

- 알고리즘: **AES-256-GCM**
  - Swift: CryptoKit `AES.GCM` — `Package.swift`의 `.macOS(.v14)`에서 사용 가능
  - Kotlin: `javax.crypto.Cipher "AES/GCM/NoPadding"` — `minSdk = 26`에서 사용 가능
  - 두 플랫폼 모두 내장이므로 새 의존성이 없다.
- nonce: 레코드마다 **12바이트 CSPRNG 난수.** 같은 키에서 재사용 금지.
- 인증 태그: 16바이트.
- scope별 하위 키(§3)로 nonce 충돌 범위와 사고 범위를 제한한다.

### 7.1 봉투 형식

```text
[0]      version         UInt8   (0x01)
[1]      alg             UInt8   (0x01 = AES-256-GCM)
[2..5]   key_generation  UInt32  big-endian
[6..17]  nonce           12 bytes
[18..]   ciphertext || tag
```

텍스트 컬럼에 넣을 때는 **표준 base64(패딩 포함, URL-safe 아님)**로 감싼다. 이 선택을 규격에 못 박는다.

`key_generation`은 1바이트가 아니라 `UInt32`로 둔다. 확장 여지를 남기고 정렬을 단순하게 한다.

### 7.2 AAD — canonical binary encoding

두 구현이 선택할 여지를 남기지 않는다. canonical CBOR는 사용하지 않고 다음 **LP v1** 형식 하나만 사용한다.

```text
header:
  magic       4 bytes   ASCII "GDK1" (47 44 4B 31)
  item_count  UInt16BE

item (field_id 오름차순, 중복 금지):
  field_id    UInt16BE
  presence    UInt8     0 = null/부재, 1 = present
  length      UInt32BE
  value       length bytes
```

- `presence = 0`이면 `length`는 반드시 0이다.
- present empty value는 `presence = 1, length = 0`이므로 null과 구별된다.
- integer는 명시된 고정 폭의 big-endian, boolean은 0 또는 1의 UInt8이다.
- UUID는 기존 `Codec.kt` 계약과 같은 **대문자 하이픈 36-byte ASCII**다.
- 문자열은 UTF-8, BOM 없음이며 별도 Unicode 정규화를 하지 않는다.
- 알 수 없는 `field_id`, 순서가 뒤집힌 item, 중복 item, 잘못된 길이는 fail closed로 거부한다.

고정 encoding vector:

```text
LP([
  field 1 = present bytes 00 01,
  field 2 = null,
  field 3 = present UTF-8 "A"
])
= 47444b310003000101000000020001000200000000000003010000000141
```

AAD field는 다음 순서와 type으로 고정한다.

| field_id | 이름 | type |
| ---: | --- | --- |
| 1 | `protocol_version` | UInt16BE, v1 = 1 |
| 2 | `key_generation` | UInt32BE, v1 = 1 |
| 3 | `account_id` | UUID ASCII |
| 4 | `space_id` | UTF-8 enum string |
| 5 | `room_id` | UUID ASCII |
| 6 | `worldline_id` | nullable UUID ASCII |
| 7 | `entity_type` | UTF-8 ASCII identifier |
| 8 | `entity_id` | UTF-8 canonical identifier |
| 9 | `field_path` | nullable UTF-8 path |
| 10 | `bubble_order` | nullable UInt64BE |
| 11 | `recovery_version` | nullable UInt32BE |
| 12 | `alg` | UInt8, v1 = `0x01` |

`alg`(field 12)는 §7.1 봉투의 `alg` byte와 **같은 값이어야 한다.** 봉투의 `version`·`key_generation`은 field 1·2로 이미 인증되지만 `alg`는 그렇지 않았다. v1에서는 `0x01` 하나뿐이라 실질 위험이 없으나, 알고리즘을 추가할 때 downgrade 여지를 남기지 않으려면 지금 결속해 두어야 형식을 다시 바꾸지 않는다.

- **v1은 `alg = 0x01`(AES-256-GCM)만 허용한다.**
- 다른 값을 만나면 **복호화를 시도하기 전에** fail closed로 거부한다. AEAD 실패에 기대지 않는다.
- 기존 field를 재번호 매기지 않고 12번을 새로 붙였다. 이미 확정한 field 1~11의 LP byte와 §3.3 vector가 그대로 유지된다.

`entity_type`을 넣어 room·profile·checkpoint·attachment의 UUID가 우연히 겹치는 경우를 막는다. `bubble_order`는 최초 canonical import 후 불변이므로 bubble payload에 포함한다.

Recovery-wrapped master key는 room·space에 속하지 않으므로 일반 field AAD에
가짜 `space_id`·`room_id`를 넣지 않는다. 다음 account-wide LP AAD를 사용하고,
봉투 header는 §7.1과 동일하다.

| field_id | recovery AAD 값 | type |
| ---: | --- | --- |
| 1 | `protocol_version` | UInt16BE |
| 2 | `account_id` | UUID ASCII |
| 3 | `recovery_lookup` | 32 bytes |
| 4 | `recovery_version` | UInt32BE, 1 이상 |
| 5 | `key_generation` | UInt32BE, v1 = 1 |
| 6 | payload type `recovery_wrapped_master_key` | UTF-8 ASCII |
| 7 | `alg` | UInt8, v1 = `0x01` |

`recovery_lookup`을 AAD에 넣어 lookup record와 wrapped key의 교체를 막고,
`recovery_version`으로 문구 교체 전후 record를 구분한다. account-wide AAD의
Swift·Kotlin exact envelope는 공용 artifact의 `recovery` section이 고정한다.

Pairing claim과 delivery package는 account 내용을 복호화하기 전에도 계산할 수 있도록 다음 별도 LP AAD를 사용한다.

| field_id | pairing AAD 값 | type |
| ---: | --- | --- |
| 1 | `protocol_version` | UInt16BE |
| 2 | `session_id` | UUID ASCII |
| 3 | `claim_id` | UUID ASCII |
| 4 | `claim_lookup` | 32 bytes |
| 5 | payload type (`claim` 또는 `delivery`) | UTF-8 ASCII |
| 6 | `alg` | UInt8, v1 = `0x01` |

HKDF와 hash의 domain separation도 LP v1을 사용한다.

```text
HKDFInfo(purpose, context_or_null) = LP([
  field 1 = UInt16BE(protocol_version),
  field 2 = UTF8(purpose),
  field 3 = context_or_null
])

LabeledHash(label, payload) = SHA-256(LP([
  field 1 = UTF8(label),
  field 2 = payload
]))
```

앞 절 표의 `HKDF(..., label, ...)`은 실제 구현에서 `HKDFInfo(label, null)`을 뜻한다. scope·claim처럼 context가 필요한 경우 field 3에 해당 LP byte를 넣는다. label 원문과 context field 구성을 고정 test vector로 검증한다.

**`revision`·`base_revision`·`server_seq`·timestamp는 AAD에 넣지 않는다.** 넣으면 내용이 바뀌지 않은 field까지 동기화마다 재암호화해야 한다. 대가는 §10에 기록한다.

## 8. 암호화 범위와 평문 경계

### 8.1 단위별 방식

| 대상 | 방식 | 근거 |
| --- | --- | --- |
| `set`/`clear`로 수정되는 room·profile 필드 | **per-field 암호화 필수** | 레코드를 통째로 암호화하면 Mac이 복호화 → 자기 모델로 해석 → 재암호화하면서 Android 전용 필드를 잃는다. 합의문 §16의 위험이 그대로 되살아난다 |
| 완결된 checkpoint snapshot | 전체 payload 암호화 가능 | 단, 아래 조건 |
| 첨부 | file 또는 chunk 단위 | §9 |
| tombstone | 별도 동기화 연산 | 암호화 대상 아님 |

**checkpoint 전체 payload 암호화 조건:** 모든 클라이언트가 unknown field를 opaque하게 왕복 보존할 수 있을 때만 허용한다. 그렇지 않으면 호환 가능한 canonical 필드와 extension을 분리하거나 per-field 암호화를 쓴다. checkpoint는 `base_revision` CAS로 연장될 수 있으므로, 연장하는 기기가 모르는 확장 필드가 있으면 같은 소실이 일어난다.

### 8.2 암호화 대상

sender, kind, text, canonicalText, persona 전체(`description`·`samples`·`styleGuide`·`suppressedExpressions`·`sampleEvidence`), profile 표시값(`title`·`statusMessage`·`musicTitle`·`musicArtist`), heart delta와 reason, checkpoint segment text와 summary, attachment filename·MIME·content, avatar 이미지, **그리고 `mode`·`modelIdentifier`·`engineProfile`·`compactionProfileId`·`compactionContractFingerprint`의 실제 값.**

Group·message 안에서 다른 room/character를 가리키는 `GroupParticipant.roomId`, `ParticipantHeart.participantRoomId`, `ChatMessage.speakerRoomId`, `MessageReaction.participantRoomId`, `MessageHeartChange.participantRoomId`의 **참조 값도 암호화한다.** entity 자체의 canonical `room_id`·향후 `character_id`는 identity metadata로 평문이지만, 이 다섯 값은 관계 graph이므로 content field로 취급한다.

`GroupChatState.activeWorldlineId`도 현재 선택 상태이므로 암호화한다. 각 message write가 평문 canonical `worldline_id`를 명시하므로 서버가 active 값 자체를 읽을 필요는 없다. 다만 평문 scope와 timestamp를 관찰하면 서버가 최근 active worldline을 추론할 수 있으므로 이 암호화가 선택 상태를 완전히 숨긴다고 보장하지 않는다.

### 8.3 평문으로 남는 것

canonical identity(`space_id`·`room_id`·`worldline_id`·`turn_id`·`message_id`), `bubble_order`, `revision`/`base_revision`, `server_seq`, `operation_id`, tombstone 표시, timestamp, 암호문과 R2 객체의 byte size, `import_batch_id`, `recovery_lookup`, `key_generation`.

**초판의 "식별자·순번·시각만"은 부정확했다.** 정확한 표현은 **"내용은 모두 암호화하되, 서비스 동작상 불가피한 metadata만 최소한으로 평문 유지"**다.

### 8.4 호환성 판정용 평문 태그

서버가 checkpoint 호환성의 equality만 비교해야 한다면 실제 fingerprint 대신 다음을 평문으로 둔다.

```text
compaction_compat_tag = HMAC-SHA256(compat_tag_key, canonical_compaction_contract)
```

같은 scope 안에서 같음/다름만 드러내고 실제 mode·model 이름은 드러내지 않는다.

### 8.5 metadata 노출 명시

- `clear`의 field path는 서버가 무엇을 지울지 알아야 하므로 **평문이다.** 값은 새지 않지만 **어떤 필드가 언제 변경됐는지는 서버에 보인다.**
- timestamp를 평문으로 두는 것은 사용자 결정 17에 따른 v1 선택이다. **대화 시각 분포와 빈도가 노출된다.** `server_seq`는 순서를 나타내지만 실제 시각을 대체하지 못한다. `lastMessageTime`은 평문 timestamp의 max로 계산하고 별도의 콘텐츠 평문을 만들지 않는다.
- 첨부 byte size는 R2 객체 크기에서 어차피 드러난다.

## 9. 첨부

### 9.1 봉투 암호화

```text
file_key = CSPRNG(32B)
R2 객체 = AES-256-GCM(file_key, 파일 바이트)
레코드 = AES-256-GCM(attachment_wrap_key, file_key)  ← 감싼 키
R2 객체 이름 = 내용과 무관한 난수 UUID
```

§1.3의 2번 규칙(Worker 경유 접근 통제)이 그대로 적용된다. 암호화는 두 번째 방어선이다.

**base64 인라인 첨부는 D1에 넣지 않는다.** 행당 2MB 제한 때문이며 결정 2와 일치한다.

### 9.2 크기 처리 — Phase 0 실측값 반영

Mac 입력 경로에는 현재 명시적 첨부 크기 상한이 없다. 큰 파일 전체를 한 번의 AES-GCM 호출로 처리하면 메모리와 중단 재개를 보장할 수 없다.

[Phase 0 inventory](2026-08-27-phase0-inventory-result.md)(`0966b65`)의 안전한 집계 결과는 다음과 같다. 실제 대화 archive는 이 문서를 쓰며 열지 않았고 아래 수치만 입력으로 사용했다.

| 항목 | Mac | Android phone | Tablet |
| --- | ---: | ---: | --- |
| 최대 첨부 | 2,618,357 bytes | 157,678 bytes | 174,199 bytes |
| 최대 avatar | 1,391,214 bytes | 6,593,776 bytes | 274,146 bytes |

**관측된 값은 모두 12MB 미만이다. 그러나 이것은 영구적인 전체 상한의 증명이 아니다.**

- **Mac 앱 자체에 첨부 상한이 없다.** 오늘 관측된 최대값은 "지금까지 사용자가 넣은 것 중 가장 큰 것"이지 "앞으로 들어올 수 있는 것의 한계"가 아니다. 내일 100MB 파일이 들어올 수 있다.

따라서 상한은 관측값이 아니라 **규격으로 정한다.**

- **v1은 양 플랫폼 공통 12MB 상한을 규격으로 둔다.** Mac 입력 경로에도 이 상한을 실제로 적용해야 하며, 상한이 없는 현재 동작을 그대로 두고 상한을 문서에만 적는 것은 안 된다.
- 상한 초과 파일은 **명시적으로 제외하고 사용자에게 알린다.** 방 전체를 조용히 누락하거나 업로드 중에 실패하는 것은 금지한다.
- 세 source space의 현재 데이터는 모두 12MB 미만이지만, 이는 기존 데이터 import 예외가 관측되지 않았다는 뜻일 뿐 미래 입력 상한을 대신하지 않는다.

**avatar도 첨부와 같은 경로로 다룬다.** phone의 최대 avatar가 6,593,776 bytes로 **관측된 최대 첨부(2,618,357 bytes)보다 2.5배 크다.** avatar를 "작은 이미지"로 가정하고 첨부와 다른 경로에 두면 R2 업로드·암호화·메모리 시험이 가장 큰 실제 payload를 놓친다. R2 저장, AEAD 처리, 메모리 contract test 대상에 attachment와 avatar를 **함께** 넣는다.

chunked AEAD를 구현할 경우 규격:

- 고정 크기 chunk마다 독립 nonce와 인증 태그
- AAD에 attachment id, chunk index, total chunks 또는 final marker를 묶는다
- chunk 크기와 nonce 생성 규칙을 Swift·Kotlin 공통 계약으로 고정
- 중단 시 완료 chunk만 재사용하고, 최종 manifest 검증 전에는 객체를 완료 상태로 노출하지 않는다

12MB 상한 안에서도 6.59MB avatar를 한 번의 AES-GCM 호출로 처리할 때의 최대 메모리 사용량은 아직 측정하지 않았다. Phase 2에서 실제 크기로 측정한 뒤 단일 호출 유지와 chunked 도입 중 하나를 정한다.

## 10. 명시적 비보장 항목

v1이 방어하지 **않는** 것을 사용자와 문서에 분명히 남긴다.

1. **악의적 서버의 rollback.** AAD에서 `revision`을 뺐으므로, 서버가 옛 ciphertext를 새 revision 자리에 놓거나 옛 키와 옛 암호문을 짝 맞춰 되돌리면 클라이언트가 탐지하지 못한다. 위협 모델을 "내용을 읽으려 하지만 데이터를 악의적으로 변조하지는 않는 서버"로 제한한 결과다.
   - 기존 기기가 마지막으로 본 revision·generation을 로컬에 기억하면 그 기기에서는 부분적으로 탐지할 수 있으나, **새 기기나 전체 복구 후에는 비교 기준이 없다.** 완전한 방어에는 hash chain이나 신뢰 가능한 checkpoint 전달 규격이 필요하며 v1 범위 밖이다.
2. **악의적 서버의 삭제·숨김·operation 조작.** tombstone과 operation metadata는 평문이며 별도 client signature/MAC을 두지 않는다. 서버가 레코드를 숨기거나 거짓 tombstone을 주입하면 v1 client가 진짜 device operation과 구별하지 못할 수 있다. AAD는 ciphertext를 다른 identity로 옮기는 조작은 막지만 서버의 suppression·삭제 주입까지 증명하지 않는다.
3. **분실 기기의 기존 로컬 데이터와 v1 단일 generation 한계.** device token 폐기는 정상 서버 경로의 추가 접근만 막는다. 분실 기기에 이미 저장된 대화와 master key는 원격으로 지울 수 없다. v1은 실제 master key rotation을 지원하지 않으므로, 분실 기기가 다른 경로로 이후 generation-1 ciphertext를 얻으면 기존 key로 읽을 수 있다. 향후 rotation을 구현해도 이미 내려받은 옛 로컬 사본까지 지울 수는 없다.
4. **기기 내부 데이터.** 로컬 JSON은 평문이다. 보호 범위는 클라우드 동기화 사본이다.
5. **metadata.** §8.5의 노출 항목.
6. **복구 문구 분실.** 클라우드 사본을 영구히 읽을 수 없다. 로컬 데이터는 무관하다.
7. **QR 유출과 claim ciphertext 열람이 동시에 일어나는 경우.** `claim_secret`은 QR에서 유도되는 키로만 보호되므로, QR을 본 주체가 어떤 경로로든 claim ciphertext를 함께 읽으면 `claim_redeem_auth`와 `pairing_delivery_key`를 모두 유도해 **승인된 정상 claim의 key package를 가로챌 수 있다.** v1은 이를 §5.1의 Worker 접근 통제로 막으며 **암호학적으로 막지 않는다.** 따라서 Worker 접근 통제 결함, claim record 유출, 서버 측 저장소 노출이 QR 유출과 겹치면 방어가 없다. SAS는 claim 치환을 잡는 장치이므로 이 경로를 탐지하지 못한다. 암호학적 보장이 필요해지면 §5.2의 강화 선택지를 도입한다.
8. **현재 worldline 추론.** `activeWorldlineId` 값 자체는 암호화되지만 message write의 canonical `worldline_id`와 timestamp는 routing metadata로 평문이다. 서버는 최근 write 분포로 현재 선택된 worldline을 추론할 수 있으며 v1은 traffic-analysis 방어를 제공하지 않는다.

## 11. 기기 키 보관

- **macOS**: Keychain의 `ThisDeviceOnly` 계열 접근성으로 master key 또는 wrapping key를 저장하고 iCloud 동기화를 끈다.
- **Android**: Android Keystore의 non-exportable AES wrapping key로 master key blob을 감싸 저장한다. **`EncryptedSharedPreferences`는 현재 deprecated이므로 새 E2EE 키 저장에 쓰지 않는다.** 프로젝트가 아직 쓰는 `security-crypto:1.1.0-alpha06`의 transitive Tink에도 기대지 않는다. Auto Backup에서 blob과 legacy encrypted preferences를 제외한다.
- 기기 백업 복원 뒤 Keystore key가 없으면 **조용히 새 키를 만들지 말고** "복구 문구 또는 기존 기기 QR이 필요함" 상태로 전환한다.

## 12. 정규화와 인코딩 규격

키 유도 입력이 raw 16바이트 entropy이므로 **문구 문자열 정규화는 키 파생 규격에서 빠진다.** 남는 정규화 대상은 다음뿐이다.

1. 단어 입력을 검증할 때만 앞뒤 공백 제거, 단어 사이 단일 U+0020, 소문자화, NFC를 적용한다. **이 결과는 wordlist 조회에만 쓰이고 키 유도 입력이 되지 않는다.**
2. HKDF `info` label과 AAD 요소는 UTF-8, BOM 없음.
3. UUID는 **대문자 하이픈 형식**으로 통일한다(기존 `Codec.kt` 규약과 일치).
4. AAD·`info`는 §7.2의 length-prefix canonical encoding을 쓴다. 구분자 문자에 의존하지 않는다.
5. base64는 표준(패딩 포함, URL-safe 아님).

메시지 본문은 바이트를 그대로 암·복호화하므로 정규화 대상이 아니다.

## 13. Contract test (Phase 1 필수)

1. **raw entropy ↔ 12단어 왕복**과 checksum 검증 고정
2. **고정 test vector** — 주어진 entropy·nonce·평문에 대한 기대 ciphertext를 hex로 문서에 박고 양 구현이 동일 결과를 내는지 확인
3. **교차 복호** — Swift가 암호화한 것을 Kotlin이, Kotlin이 암호화한 것을 Swift가 푼다
4. **AAD 불일치 거부** — entity id·field path·`bubble_order`·`key_generation`·`alg`를 바꾼 ciphertext는 실패해야 한다
5. **`alg` 변조 거부** — 봉투의 `alg`를 `0x01` 외의 값으로 바꾸면 **복호화를 시도하기 전에** 거부한다. 봉투 `alg`와 AAD field 12가 어긋나는 경우도 거부한다
6. **LP v1 byte 동일성** — §7.2 고정 vector, null/empty, optional bubble order, UUID, 잘못된 길이를 양쪽에서 동일 처리
7. **HKDF domain separation** — 같은 root key에서도 field·checkpoint·attachment·compat·pairing label의 결과가 모두 다름
8. **HKDF 단계 고정** — §3.3의 `scope_prk`·`scope_root_key`·child key 4개를 hex 기대값과 대조한다. **바로 위 7번(domain separation)만으로는 Extract 생략이나 재수행을 잡지 못하므로 이 시험이 별도로 필요하다**(§3.3의 오답 표 참조)
9. **QR claim binding** — QR 복제·동시 claim·다른 claim redeem·SAS 불일치·승인 전 package 요청을 거부
10. **claim ciphertext 접근 통제**(§5.1) — §14 Phase 2의 9개 negative test를 contract 수준에서도 고정
    - claim 제출 시 redeem verifier 등록, session·claim·lookup 결속, constant-time 비교, 원자적 1회 소비를 포함한다
11. **recovery verifier와 문구 교체** — 평문 auth 미저장, verifier 비교, R2/D1 중간 실패 시 기존 recovery record 유지
12. **한글 문자열 왕복** — 조합형·완성형이 섞인 입력이 정확히 복원되어야 한다
13. **fail closed 검증** — 키가 없을 때 평문이 저장되지 않음
14. **persona Codable 하위호환** — 새 필드가 없는 옛 JSON이 정상적으로 읽혀야 한다
15. **generation 규칙** — v1이 1 이외 generation을 거부하고 자동 후퇴하지 않음
16. **비파괴 importer 결합** — 암호화는 업로드 경로에서만 일어나고 원본 로컬 파일의 byte·mtime·hash가 변하지 않는다
17. RFC 5869 test vector로 HKDF 구현 검증

## 14. Phase gate 보정

### Phase 1

- raw 16바이트 entropy ↔ mnemonic 왕복과 checksum
- account lookup / auth verifier / wrapped master key schema와 recovery record 교체 절차
- LP v1 canonical HKDF·AAD·envelope byte encoding과 `key_generation = 1`, AAD field 12 `alg`
- scope·field·checkpoint·attachment·compat·pairing의 exact HKDF label과 **Extract/Expand 단계**(§3.2)
- Swift·Kotlin 고정 test vector — §3.3의 key derivation vector 포함
- **§5.1 claim ciphertext 접근 통제를 Worker API 계약으로 명문화** (조회 권한, 응답 body에서 ciphertext 제외)
- claim 제출 schema에 `claim_redeem_verifier`를 포함하고, redeem endpoint의 constant-time 비교·원자적 1회 소비 계약을 고정
- Mac 입력 경로의 12MB 첨부 상한 적용 방식(§9.2)
- persona Codable 하위호환 계약
- 복구 문구 생성·재입력 확인 UX

### Phase 2 (합성 데이터)

- QR pairing의 1회 사용·만료·replay·폐기 시험
- **승인 이전에 키가 배포되지 않고 승인된 claim만 redeem함**을 검증
- QR 복제자가 만든 별도 claim, claim race, SAS 불일치, 다른 claim의 package 탈취를 거부
- **§5.1 claim ciphertext 접근 통제 시험** — 아래 9개는 모두 거부·부재 또는 원자적 단일 성공을 확인하는 negative test다
  1. QR bearer(`pairing_session_lookup`·`session_id`만 보유)의 claim ciphertext GET 거부
  2. QR bearer의 claim 목록 조회 거부
  3. 유효한 device token으로 **다른 claim**의 ciphertext 조회 거부
  4. 해당 계정에 연결되지 않은 device token의 조회 거부
  5. 승인 전 key package 생성·조회 거부
  6. 승인되지 않은 claim의 redeem 거부
  7. claim 제출 응답과 session 조회 응답에 claim ciphertext가 **포함되지 않음**을 확인
  8. 다른 session·claim의 verifier 또는 잘못된 `claim_redeem_auth`로 redeem 거부
  9. 같은 승인 claim의 동시·반복 redeem 중 정확히 하나만 성공
- 6.59MB avatar와 2.6MB 첨부를 실제 크기로 R2 업로드·암호화하며 최대 메모리 사용량 측정(§9.2)
- 복구 문구만으로 새 synthetic device가 wrapped master key를 복원하는 dry run
- field patch·tombstone·checkpoint가 암호화 payload에서도 보존되는 contract test
- chunked attachment 중단·재개·태그 변조·순서 바꿈 거부 시험(구현하는 경우)

### Phase 3 (실데이터 이전 필수)

- **복구 문구 재입력 완료를 확인하지 않으면 업로드 금지**
- Phase 0 인벤토리의 최대 첨부 크기 결과에 따른 상한 또는 chunked 결정
- hash manifest 3분리(아래)와 outbox ciphertext 재사용 증명
- server·Worker·R2·log에 평문·문구·auth secret이 남지 않음을 검증
- 기기 폐기 후 token 거부 확인과 "폐기된 기기의 기존 로컬 사본은 원격으로 지울 수 없음" 안내

### hash manifest 3분리

| 이름 | 대상 | 보관 |
| --- | --- | --- |
| `local_raw_hash` | 원본 파일 byte | 로컬 전용. importer 비파괴성 검사 |
| `canonical_plain_hash` | importer가 만든 canonical 평문 | 로컬 전용. **서버에 올리지 않는다** |
| `ciphertext_hash` | outbox에 고정 저장한 암호문 byte | 업로드·다운로드 byte 동일성 검사 |

랜덤 nonce 때문에 **같은 평문을 다시 암호화한 결과끼리 비교하면 안 된다.** durable outbox에 최초 생성한 ciphertext와 nonce를 저장하고, 같은 `operation_id`의 재시도는 그 바이트를 재사용한다. 내려받은 뒤 복호화해 canonical hash를 로컬에서 비교해야 end-to-end 검증이 된다.

## 15. 초판 대비 변경 목록

| 항목 | 초판 (`3b449dc`) | 개정본 |
| --- | --- | --- |
| 키 계층 | 문구 → `content_key` 직접 유도 | 무작위 `account_master_key` + recovery-wrapped key |
| 계정 조회 | `account_salt`를 서버에서 받음 (순환) | `recovery_lookup` + 고정 `PROTOCOL_SALT` |
| 새 기기 키 전달 | 없음 | QR `pairing_secret` + claim secret + SAS, claim 승인 후 1회 배포 |
| BIP-39 | 문구 문자열을 NFC로 HKDF에 투입 | wordlist·checksum만 사용, raw 16바이트를 IKM으로 |
| AAD | 구분자 문자열 이어붙이기, message 중심 | LP v1 exact binary grammar, entity별 |
| `key_generation` | 미포함 | 봉투·AAD·wrapped key에 포함, v1은 1만 지원 |
| 암호화 단위 | 명시 없음 | per-field / whole-payload / chunk 구분 |
| engine·compaction profile | 미결 | 암호화, 필요 시 keyed compat tag만 평문 |
| 첨부 크기 | 언급 없음 | Phase 0 결과에 따른 상한 또는 chunked AEAD |
| Android 키 보관 | `EncryptedSharedPreferences` 언급 | Android Keystore |
| 비보장 항목 | 없음 | §10 신설 |
| 로컬 평문 | 암시 | 명시 |

## 16. 남은 미결

3차 보정의 R1(§5.1 접근 통제)·R2(§3.2 HKDF 단계)·`alg` AAD 결속을 Codex가 독립 재현했다. 4차 통합에서 claim redeem verifier의 등록·identity 결속·원자적 1회 소비 절차와 Tablet 실측값을 보완했다. **기술 계약 검토가 완료됐다는 뜻일 뿐 구현·Cloudflare 생성·실데이터 업로드 승인은 아니다.**

### 16.1 아직 측정하거나 구현 검증하지 않은 값

- 6.59MB avatar를 단일 AES-GCM 호출로 처리할 때의 최대 메모리 사용량
- Worker가 10ms CPU 제한 안에서 동작하는지
- D1·R2 실사용량과 무료 한도 여유
- 암호화 구현이 실제로 교차 호환되는지 — §13이 통과해야 확인된다

### 16.2 규격은 정했으나 아직 구현하지 않은 것

- §5.1 접근 통제는 **Worker 구현이 지켜야 성립한다.** 문서만으로는 보장되지 않으며 §14 Phase 2의 9개 negative test로 확인한다
- Mac 입력 경로에는 현재 첨부 상한이 없다. 12MB 상한을 실제 코드에 적용하는 작업이 남아 있다
- §3.3 vector를 Swift·Kotlin contract test fixture로 옮기는 작업

### 16.3 의도적으로 v1 범위 밖에 둔 것

- master key rotation과 다중 generation keyring (§6.2)
- pairing의 별도 `redeem_secret`과 ephemeral ECDH (§5.2)
- chunked AEAD — 12MB 상한 안에서 단일 호출로 충분한지 Phase 2 측정 후 결정 (§9.2)

이 값들이 나오기 전에 Phase 3으로 넘어가지 않는다.
