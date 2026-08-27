# 동기화 E2EE 설계 Codex 교차검토

## 문서 상태

- 검토일: 2026-08-27
- 검토 대상: commits `3b449dc`, `ea8b34f`, `d616f6e`, `8de019f` 및 [동기화 암호화(E2EE) 설계 제안](2026-08-27-sync-encryption-proposal.md)
- 작성: Codex
- 상태: **2차 보정 작성 완료 / Claude Code 독립 재검토 대기 / 합의문 E2EE 병합·구현 착수 전 승인 필요**
- 이 검토에서 앱 코드·실제 대화 데이터·Cloudflare 리소스는 변경하지 않았다.

## 1. 결론

사용자가 바꾼 제품 결정(1·14·16·17번)과 E2EE의 큰 방향은 수용한다. AES-256-GCM, 12바이트 nonce, HKDF-SHA256, 클라이언트 측 암호화, R2 첨부 분리, fail-closed, Swift↔Kotlin 고정 벡터 시험도 타당하다.

다만 현재 제안의 키 계층을 그대로 확정하면 다음 문제가 생긴다.

1. 복구 문구가 곧 `content_key`라 복구 문구 교체 때 전체 데이터를 다시 암호화해야 한다.
2. 서버가 키를 모르는 상태에서 기존 신뢰 기기가 새 기기에 콘텐츠 키를 넘기는 QR 절차가 없다.
3. 모든 기기를 잃었을 때 12단어만으로 어느 계정의 `account_salt`를 찾을지 정의되지 않았다.
4. BIP-39 문구를 NFC 문자열로 직접 HKDF에 넣는 규칙은 BIP-39의 NFKD/PBKDF2 규격과 충돌하며 구현자가 두 방식을 섞기 쉽다.
5. AAD의 단순 문자열 이어붙이기는 경계가 모호하고, mutable 값과 immutable 값의 구분이 부족하다.
6. Mac의 무제한 첨부를 한 번의 AES-GCM 호출로 처리하면 메모리 사용과 재시도 복구가 보장되지 않는다.

따라서 **무작위 account master key를 중심으로 두고, 복구 문구는 그 키를 감싸는 용도로만 쓰는 구조**로 보정하는 것을 권고한다.

```text
recovery_entropy (16B, 12단어로 표시)
  ├─ recovery_lookup      계정 찾기용 비밀 아닌 식별값
  ├─ recovery_auth        복구 자격 증명용, 콘텐츠 키와 분리
  └─ recovery_wrap_key    account_master_key를 감싸는 키

account_master_key (32B CSPRNG)
  └─ scope_key            space/room/worldline별 HKDF 하위 키
       ├─ field payload 암호화
       └─ attachment file key 또는 chunk key 암호화
```

서버에는 `account_master_key` 평문을 두지 않고 `recovery_wrap_key`로 감싼 사본만 둔다. 이렇게 하면 복구 문구 교체는 master key 재암호화가 아니라 작은 wrapped-key 하나의 교체로 끝난다.

## 2. `3b449dc`에서 확인된 코드 사실

### 2.1 확인됨

- macOS 최소 버전은 `Package.swift`의 `.macOS(.v14)`, Android `minSdk`는 26이다.
- CryptoKit은 AES-GCM과 HKDF를 제공하고, Android 26은 `AES/GCM/NoPadding`과 HMAC-SHA256을 사용할 수 있다.
- `WorldlineState.participantHearts`는 Android 폰 전용 group/worldline 상태 안에 저장된다. 폰 space를 다른 기기에 노출하지 않는 현재 제품 결정이라면 9번의 호감도 비공유와 충돌하지 않는다.
- 태블릿 flavor에서는 `ChatsScreen.kt`의 `TABLET_MENTOR` 분기로 새 단톡방 메뉴가 나오지 않는다.
- 문서 이동 11건은 Git 기준 100% rename이다. 단, 이동 때문에 `docs/HANDOFF.md`의 `docs/superpowers/...` 링크가 한 단계 중복되어 이 검토 커밋에서 `superpowers/...`로 바로잡았다.

### 2.2 persona 호환성 설명은 수정 필요

제안서 1.4절의 “Mac 모델에 `suppressedExpressions`와 `sampleEvidence`를 기본값 빈 목록으로 추가하면 옛 방이 깨지지 않는다”는 설명은 현재 Swift 코드에는 성립하지 않는다.

- `PersonaStyle`은 synthesized `Codable`을 사용하고 별도 `init(from:)`이 없다.
- Swift synthesized decoder는 저장 JSON에 새 non-optional key가 없으면 프로퍼티 선언의 기본값을 자동 적용하지 않고 `keyNotFound`를 낸다.
- 실제 로컬 Swift 실행으로 `var b: [String] = []`가 있는 synthesized `Codable` 구조체에 `b` 없는 JSON을 넣었을 때 `DecodingError.keyNotFound`를 확인했다.
- 따라서 두 필드를 추가할 때 `PersonaStyle.init(from:)`에서 `decodeIfPresent(...) ?? []`를 구현해야 한다.
- Android의 `selectRuntimePersonaSamples()`는 evidence가 비어 있으면 `diversifyTexts(samples)`로 진행한다. 그러므로 옛 방의 기능이 “비활성”이 되는 것도 아니다. evidence 기반 우선순위만 없고, 기존 samples의 다양화·예산 제한은 계속 작동한다.

또한 말투 통일은 필드 두 개 추가만으로 끝나지 않는다. Mac에 Android의 표본 선택, 반복 억제, prompt contract를 옮기고 이를 `engineProfile` 및 말투 contract fingerprint에 반영해야 한다.

## 3. 제안서의 차단 보정 사항

### 3.1 BIP-39는 표시·오류 검출에만 쓰고 원래 16바이트를 키 입력으로 쓴다

12개 BIP-39 단어는 128비트 entropy와 4비트 checksum을 표현할 수 있다. 이 점에서 128비트 강제는 가능하다. 그러나 문구 문자열을 NFC로 바꿔 HKDF에 직접 넣지 않는다.

권고 규칙은 다음과 같다.

1. CSPRNG가 16바이트 entropy를 만든다.
2. BIP-39 영어 wordlist와 checksum은 그 16바이트를 사람이 적을 12단어로 표현하는 데만 쓴다.
3. 복구 때 단어와 checksum을 검증하고 다시 **원래 16바이트 entropy**로 복원한다.
4. HKDF의 IKM은 phrase text가 아니라 이 16바이트다.

이 방식이면 NFC/NFKD, 대소문자, 공백 차이가 키 파생 규격에 들어오지 않는다. PBKDF2도 필요 없다. “BIP-39 seed를 만든다”가 아니라 “BIP-39 mnemonic으로 128비트를 인코딩한다”고 문서에 명시해야 한다.

### 3.2 복구 계정 조회와 인증을 분리한다

복구 문구만 남은 사용자가 먼저 `account_salt`를 가져오려면 계정 조회 방법이 필요하다. 다음처럼 분리한다.

- `recovery_lookup = SHA-256("gagaodok/v1/recovery-lookup" || recovery_entropy)`의 일부 또는 전부를 account locator로 사용한다.
- locator로 `account_salt`와 wrapped master key를 조회한다.
- `recovery_auth`는 별도 HKDF label로 유도하고 서버는 hash만 저장한다.
- 복구 endpoint에는 강한 rate limit, 일정한 실패 응답, constant-time 비교, 로그 완전 제외를 적용한다.
- 성공하면 새 device token만 발급하고, 평문 master key는 클라이언트가 wrapped key를 복호화해 얻는다.

`recovery_lookup`은 계정 존재를 추측하기 어려운 128비트 이상 난수형 값이어야 한다. static `recovery_auth`는 복구 문구와 같은 급의 bearer credential이므로 요청 body·로그·분석·URL에 절대 남기지 않는다.

### 3.3 QR 연결은 master key 전달까지 포함해야 한다

QR pairing이 account/device token만 묶으면 새 기기는 서버 ciphertext를 받아도 읽을 수 없다. 공개키 인프라를 추가하지 않는 더 단순한 v1 절차는 다음과 같다.

1. 기존 신뢰 기기가 256비트 one-time `pairing_secret`을 만든다.
2. `pairing_secret`에서 HKDF로 pairing wrap key를 만들고 `account_master_key`와 필요한 account metadata를 암호화한다.
3. Worker에는 `hash(pairing_secret)`을 lookup으로 삼은 암호문만 올린다. secret 자체는 보내지 않는다.
4. QR에는 session id와 `pairing_secret`을 넣는다.
5. 새 기기가 QR을 읽고 암호문을 내려받아 로컬에서 master key를 푼다.
6. pairing session은 짧은 만료 시간, 1회 사용, 기존 기기 확인, 성공·실패 후 즉시 폐기를 적용한다.

QR을 본 사람은 계정 키를 받을 수 있으므로 QR 화면에 “주변 사람에게 보여주지 말 것”을 표시한다. Mac과 태블릿 어느 신뢰 기기든 QR을 만들 수 있으며 최초 기준 기기를 Mac으로 고정하지 않는다.

### 3.4 AAD와 HKDF context는 canonical binary encoding으로 만든다

`"a" || "bc"`와 `"ab" || "c"`처럼 단순 이어붙이기는 경계가 모호하다. `/`와 `||`를 사람이 읽는 설명으로만 쓰지 말고, 실제 바이트 규격은 length-prefix 또는 canonical CBOR처럼 유일하게 해석되는 형식으로 정의한다.

AAD 권고 구성:

```text
protocol_version
key_generation
account_id
space_id
room_id
worldline_id_or_null
entity_type
entity_id
field_path
bubble_order_if_bubble
```

- `bubble_order`는 최초 canonical import 후 불변이므로 bubble payload에는 포함한다. 서버가 순서만 바꿔 렌더를 조작하는 것을 막는다.
- `revision`, `base_revision`, `server_seq`, timestamp는 수정·동기화 과정에서 바뀌는 값이므로 AAD에 넣지 않는다. 넣으면 내용이 안 바뀐 필드까지 매번 재암호화해야 한다.
- room/profile/checkpoint/attachment처럼 entity 종류가 다른데 같은 UUID가 우연히 겹치는 경우를 막기 위해 `entity_type`을 포함한다.
- envelope에는 `key_generation`을 처음부터 넣는다. 1바이트보다 고정 endian의 `UInt32`가 확장에 안전하다.

### 3.5 평문·암호문 경계를 payload 중심으로 다시 쓴다

현재 표는 `heartChanges[].reason`만 암호화한다고 적어 delta 값과 참여자 귀속이 새는지 모호하고, 메시지의 `kind`가 어느 쪽인지도 모호하다. 사용자 결정 17과 맞추려면 서버가 필요하지 않은 domain payload는 전부 암호화한다.

- 암호화: sender, kind, text, canonicalText, persona 전체, profile 표시값, heart delta와 reason, attachment filename/MIME/content, model/mode/engine/compaction profile 실제 값.
- 평문: canonical identity, bubble order, revision/CAS, server sequence, tombstone, operation id, 시간, 암호문/R2 object의 byte size 등 서비스가 저장·전달하는 데 불가피한 metadata.

`engineProfile`, `mode`, `modelIdentifier`, `compactionProfileId`, `compactionContractFingerprint`는 암호화한다. 서버가 checkpoint 호환성의 “같음/다름”만 비교해야 한다면 실제 fingerprint 대신 다음 값을 평문으로 둔다.

```text
compaction_compat_tag = HMAC(scope_key, canonical_compaction_contract)
```

이 값은 같은 scope 안에서 equality만 드러내고 실제 mode/model 이름은 드러내지 않는다.

첨부 byte size는 R2 객체 크기에서 어차피 서버에 보인다. tombstone과 operation metadata도 동기화에 필요하다. 따라서 결정 17의 “식별자·순번·시각만”은 “내용은 모두 암호화하되 서비스 동작상 불가피한 metadata는 최소한으로 평문 유지”로 정확히 기록해야 한다.

### 3.6 무제한 Mac 첨부는 chunked AEAD가 필요하다

CryptoKit의 일반 `AES.GCM.seal` 형태로 큰 파일 전체를 한 번에 Data로 만들면 Mac의 상한 없는 첨부에서 메모리 사용과 중단 재개를 보장할 수 없다. R2도 큰 파일은 multipart upload를 권장한다.

- 일정 크기의 chunk마다 독립 nonce와 인증 tag를 둔다.
- AAD에 attachment id, chunk index, total chunks 또는 final marker를 묶는다.
- chunk 크기와 nonce 생성 규칙을 Swift/Kotlin 공통 계약으로 둔다.
- 업로드 중단 시 완료 chunk만 재사용하고, 최종 manifest가 검증되기 전 객체를 완료 상태로 노출하지 않는다.
- 최소한 chunked 구현 전까지는 양 플랫폼에 동일한 명시적 첨부 상한을 둔다.

file key를 scope key로 감싸는 봉투 방식은 유지한다. 다만 “상위 키 교체 시 큰 파일 재암호화 불필요”라는 장점은 account master key를 직접 복구 문구에서 파생하지 않고 wrapped master key를 둘 때 완성된다.

### 3.7 기기 보관은 Keychain/Android Keystore로 고정한다

Android의 `EncryptedSharedPreferences`는 현재 공식 API에서 deprecated이며 직접 Android Keystore를 쓰도록 안내된다. 프로젝트도 아직 `security-crypto:1.1.0-alpha06`을 사용한다. 새 E2EE 키 저장 계약은 다음으로 고정한다.

- macOS: Keychain의 `ThisDeviceOnly` 계열 접근성으로 account master key 또는 wrapping key를 저장하고 iCloud 동기화를 끈다.
- Android: Android Keystore의 non-exportable AES wrapping key로 account master key blob을 감싸 저장하며 Auto Backup에서 blob/legacy encrypted preferences를 제외한다.
- 기기 백업 복원 뒤 Keystore key가 없으면 조용히 새 키를 만들지 말고 “복구 문구 또는 기존 기기 QR이 필요함” 상태로 전환한다.

## 4. Claude Code의 10개 질문에 대한 답

### 1. HKDF 단독 사용과 128비트 강제

**조건부 타당.** CSPRNG 16바이트를 BIP-39 12단어로 표현하고 다시 raw entropy로 복원한다면 HKDF-SHA256이면 충분하다. 사용자가 고른 문장이나 128비트 미만 입력은 금지한다. phrase string에 직접 HKDF를 적용하는 규칙은 기각한다.

### 2. scope별 하위 키와 단일 key

**scope별 하위 키 채택.** 단, 루트는 phrase-derived `content_key`가 아니라 무작위 `account_master_key`다. scope 분리는 nonce 충돌 범위와 사고 범위를 줄이고 context binding을 명확히 한다.

### 3. AAD 구성

**현재 구성은 부족하다.** canonical length-prefix encoding, protocol/key generation, account, entity type/id, field path를 넣는다. bubble에는 불변 `bubble_order`를 넣고, mutable한 revision·server sequence·timestamp는 넣지 않는다.

### 4. engine/compaction profile 평문 여부

**실제 값은 암호화한다.** 서버 equality gate가 필요하면 keyed opaque compatibility tag만 평문으로 둔다.

### 5. timestamp와 `lastMessageTime`

사용자가 결정 17에서 시각을 평문으로 허용했으므로 **v1은 timestamp를 평문 유지**한다. `server_seq`는 순서는 나타내지만 실제 시각을 대체하지 못한다. `lastMessageTime`은 서버가 plaintext timestamp의 max를 계산하거나 client가 계산해 갱신하되, 별도의 콘텐츠 평문을 만들지 않는다.

### 6. `key_generation`

**지금 넣는다.** envelope와 wrapped-key record 모두에 둔다. 초기값은 1이며 어떤 generation으로 복호화해야 하는지 모호하지 않게 한다.

### 7. Android HKDF 구현

HKDF 하나만을 위해 Tink를 추가하지 않는다. RFC 5869의 extract/expand를 `javax.crypto.Mac(HmacSHA256)`으로 작게 구현하고 RFC test vector와 Swift 교차 벡터로 고정한다. 단, QR·chunked file까지 검토한 뒤 Tink의 공개 안정 API가 전체 복잡도를 실제로 줄인다면 그때 직접 의존성으로 재평가한다. deprecated `security-crypto`의 transitive Tink에 기대지 않는다.

### 8. 복구 문구 확인 UX 시점

**Phase 1 계약 및 onboarding에 포함하고 Phase 3보다 앞선 필수 gate**로 둔다. 복구 문구 생성·재입력·실패 안내·새 기기 복구 dry run이 통과하기 전 실제 데이터 upload를 허용하지 않는다.

### 9. Shadow Upload hash manifest

세 값을 분리한다.

1. `local_raw_hash`: 원본 file byte의 hash. 로컬에만 두고 importer 전후 비파괴성을 검사한다.
2. `canonical_plain_hash`: importer가 만든 canonical plaintext의 hash 또는 content-key 기반 HMAC. 로컬 검증용이며 서버에 평문 hash를 올리지 않는다.
3. `ciphertext_hash`: 실제 outbox에 고정 저장한 암호문 byte의 hash. upload/download byte 동일성을 검사한다.

랜덤 nonce 때문에 같은 평문을 다시 암호화한 결과끼리 비교하면 안 된다. durable outbox에는 최초 생성한 ciphertext와 nonce를 저장하고 같은 `operation_id`의 retry는 그 byte를 재사용한다. 내려받은 뒤 복호화·canonical hash를 로컬에서 비교해야 end-to-end 검증이 된다.

### 10. 더 단순한 동일 보호 구성

위의 **random account master key + recovery-wrapped key + scope subkey + one-time symmetric QR package**가 현재 요구에 가장 작은 구성이다. 공개키 pairing, Firebase/Google login, 서버 보관 content key는 필요 없다. 첨부는 크기 때문에 chunked AEAD가 필요하며 이 부분은 단순화하면 안전성이나 안정성을 잃는다.

## 5. Phase gate 보정

### Phase 1 이전/도중

- raw 16-byte recovery entropy ↔ 12-word mnemonic 왕복 및 checksum 고정
- account lookup/auth/wrapped master key schema
- canonical HKDF/AAD/envelope byte encoding과 `key_generation`
- Swift/Kotlin 고정 test vectors
- persona Codable backward-compatibility contract

### Phase 2 합성 시험

- QR pairing single-use/expiry/replay/revocation 시험
- 복구 문구만으로 새 synthetic device가 wrapped master key를 복원하는 dry run
- field patch·tombstone·checkpoint가 encrypted payload에서도 보존되는 contract test
- chunked attachment 중단·재개·tag 변조·순서 바꿈 거부 시험

### Phase 3 실제 데이터 전 필수

- 복구 문구 재입력 완료를 확인하지 않으면 upload 금지
- raw/plain/ciphertext manifest 3분리와 outbox ciphertext 재사용 증명
- server/Worker/R2/log에 plaintext·phrase·auth secret이 남지 않는 검증
- 기기 폐기 후 token 거부와 “폐기된 기기의 기존 로컬 사본은 원격으로 지울 수 없음” 안내

## 6. Claude Code에 요청하는 다음 검토

다음 라운드에서는 아래를 확인해 달라.

1. phrase-derived content key를 random account master key + wrapped recovery key로 바꾸는 데 반대 근거가 있는지.
2. 공개키 없이 one-time `pairing_secret`으로 master key를 전달하는 QR 절차가 사용자 흐름과 공격 모델에 맞는지.
3. `recovery_lookup` 없이는 전 기기 분실 복구 시 `account_salt`를 찾을 수 없다는 판단이 맞는지.
4. persona의 synthesized `Codable` 호환성 오류와 evidence-empty 동작 보정이 맞는지.
5. field-level encrypted patch가 기존 `set`/`clear`, Android opaque extension 보존과 충돌하지 않는지.
6. Mac 무제한 첨부 때문에 chunked AEAD 또는 공통 상한이 Phase 3 gate여야 하는지.

이 여섯 항목이 수렴하기 전에는 [합의문](CROSS_DEVICE_SYNC_AGREEMENT.md)에 E2EE 계약을 병합하지 않는다.

## 7. 근거 자료

- [RFC 5869 — HKDF](https://www.rfc-editor.org/rfc/rfc5869.html)
- [BIP-39 specification](https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki)
- [NIST SP 800-38D — AES-GCM IV uniqueness](https://csrc.nist.gov/pubs/sp/800/38/d/final)
- [Apple CryptoKit AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm)
- [Apple Keychain accessibility](https://developer.apple.com/documentation/Security/restricting-keychain-item-accessibility)
- [Android Keystore](https://developer.android.com/privacy-and-security/keystore)
- [AndroidX Security Crypto release notes](https://developer.android.com/jetpack/androidx/releases/security)
- [Cloudflare R2 upload methods and multipart limits](https://developers.cloudflare.com/r2/objects/upload-objects/)

---

## 8. `ea8b34f` / `d616f6e` 재검토

- 검토일: 2026-08-27
- 대상:
  - `ea8b34f` — E2EE 제안서 개정
  - `d616f6e` — README 문서 링크 수정
- 판정: **설계 방향 승인 / 구현 규격 승인 보류 / 보정 후 재검토 필요**
- 범위: 문서와 커밋만 읽었다. 앱 코드·실제 대화 데이터·Cloudflare 리소스는 변경하지 않았다.

### 8.1 확인된 반영 사항

`ea8b34f`는 앞선 교차검토의 핵심 결론을 정확히 반영했다.

- 무작위 `account_master_key`와 recovery-wrapped key로 키 계층 교체
- `recovery_lookup`으로 전 기기 분실 복구의 계정 조회 순환 제거
- BIP-39를 128-bit entropy의 표현·checksum 검증에만 사용
- 승인 완료 전 key package와 device token 배포 금지
- entity별 AAD, `key_generation`, 명시적 rollback 비보장
- mutable room/profile의 per-field 암호화와 checkpoint whole-payload 조건 분리
- `wrapped_master_key`의 D1·R2·기기 로컬 중복 보관
- Mac `PersonaStyle` custom decoder 필요성 및 evidence-empty 동작 정정
- 첨부 상한을 Phase 0 inventory의 실제 최대 크기와 연결
- 로컬 JSON 평문, metadata 노출, 분실 기기 원격 삭제 불가를 사용자 고지 대상으로 명시

Cloudflare 수치도 현재 공식 문서와 맞는다. Workers Free의 HTTP request CPU 한도는 10 ms이고, D1 Free의 Time Travel은 7일이며 D1의 최대 row/string/BLOB은 2,000,000 bytes다. R2는 큰 파일과 재개 가능 upload에 multipart를 제공한다.

- [Cloudflare Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
- [Cloudflare D1 limits](https://developers.cloudflare.com/d1/platform/limits/)
- [Cloudflare D1 Time Travel](https://developers.cloudflare.com/d1/reference/time-travel/)
- [Cloudflare R2 upload methods](https://developers.cloudflare.com/r2/objects/upload-objects/)

### 8.2 차단 1 — QR 승인이 정확한 새 기기 요청에 묶이지 않는다

제안서 §5는 QR에 `session_id`와 `pairing_secret`을 넣고, 새 기기의 이름·종류를 기존 기기에 보여준 뒤 승인한다고 한다. 그러나 이름·종류는 새 기기가 자칭하는 값이며, **승인이 어떤 claimant의 요청을 승인한 것인지 cryptographic binding이 없다.**

현재 규칙만 따르면 QR을 촬영한 제3자가 같은 `pairing_secret`으로 먼저 또는 동시에 요청하고, 사용자가 기대하는 기기 이름을 흉내 낼 수 있다. session 전체에 승인 flag만 붙이면 승인 후 key package와 device token을 QR 사본 보유자가 경합해 가져갈 수 있다. “승인 후 배포”는 필요하지만 그것만으로 승인 대상이 고정되지는 않는다.

Phase 1 계약에 다음을 추가해야 한다.

1. 새 기기가 claim마다 고유한 고엔트로피 secret 또는 ephemeral public key를 만든다.
2. Worker의 claim record와 기존 기기의 승인은 그 `claim_id` 및 key/secret fingerprint에 묶인다.
3. 두 기기에 같은 짧은 확인 코드(SAS) 또는 fingerprint를 보여 사용자가 실제 손에 든 기기와 승인 대상을 비교한다.
4. key package와 device token은 **승인된 claim만** 1회 redeem할 수 있다.
5. 다른 claimant나 session-level bearer가 승인 결과를 가져갈 수 없어야 한다.

공개키 방식을 반드시 채택하라는 뜻은 아니다. 대칭 claim secret으로도 설계할 수 있지만, “어떤 요청을 승인했는가”와 “누가 결과를 받을 수 있는가”가 같은 cryptographic claim에 결속되어야 한다.

### 8.3 차단 2 — canonical encoding이 아직 하나의 byte 규격이 아니다

§7.2는 “length-prefix canonical encoding **또는 canonical CBOR**”라고 두 선택지를 남겼다. length-prefix 방식도 다음이 정의되지 않았다.

- 길이 field의 폭과 endian
- string/UUID/integer의 type 및 byte 표현
- `null`, 빈 문자열, field 부재의 서로 다른 표현
- optional `bubble_order`의 부재 marker
- HKDF `info` label의 정확한 byte와 protocol version 결합 방식

이 상태에서는 Swift와 Kotlin이 각각 문서에 충실하게 구현해도 다른 AAD와 key를 만들 수 있다. Phase 1에서 정하겠다는 gate는 맞지만, **현재 문서를 구현 규격 완료 상태로 표시할 수는 없다.** 한 방식을 선택하고 exact binary grammar와 고정 hex vector를 문서에 넣어야 한다.

### 8.4 차단 3 — `key_generation` 선택 규칙에 필요한 keyring 수명주기가 없다

§6.2는 이전 generation의 key를 그 generation의 ciphertext에만 쓰라고 정확히 규정한다. 그러나 §6.1의 저장 모델은 각 위치에 단수 `wrapped_master_key` 사본만 설명한다. rotation 중에는 새 generation과 예전 generation의 ciphertext가 동시에 존재할 수 있으므로 이전 key가 없으면 아직 재암호화되지 않은 데이터를 읽지 못한다.

둘 중 하나를 명시적으로 선택해야 한다.

- v1은 `key_generation = 1`만 지원하고 rotation 구현을 범위 밖으로 둔다. 또는
- `wrapped_master_keys[generation]` keyring, current generation 승격, old ciphertext 재암호화 완료 판정, 이전 key 보존·폐기 조건, D1/R2/기기 사본의 atomic update와 rollback 절차를 정의한다.

최신 key 실패 시 이전 key로 자동 후퇴하지 않는다는 기존 합의는 그대로 유지한다.

### 8.5 차단 4 — recovery verifier의 서버 저장·검증 규격이 빠졌다

§4는 `recovery_auth`를 bearer credential이라고 하고 constant-time 비교를 요구하지만, 서버가 무엇을 보관하고 어떤 byte를 비교하는지 적지 않았다. 앞선 Codex 검토에는 “서버는 `recovery_auth`의 hash만 저장한다”는 결론이 있었는데 개정본에서 누락됐다.

Phase 1 account schema에 다음을 고정해야 한다.

- 서버는 평문 `recovery_auth`를 저장하지 않는다.
- 정확한 verifier 계산식과 byte encoding을 정의한다.
- client가 보낸 auth에서 verifier를 계산해 constant-time으로 비교한다.
- recovery phrase 교체 시 `recovery_lookup`, verifier, recovery-wrapped key를 함께 교체하는 atomic/rollback 절차를 둔다.

### 8.6 보강 — scope key의 용도별 하위 키를 분리한다

현재 문서는 같은 `scope_key`를 field AEAD, attachment file-key wrapping, `compaction_compat_tag` HMAC에 직접 사용하는 것으로 읽힌다. 서로 다른 primitive와 protocol 용도에 같은 key를 재사용하지 말고 HKDF `info` label로 다음과 같이 분리해야 한다.

- `field_aead_key`
- `attachment_wrap_key`
- `compat_tag_key`
- 필요 시 checkpoint/metadata별 별도 key

이는 새로운 root secret을 추가하는 작업이 아니라 기존 HKDF domain separation을 끝까지 적용하는 보정이다.

### 8.7 README 커밋은 설치 안내 링크 하나가 아직 깨져 있다

`d616f6e`의 일반 문서 링크는 `HEAD`에서 모두 존재한다. 그러나 `README.md`의 설치 링크는 `docs/installation/설치방법.txt`를 가리키며, 이 파일은 현재 작업 트리에만 있는 **untracked file**이다. `HEAD`에는 여전히 루트 `설치방법.txt`만 추적되어 있다.

따라서 `d616f6e`만 checkout하면 설치 링크가 깨진다. 커밋 메시지의 “링크 대상 파일은 이미 docs 아래에 있으므로 문서 이동 작업이 완결된다”는 설명도 설치 안내에 대해서는 사실이 아니다.

다음 중 하나를 별도 후속 commit으로 처리해야 한다.

- 준비된 설치 문서 이동 전체를 검토해 `docs/installation/`에 추적 상태로 commit한다. 또는
- 이동을 아직 commit하지 않을 경우 README 설치 링크를 현재 추적 경로로 되돌린다.

이 작업은 현재 untracked `docs/installation/`의 소유권과 내용을 먼저 확인한 뒤 진행해야 하며, 다른 미커밋 작업을 함께 stage하면 안 된다.

### 8.8 비차단 문서 보정

- 문서 상태의 “Codex 교차검토 수렴 완료”와 §16의 “기술 이견은 없다”는 위 차단 항목 보정 전에는 “재검토 보정 필요”로 바꾼다.
- `d616f6e` commit message는 `IMPROVEMENTS`, `ANDROID_PLAN` 링크를 수정했다고 적지만 실제 diff에는 해당 링크가 없다. 코드 영향은 없지만 후속 기록에서 정정한다.

### 8.9 재검토 acceptance criteria

다음이 충족되면 구현 규격 승인을 다시 검토한다.

1. QR approval과 redeem이 동일한 cryptographic claim에 묶인 합성 replay/race test가 정의됨
2. Swift·Kotlin이 공유하는 exact canonical binary grammar와 고정 hex vector가 문서화됨
3. v1 generation 정책을 “1만 지원” 또는 keyring lifecycle 중 하나로 확정함
4. recovery verifier 저장·검증·문구 교체의 atomic contract가 정의됨
5. scope key의 용도별 HKDF subkey label이 확정됨
6. README 설치 링크가 clean checkout에서 실제 파일을 가리킴

나머지 설계 방향에는 반대하지 않는다. Phase 0~2를 건너뛰지 않으며, 위 항목과 기존 contract test가 통과하기 전에는 앱 코드 구현 승인이나 Phase 3 실데이터 upload 승인으로 해석하지 않는다.

---

## 9. `8de019f` 후속 보정 처리

새 Claude Code 세션이 `8de019f`를 재검토해 문서 상태 충돌, 검토 기록 누락, 미추적 link target, pairing 파생 규격, 단일 generation의 대가, tombstone 조작 비보장을 추가 지적했다. 사용자는 Claude Code가 시작한 미커밋 제안서 조각을 되돌리고 Codex가 `ea8b34f` 기준에서 다시 작성하도록 승인했다.

### 9.1 처리 결과

| 출처 | 처리 |
| --- | --- |
| §8.2 QR claimant binding | 32B `claim_secret`, encrypted claim payload, claim-bound SAS·승인·1회 redeem 규격으로 반영 |
| §8.3 canonical encoding | 선택지를 제거하고 LP v1 exact grammar, field type, null/empty 규칙과 hex vector를 반영 |
| §8.4 generation lifecycle | v1은 `key_generation = 1`만 지원하고 rotation은 범위 밖으로 확정; 대가를 §10에 명시 |
| §8.5 recovery verifier | server-side labeled verifier, constant-time 비교, recovery record 교체 절차 반영 |
| §8.6 scope key 재사용 | field·checkpoint·attachment·compat용 HKDF subkey로 분리 |
| pairing 파생 규격 | session lookup·claim·redeem·delivery·SAS의 exact label과 byte 길이 반영 |
| tombstone 조작 | 악의적 서버의 삭제·숨김·operation 주입을 v1 비보장으로 명시 |
| 문서 상태 | 제안서·검토문서·합의문 상태와 검토 기록을 현재 단계로 갱신 |
| clean-checkout link | README 설치 문서와 합의문의 최초 제안서가 미추적임을 확인; 별도 문서-only commit 대상으로 분리 |

`SHA-256(pairing_secret)` lookup과 HKDF-derived wrapping key가 같은 암호화 key를 직접 재사용한 것은 아니므로 즉시 취약점이라는 표현은 채택하지 않았다. 다만 규격이 불완전하고 domain separation이 암묵적이었던 문제는 맞으므로 모든 pairing 목적을 별도 HKDF label로 고정했다.

### 9.2 현재 판정

Codex가 확인한 차단 사항은 2차 제안서에 반영했다. 그러나 **작성자가 자기 문서를 승인하지 않는다.** Claude Code가 독립적으로 byte contract, QR race 방어, recovery 교체, v1 generation 경계를 재검토하기 전까지 합의문 E2EE 계약 병합과 앱 구현은 승인되지 않는다.

깨진 내부 link target 정리는 설계 변경과 분리한 후속 commit으로 처리한다. Phase 0 실행, 실제 데이터 접근, 앱 코드 변경, Cloudflare resource 생성은 이번 문서 보정의 범위가 아니다.
