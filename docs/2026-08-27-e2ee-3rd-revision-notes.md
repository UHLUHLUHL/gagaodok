# E2EE 제안서 3차 보정 설명

> **검토 이력 문서:** 이 문서는 `c327650` 작성 시점의 상태를 보존한다. 현재 판정과 후속 보정은 [E2EE 제안서](2026-08-27-sync-encryption-proposal.md)와 [Codex 통합 검토](2026-08-27-e2ee-codex-integration-review.md)를 따른다.

## 문서 상태

- 작성일: 2026-08-27
- 작성: Claude Code (Codex 배정 작업)
- 대상: [E2EE 설계 제안서](2026-08-27-sync-encryption-proposal.md) 3차 보정
- 상태: **E2EE 3차 보정 작성 완료 / Codex 통합 검토 대기 / 구현 승인 아님 / Cloudflare 리소스 생성·앱 코드 구현·실데이터 업로드 승인 아님**
- 이 보정에서 앱 코드·실제 대화 archive·Cloudflare 리소스를 열거나 변경하지 않았다. Phase 0 결과는 `0966b65`의 집계 수치만 입력으로 읽었다.

이 문서는 3차 보정에서 **무엇을 왜 바꿨는지**와 **고정 vector를 어떻게 재현하는지**를 설명한다. 설계 근거 본문은 제안서에 있다.

## 1. R1 — QR pairing 접근 통제 (선택지 a 채택)

### 무엇이 문제였나

`claim_secret`은 QR에서 유도되는 `pairing_claim_key` 하나로만 보호된 채 Worker에 저장된다. 그 암호문을 읽을 수 있는 주체는 `claim_secret`을 얻고, 이어서 `claim_redeem_auth`(redeem 자격)와 `pairing_delivery_key`(package 복호화)를 **둘 다** 유도할 수 있다.

6자리 SAS는 이 경로를 막지 못한다. SAS는 공격자가 *자기 claim을 밀어 넣는* 치환을 잡는 장치인데, 이 시나리오에서 사용자는 손에 든 진짜 기기의 claim을 정상 승인한다. 훔쳐지는 것은 그 승인 결과다.

### 어떻게 처리했나

사용자 결정에 따라 **(a) Worker 접근 통제를 규격으로 명시**했다. 제안서에 §5.1을 신설하고 8개 조항을 규격으로 못 박았다. 핵심은 다음 세 가지다.

- claim ciphertext와 claim 목록 **조회**는 계정에 이미 연결된 기기의 device token으로만 가능하다. `pairing_session_lookup`·`session_id`·QR payload 보유는 조회 권한 근거가 되지 않는다.
- claim **제출**은 QR session 자격으로 가능하다. 새 기기는 아직 device token이 없기 때문이다. 제출과 조회의 권한이 다르다는 점이 이 계약의 요지다.
- 제출 응답과 session 조회 응답에 claim ciphertext를 **넣지 않는다.** 제출자는 자기가 보낸 값을 이미 알고 있으므로 되돌려줄 이유가 없다.

§10에 비보장 7번을 추가해 **v1이 이 경로를 암호학적으로 막지 않는다**는 사실을 명시했다. Worker 접근 통제 결함·claim record 유출·서버 저장소 노출이 QR 유출과 겹치면 방어가 없다.

§5.2에 향후 강화 선택지(별도 `redeem_secret`, ephemeral ECDH)를 기록하되 **v1 범위 밖**임을 분명히 했다.

### 검증 방법

§14 Phase 2에 7개 negative test를 추가했다. 모두 "거부되는지" 또는 "응답에 없는지"를 확인하는 시험이다.

1. QR bearer의 claim ciphertext GET 거부
2. QR bearer의 claim 목록 조회 거부
3. 유효한 device token으로 다른 claim의 ciphertext 조회 거부
4. 계정에 연결되지 않은 device token의 조회 거부
5. 승인 전 key package 생성·조회 거부
6. 승인되지 않은 claim의 redeem 거부
7. claim 제출·session 조회 응답에 claim ciphertext 부재 확인

§13에도 같은 항목을 contract 수준으로 고정했다(13.10).

## 2. R2 — HKDF Extract/Expand 단계 확정

### 무엇이 문제였나

§3.2 한 문장만 "HKDF-expand"라고 쓰고 나머지 파생은 모두 `HKDF-SHA256(ikm, salt, info, L)` 형태였다. 두 연산은 결과가 다르다. Swift `CryptoKit`은 `deriveKey`(Extract+Expand)와 `expand`(Expand 전용)를 모두 제공하고 Kotlin은 통상 직접 구현하므로, **양쪽이 문서에 성실히 따라도 다른 키가 나올 수 있었다.**

### 어떻게 처리했나

§3.2에 전역 표기 규칙을 넣었다.

| 표기 | 뜻 |
| --- | --- |
| `HKDF-SHA256(IKM, salt, info, L)` | RFC 5869 Extract + Expand 전체 |
| `HKDF-Expand-SHA256(PRK, info, L)` | 이미 만들어진 PRK에 대한 Expand만 |

§4 recovery 표와 §5 pairing 표의 `HKDF-SHA256(...)`은 모두 표준 Extract+Expand를 뜻한다고 명시했다.

`scope_root_key`는 Extract 후 Expand, scope 하위 키는 **Extract를 다시 하지 않고 Expand만** 수행하는 것으로 확정했다. §3의 키 계층 다이어그램도 이 단계 구분이 보이도록 다시 썼다.

### 왜 시험만으로는 부족한가

기존 §13의 domain separation 시험은 "같은 root에서 label이 다르면 결과가 다른가"만 확인한다. **Extract를 생략한 구현도 자기 안에서는 일관되므로 이 시험을 통과한다.** 그래서 고정 vector(§3.3)와 이를 대조하는 별도 시험(§13.8)을 추가했다.

교차 복호 시험(§13.3)이 결국 잡아내기는 하지만, 그때는 원인이 키 파생인지 AAD인지 봉투인지 가려내는 데 시간이 든다. 규격에서 미리 막는 편이 싸다.

## 3. 고정 vector 재현 방법

§3.3의 값은 표준 라이브러리만 쓰는 독립 스크립트로 계산했다. 아래 절차로 누구든 재현할 수 있다.

### 3.1 순서

1. **HKDF 구현을 먼저 검증한다.** RFC 5869 부록 A.1과 A.3의 SHA-256 test vector로 `HKDF-Extract`·`HKDF-Expand`가 맞는지 확인한다. 이 단계를 건너뛰면 이후 값이 전부 무의미하다.
2. LP v1 encoder를 §7.2 문법대로 구현하고, 기존 고정 vector `47444b31…0141`(30 bytes)로 검증한다.
3. `HKDFInfo(purpose, context) = LP([1 = UInt16BE(1), 2 = UTF8(purpose), 3 = context_or_null])`을 구현한다.
4. 아래 입력으로 `scope_prk` → `scope_root_key` → child key 4개를 계산한다.
5. **모든 중간값의 byte 길이를 확인한다.** 이번 보정 중 손으로 줄바꿈한 hex에서 1 byte가 누락된 적이 있어, 길이 검증을 넣지 않으면 눈으로는 잡히지 않는다.

### 3.2 입력 (시험 전용, 실제 배포 키 아님)

| 항목 | 값 |
| --- | --- |
| `PROTOCOL_SALT` | UTF-8 `gagaodok/e2ee/v1/hkdf-salt` (26 bytes) |
| `account_master_key` | `00 01 02 … 1f` (32 bytes) |
| `account_id` | `11111111-1111-4111-8111-111111111111` |
| `space_id` | `MAC_SPACE` |
| `room_id` | `22222222-2222-4222-8222-222222222222` |
| `worldline_id` | null |

`account_master_key`로 `00`부터 `1f`까지의 연속 byte를 고른 이유는 손으로도 확인할 수 있고 오타가 눈에 띄기 때문이다.

### 3.3 기대 출력

| 항목 | 값 | byte |
| --- | --- | ---: |
| `canonical_scope_context` | `47444b310004…0000` | 115 |
| `HKDFInfo(scope-root, ctx)` | `47444b310003…0000` | 171 |
| `scope_prk` | `d6f8acf0397895e14f62491a74bc964c9bee238cf4efab0016a1f5467b211048` | 32 |
| `scope_root_key` | `5633eaf345979da613efa3c7a785a48f5e4c60473ca806f772d79c62cc3d93a0` | 32 |
| `field_aead_key` | `c96df08f1224ca6f8b3e96ac87f1e7d7327a4e5f0ae250c8752656bbe31c793f` | 32 |
| `checkpoint_aead_key` | `45759f66516548d112ef49ef261a49d8c5537f790772322c20afa560312c14bd` | 32 |
| `attachment_wrap_key` | `2368e886dbfacce439bab98ec99c049f0d5130fe2e0eb2bbe6b62fbe72f0068d` | 32 |
| `compat_tag_key` | `8cca8fd82e374d48e585bc3e250d317e0560905004bdd93f458d84f1713da9f4` | 32 |

전체 hex는 제안서 §3.3에 줄바꿈 없이 실려 있다.

### 3.4 오답 확인

단계를 틀리면 값이 실제로 달라진다는 것을 같은 스크립트로 확인했다.

| 잘못된 구현 | 결과 |
| --- | --- |
| `scope_root_key`에서 Extract 생략 | `41362c4745d268b073b701a554541ae2cb727cc2cbb468567c069f4cdd550ba9` |
| 하위 키에서 Extract 재수행 | `e50588ed325306340210f7af8cf7e87de08fc7ac6be44bf2b36db8065281d350` |

두 오답 모두 정상값과 다르며, **둘 다 domain separation 시험은 통과한다.**

### 3.5 스크립트를 저장소에 넣지 않은 이유

이번 작업의 수정 허용 범위가 E2EE 문서로 한정되어 있어 `tools/` 아래에 파일을 만들지 않았다. 위 절차와 입력·기대 출력이 모두 문서에 있으므로 재현에 지장이 없다. **Phase 1에서 Swift·Kotlin contract test fixture를 만들 때 이 값을 그대로 옮기면 된다.** 스크립트를 저장소에 두는 것이 낫다고 판단되면 Codex가 위치를 지정해 주기 바란다.

## 4. Envelope `alg` 인증

§7.1 봉투의 `version`과 `key_generation`은 AAD field 1·2로 이미 인증되지만 `alg`(offset 1)는 어디에도 묶이지 않았다.

- AAD에 **field 12 = `alg` (UInt8)**를 추가했다. 봉투의 `alg` byte와 같은 값이어야 한다.
- pairing AAD에도 **field 6 = `alg`**를 추가했다.
- v1은 `0x01`(AES-256-GCM)만 허용하고, 다른 값은 **복호화를 시도하기 전에** fail closed로 거부한다. AEAD 실패에 기대지 않는다.
- §13.4에 `alg` 변조를 추가하고 §13.5로 별도 시험을 신설했다. 봉투 `alg`와 AAD field 12가 어긋나는 경우도 거부 대상이다.

**기존 field 1~11을 재번호 매기지 않고 12번을 새로 붙였다.** 이미 확정한 LP byte와 §3.3 vector가 그대로 유지되기 때문이다.

## 5. Phase 0 실측값 반영

`0966b65`의 안전한 집계 결과만 사용했다. 실제 대화 archive는 열지 않았다.

| 항목 | Mac | Android phone | Tablet |
| --- | ---: | ---: | --- |
| 최대 첨부 | 2,618,357 bytes | 157,678 bytes | 미측정 |
| 최대 avatar | 1,391,214 bytes | 6,593,776 bytes | 미측정 |

§9.2를 다음과 같이 고쳤다.

- 관측값이 모두 12MB 미만이지만 **영구적인 전체 상한의 증명이 아니다.** Tablet은 미측정이고, Mac 앱 자체에 첨부 상한이 없어서 관측 최대값은 "지금까지 넣은 것 중 가장 큰 것"일 뿐이다.
- 따라서 상한은 관측값이 아니라 **규격으로** 12MB를 정하고, **Mac 입력 경로에 실제로 적용**해야 한다고 명시했다. 상한 없는 현재 동작을 두고 문서에만 적는 것은 안 된다.
- **avatar를 첨부와 같은 시험 대상에 넣었다.** phone의 최대 avatar 6.59MB가 관측된 최대 첨부 2.6MB보다 2.5배 크다. avatar를 "작은 이미지"로 가정하면 R2·암호화·메모리 시험이 가장 큰 실제 payload를 놓친다.
- 6.59MB를 단일 AES-GCM 호출로 처리할 때의 메모리 사용량은 아직 측정하지 않았다. Phase 2에서 측정한 뒤 단일 호출 유지와 chunked 도입 중 하나를 정한다.

## 6. 아직 구현하지 않은 것

문서가 규격을 정했다고 해서 동작이 보장되는 것은 아니다. 다음은 명시적으로 남아 있다.

- **§5.1 접근 통제는 Worker 구현이 지켜야 성립한다.** 지금은 문서상의 계약이며, Phase 2의 7개 negative test로만 확인된다.
- **Mac 입력 경로의 12MB 상한이 코드에 없다.**
- §3.3 vector를 Swift·Kotlin contract test fixture로 옮기는 작업.
- Tablet inventory.

## 7. Codex가 다음에 확인할 항목

1. **R1 접근 통제 8개 조항이 Worker API 계약으로 옮길 수 있을 만큼 구체적인가.** 특히 3번(session lookup을 조회 권한 근거로 쓰지 않음)과 5번(device token의 account 결속 확인)이 Phase 1 schema 설계와 충돌하지 않는지.
2. **§10.7 비보장 표현의 수위.** "Worker 접근 통제 결함이 QR 유출과 겹치면 방어가 없다"를 사용자 안내에 어떤 문구로 옮길지.
3. **§3.3 vector의 시험 입력값이 적절한가.** `account_master_key`를 `00…1f`로 고른 것과 `space_id = MAC_SPACE`가 실제 enum 값과 맞는지.
4. **AAD field 12 추가가 다른 규격과 충돌하지 않는지.** 특히 recovery-wrapped master key가 field 11·12를 함께 쓰는 경우.
5. **12MB 상한을 Mac 입력 경로에 적용하는 작업의 소유자.** 이 작업은 앱 코드 변경이므로 이번 문서 보정 범위 밖이다.
6. **§3.3 계산 스크립트를 저장소에 둘지, 둔다면 어느 경로에 둘지.**
