# 완전 동기화 Task 11–15 설계

_2026-09-01 · 기준 커밋 `aaa70a0` · 상위 계획 `docs/superpowers/plans/2026-08-31-complete-cross-device-sync.md`_

이 문서는 **설계와 계약**만 담는다. 실행 단계는 같은 날짜의 구현 계획 문서에 있다.
이 문서는 배포·원격 migration·실제 데이터 접근·앱 설치를 승인하지 않는다.

문서 언어는 한국어이고 식별자·label·명령·파일 경로는 영어다. 이 저장소의
`PHASE1_*`, `CLOUDFLARE_*` 문서와 같은 규칙이다.

---

## 1. 범위와 경계

### 1.1 이번에 하는 것

Task 11부터 Task 15까지다. Task 15가 **합성 데이터만 쓰는 마지막 단계**이고,
Task 16부터 실제 대화가 들어간다.

| Task | 내용 | 사용자 승인 |
| --- | --- | --- |
| 11 | 첨부(사진·PDF) 동기화 | 불필요 |
| 12 | 방 가족 완결성(세계선·versioned AI state) | 불필요 |
| 13 | foreground runtime과 kill switch 연결 | 불필요 |
| 14 | 로컬 전체 수용 | 불필요 |
| 15 | 격리된 합성 Cloudflare 자원 검증 | **필요 — 여기서 정지** |

### 1.2 이번에 하지 않는 것

- **Task 16·17·18** — 실제 방 rollout, production 자원 생성, 최종 서명 릴리스.
- **앱 설치** — 2026-09-01 사용자 결정. `/Applications/가가오독.app`을 바꾸지 않고
  안드로이드 APK도 설치하지 않는다. 따라서 **UI는 미검증으로 보고**하며, 무엇을
  확인해야 하는지 목록으로 남긴다. 빌드 성공을 화면 확인으로 바꿔 쓰지 않는다.
- **실제 대화·첨부·복구 문구 접근** — 0건을 유지한다.
- **push·merge** — commit까지만 한다.
- **chunked AEAD** — 정본 스키마 §7.2가 v1 M05 범위 밖으로 못박았다.
- **Gemini cache와 호감도 동기화** — 기기 로컬 데이터로 남긴다.

### 1.3 건드리지 않는 작업 중 파일

`package_for_sharing.sh`, `tools/costsim.py`의 기존 수정과 모든 untracked 파일은
사용자·다른 작업자의 것으로 취급한다. stage·수정·삭제·reset하지 않는다.

---

## 2. 조사로 바로잡은 전제

인수인계 문서 `docs/CODEX_CLAUDE_HANDOFF_2026-09-01.md`의 그림과 실제 저장소가
세 군데 달랐다. 설계는 실제 쪽에 맞췄다.

| 인수인계 문서의 서술 | 저장소 실측 |
| --- | --- |
| "Task 11 첨부 코디네이터를 아직 만들지 마라" | Worker·D1·R2 경로는 **완성**돼 있다. `0006_attachment.sql`, `src/routes/attachments.ts`, `src/storage/attachmentContent.ts`, 테스트 5종. 2026-08-29 원격 합성 smoke에서 업로드→complete→다운로드 바이트 일치 확인 |
| "Task 15가 마지막" | 계획서에 Task 16·17·18이 더 있다 |
| "Cloudflare 작업 전면 보류" | 합성 전용 D1·private R2·Worker가 **이미 존재**하고 migration 0001–0010이 원격 적용돼 있다(`docs/CLOUDFLARE_CONNECTION_GATE.md`) |

빠져 있는 것은 **클라이언트뿐**이다. 현재 Swift·Kotlin 모두 첨부가 달린 메시지를
만나면 건너뛴다(`SyncShadowUploadCoordinator.skippedAttachments`,
`SyncShadowWriteModel.skippedAttachments`).

계획에 영향을 주는 사실 두 가지를 추가로 확인했다.

- **Swift에 `swift test`가 없다.** `Package.swift`에 test target이 없고
  `Tests/` 아래 36개 파일이 각각 `@main` 실행파일이다(SyncOutbox 21,
  Tests 11, E2EEContract 4). `swiftc`로 하나씩 컴파일해 실행해야 한다.
- **Task 15의 "24시간 유지보수 점검"은 기다릴 일이 아니다.**
  로직은 이미 로컬 테스트 3개가 덮고(`runMaintenance(env, now)`가 시각을 주입받는다),
  원격에서는 `wrangler dev --remote --test-scheduled`로 예약 이벤트를 직접 호출한다.

---

## 3. 첨부 암호 계약 v1

### 3.1 해결하는 문제

`SyncE2EE.Scope`는 `(account_id, space_id, room_id, worldline_id?)`이고
`encodeScopeContext`가 `room_id`를 정규 UUID로 강제한다. 비울 수 없다.

그런데 정본 스키마 §7.1은 첨부의 canonical identity를 **`(account_id, attachment_id)`**로
확정했고, `create_attachment` operation target에 `room_id`·`worldline_id`를
**금지**한다. 한 첨부가 여러 방에서 참조될 수 있고, bubble 참조가 없는 첨부도
존재하며, bubble이 tombstone돼도 첨부는 남는다.

따라서 받는 기기가 "어느 방 scope로 열쇠를 만들어야 하는가"를 알아낼 방법이 없다.
가짜 room UUID를 넣으면 기기 간 복호화가 조용히 깨진다.

### 3.2 결정 — 계정 단위 첨부 scope (2026-09-01 사용자 승인)

첨부 키를 방과 무관하게 **계정 마스터키에서 바로** 갈라낸다.

기각한 대안:

- **고정 sentinel room UUID** — 방이 아닌 것을 방으로 인코딩한다. 읽는 사람이
  반드시 오해하고, `space_id` 자리에 무엇을 넣을지가 미결로 남는다.
- **참조하는 방마다 봉투 복제** — `wrapped_file_key` 칸이 하나뿐이라 D1 스키마와
  Worker 계약 변경, 원격 migration이 필요하다. bubble 참조 없는 첨부는 여전히
  못 연다.

선택안이 성립하는 근거는 두 가지다.

1. 정본 스키마 §7.1이 이미 "다운로드 권한은 같은 account의 유효한 device token으로
   판정한다 … 한 첨부가 여러 방에서 참조될 수 있으므로 room UUID를 identity에
   억지로 넣지 않는다"고 정했다. 키 유도가 그 결정을 따라간다.
2. 새 메커니즘이 아니다. recovery(`recovery-lookup`·`recovery-auth`·`recovery-wrap`)와
   pairing이 **이미** 계정/세션 비밀에서 scope 없이 바로 유도하는 같은 모양을 쓴다.

**서버와 D1은 바뀌지 않는다.** `wrapped_file_key_enc`는 Worker에게 계속 불투명한
바이트다.

### 3.3 키 유도

기존 private helper 세 개(`hkdfSHA256`, `derivedKey`, `hkdfInfo`)를 그대로 재사용한다.
새 원시 연산을 도입하지 않는다.

```text
attachment_root_key = HKDF-Expand(
    PRK  = HMAC-SHA256(key = "gagaodok/e2ee/v1/hkdf-salt", msg = account_master_key),
    info = LP[(1, u16be(1)), (2, "gagaodok/e2ee/v1/attachment-root"), (3, absent)],
    L    = 32)

attachment_field_key = HKDF-Expand(
    PRK  = attachment_root_key,
    info = LP[(1, u16be(1)), (2, "gagaodok/e2ee/v1/attachment-field-aead"), (3, absent)],
    L    = 32)

attachment_wrap_key = HKDF-Expand(
    PRK  = attachment_root_key,
    info = LP[(1, u16be(1)), (2, "gagaodok/e2ee/v1/attachment-file-key-wrap"), (3, absent)],
    L    = 32)
```

`attachment_field_key`는 `file_name`·`mime_type`을 잠그고,
`attachment_wrap_key`는 `wrapped_file_key`를 잠근다.

**기존 `ScopeKeys.attachmentWrapKey`(label `gagaodok/e2ee/v1/attachment-wrap`)는
지우지 않는다.** `tools/fixtures/e2ee_contract_vectors.json`의
`key_derivation.attachment_wrap_key`에 공표된 시험값이 걸려 있다. 대신 Swift·Kotlin
양쪽에 "v1은 이 키를 쓰지 않는다. 첨부는 계정 scope다"라는 주석을 단다. 지우면
시험값이 깨지고, 설명 없이 두면 다음 사람이 잘못 갖다 쓴다.

### 3.4 AAD

encoder 하나로 세 용도를 처리한다. 용도별로 binding slot(field 7) 하나만 달라진다.

```text
encodeAttachmentAAD(account_id, attachment_id, kind, purpose, binding) =
  LP[ (1, u16be(protocol_version = 1)),
      (2, u32be(key_generation   = 1)),
      (3, ascii(canonical_uuid(account_id))),      // 36 bytes
      (4, ascii(canonical_uuid(attachment_id))),   // 36 bytes
      (5, ascii(kind)),                            // "attachment" | "avatar"
      (6, ascii(purpose)),
      (7, binding),                                // 용도별, 없으면 absent
      (8, [algorithm = 1]) ]
```

| purpose | 쓰이는 곳 | 열쇠 | binding(field 7) |
| --- | --- | --- | --- |
| `attachment_content` | R2 object 본문 | `file_key`(무작위 32B) | `u64be(source_byte_size)` |
| `wrapped_file_key` | D1 `wrapped_file_key_enc` | `attachment_wrap_key` | `ciphertext_hash` 원시 32바이트 |
| `file_name` | D1 `file_name_enc` | `attachment_field_key` | absent |
| `mime_type` | D1 `mime_type_enc` | `attachment_field_key` | absent |

`LP`는 기존 `encodeLP`와 동일하다: magic `GDK1`, u16 field 수, field마다
`u16 id · 1바이트 존재 flag · u32 길이 · 바이트`. field id는 순증가한다.
UUID는 raw 16바이트가 아니라 **정규 대문자 문자열의 ASCII 36바이트**다.
이것은 기존 `canonicalUUID` 동작과 같다.

**binding을 넣은 이유는 두 가지다.**

- `source_byte_size`를 본문에 묶으면 잘린 파일이 인증을 통과하지 못한다.
- `ciphertext_hash`를 열쇠 봉투에 묶으면 그 열쇠가 그 object 하나에만 맞는다.
  서버가 같은 `attachment_id` 아래 다른 object를 갈아끼워도 열리지 않는다.
  암호 규격 §10이 "악의적 서버의 rollback은 v1이 막지 않는다"고 인정한 부분인데,
  첨부에서는 추가 비용 없이 막을 수 있다.

**추가 비용이 0인 근거:** `create_attachment`의
`METADATA_RULES.create_attachment.required`가 이미 `ciphertext_hash`,
`source_byte_size`, `kind`, `key_generation`을 allocation 시점에 요구한다. 즉
클라이언트는 어차피 본문을 먼저 암호화하고 해시해야 한다. 그리고 이 값들은 모두
평문 metadata라 **계정의 어느 기기든 projection에서 그대로 읽어 AAD를 재현**할 수 있다.
이것이 설계가 성립하는 핵심 조건이다.

`r2_object_key`는 서버 내부값이고 클라이언트에 반환되지 않으므로 AAD에 넣지 않는다.

### 3.5 봉투

기존 `sealEnvelope`/`openEnvelope`를 그대로 쓴다.

```text
envelope = version(1) ‖ alg(1) ‖ key_generation(4) ‖ nonce(12) ‖ ciphertext ‖ tag(16)
고정 overhead = 34 bytes
```

Worker의 `ATTACHMENT_ENVELOPE_OVERHEAD_BYTES = 34` 및
`ciphertext_byte_size == source_byte_size + 34` 검증과 정확히 일치한다.
`MAX_ATTACHMENT_SOURCE_BYTES = 12,582,912`.

### 3.6 순서

```text
올리기
  1. file_key = CSPRNG(32)
  2. ciphertext = seal(bytes, file_key, nonce, AAD[attachment_content])
  3. ciphertext_hash = SHA-256(ciphertext)
  4. wrapped_file_key = seal(file_key, attachment_wrap_key, nonce2, AAD[wrapped_file_key])
  5. file_name_enc, mime_type_enc = seal(…, attachment_field_key, …)
  6. POST /v1/sync/operations  create_attachment            → allocated
  7. PUT  /v1/attachments/{id}/content                      → uploaded
  8. POST /v1/attachments/{id}/complete                     → ready
  9. ready 확인 뒤에야 bubble의 attachment_ref를 보낸다

받기
  1. projection에서 평문 metadata를 읽는다
  2. GET /v1/attachments/{id}/content
  3. 받은 바이트 수 == ciphertext_byte_size 확인
  4. SHA-256 == ciphertext_hash 확인
  5. file_key 풀기(AAD에 해시 포함) → 본문 풀기(AAD에 원본 크기 포함)
  6. sync/remote/attachments 아래로 원자적 이동
```

bubble이 첨부보다 먼저 나가면 다른 기기에 "볼 수 없는 사진"이 뜬다. 정본 스키마도
"bubble change가 먼저 노출된 뒤 다운로드 불가능한 중간 상태를 허용하지 않는다"고
정했다. 이 순서를 테스트로 고정한다.

카메라 원본·PDF 원본 파일은 **절대 덮어쓰지 않는다.** 복호화 결과는
`sync/remote/attachments` 아래에만 쓴다.

### 3.7 측정 항목

12MB 상한을 한 번의 AES-GCM 호출로 처리할 때의 **최고 메모리 사용량을 실제로 잰다.**
암호 규격 §9.2가 "아직 측정하지 않았다"고 남긴 자리다. 감으로 넘기지 않는다.
측정값은 수용 매트릭스에 기록하고, 단일 호출 유지 여부의 근거로 삼는다.

---

## 4. Task 12 — 방 가족 완결성

### 4.1 현재 결함

`SyncRemoteRoomAssembler`(Swift·Kotlin 모두)가 grouping 단계에서
`room`·`turn`·`bubble` 세 종류만 통과시킨다. 나머지 6종(`group_state`,
`worldline`, `engine_profile`, `persona_snapshot`, `checkpoint`, `attachment`)은
분기에 닿기 전에 걸러져 **조용히 버려진다.** switch의 `default: return nil`은
도달하지 않는다.

`SyncReplicaStore`는 이미 9종 전부를 저장하고 있다. 즉 데이터는 로컬에 있고
assembler만 무시한다. Task 12는 순수 클라이언트 작업이다.

### 4.2 설계

`SyncCanonicalRoomSnapshotBuilder`를 양 플랫폼에 새로 만든다. 방 가족을 조립하고
완결성을 판정하는 책임만 갖는다. assembler는 그 결과를 렌더링한다.

```text
RoomFamily = room
           + optional group_state
           + worldlines (default + named)
           + turns + bubbles
           + 참조된 engine_profile revision들
           + 참조된 persona_snapshot revision/head
           + checkpoints
           + ready 상태 attachment 참조들
```

**필수 참조가 하나라도 없으면 `unsupportedReason`을 달고 이어쓰기를 막는다.**
기본값을 지어내 렌더링하지 않는다. 손상된 방 가족은 그 가족만 막고 다른 방에
번지지 않는다.

`SyncRemoteRoomSnapshot`에 `unsupportedReason: String?`을 추가한다. 저장된 옛
projection과의 호환은 기존 `continuationCapability`와 같은
`decodeIfPresent` 방식으로 유지한다.

Task 11에 의존한다 — 완결성 판정에 "ready 첨부"가 들어간다.

---

## 5. Task 13 — runtime 연결

### 5.1 현재 상태

`aa2cee4`가 만든 `SyncRuntimeCoordinator`는 **자기 파일과 테스트 외에 참조가 0건**이다.
스위치 세 개는 진짜 gate지만 아직 lifecycle에 붙어 있지 않다.

### 5.2 붙일 지점

| 플랫폼 | 파일 | 지점 |
| --- | --- | --- |
| macOS | `Sources/KakaoSapiens/App/KakaoSapiensApp.swift` | `AppDelegate` — 실행 완료, 활성화 복귀 |
| Android | `android/app/src/main/java/com/sapiens/gagaodok/MainActivity.kt` | `onCreate` + lifecycle observer의 `ON_RESUME` |

실행 시점은 **앱 시작 · foreground 복귀 · 수동 새로고침 · 전송 성공 직후** 네 가지뿐이다.
APNs·FCM·background polling을 추가하지 않는다. 단일 실행 잠금과 제한된 backoff를 쓴다.

### 5.3 함께 고치는 것

`SyncRemoteReplyCoordinator`의 `journal` 인자가 현재 `= null` 기본값이고 호출부가
`journal?.prepare(...)`다. 즉 "journal 먼저, outbox 나중"이라는 durable 계약이
**구조로 강제되지 않는다.** 지금은 UI가 항상 journal을 넘겨 실동작에 문제가 없지만,
lifecycle에서 새 호출부가 생기면 조용히 깨진다. **필수 인자로 바꾼다.**

### 5.4 불변식

- 기본값은 계속 전부 꺼짐이다. `SyncPairingCoordinator`·`SyncOnboardingCoordinator`의
  `enabled = false`를 유지한다.
- `syncEnabled = false`면 **네트워크 요청이 한 건도 나가지 않는다.**
  설정 화면이나 원격 방 화면을 열었다는 이유만으로 요청이 나가지 않는다.
- 스위치를 끄는 것은 데이터를 지우는 것이 아니다. replica·로컬 대화·outbox·journal은
  보존된다.
- token 폐기는 runtime을 멈추되 outbox와 journal을 남긴다.
- 상태 UI는 `syncEnabled = false`인 동안 "동기화 중"이라고 **절대 말하지 않는다.**

---

## 6. Task 14 — 로컬 수용

### 6.1 시나리오

`cloudflare/sync-worker/test/complete-cross-device-sync-e2e.spec.ts`와
`tools/fixtures/complete-sync-room-v1.json`으로 결정적 시나리오를 만든다.

MAC이 방을 만든다 → PHONE이 읽는다 → PHONE이 오프라인 상태로 답장하고 재시작한다
→ 큐가 빠진다 → MAC이 읽는다. TABLET-origin 방은 MAC과 PHONE이 읽고 답장한다.
PHONE-origin 방은 다른 곳에서 보이지 않는다. 첨부가 `ready`에 도달한다.
페이지 중복과 raw body 재전송이 무해하다.

실패 주입: 같은 순번 동시 답장, D1 batch rollback, R2 실패, 폐기된 device,
누락된 AI revision, tombstone, 잘못된 origin.

### 6.2 필요한 도구 추가

`tools/run-swift-sync-tests.sh`를 만든다. Swift 테스트 36개를 `swiftc`로 하나씩
컴파일·실행해 통과 개수를 집계한다. 최소한 sync·E2EE 관련 25개는 반드시 포함한다. 이것이 없으면 "Swift suite 전부 통과"를
정직하게 셀 수 없고 Task 14 Step 3을 지어내야 한다. 상위 계획서에 없는 추가이며
2026-09-01 사용자 승인을 받았다.

### 6.3 기록

`docs/PHASE1_INTEGRATION_ACCEPTANCE_MATRIX.md`에 **실제로 실행한 명령과 결과만**
적는다. 개수·환경·JDK 버전을 그대로 적고, 실행하지 않은 항목은 미실행이라고 적는다.

fixture에는 실제 대화·token·복구 문구·production endpoint가 들어가지 않는다.
합성 식별자는 한눈에 가짜임이 보여야 한다(`A0000000-…`, `70000000-…` 형식).

---

## 7. Task 15 — 합성 원격 gate

### 7.1 정지 지점

**Task 14를 끝낸 뒤 여기서 멈추고 사용자 승인을 다시 받는다.** 상위 계획서가
요구하는 승인 문구는 정해져 있다: **Worker 배포, 원격 D1 migration 0011·0012,
합성 smoke**를 이름으로 지목해야 한다.

**로그인은 사용자가 직접 한다.** 2026-08-29 gate와 같다. 비밀번호·2FA를 대신
입력하지 않는다.

### 7.2 순서

1. migration `0011_room_origin_expand.sql` 적용, 원장과 스키마 확인
2. 호환 Worker 배포, 확인
3. migration `0012_room_origin_enforce.sql` 적용, 확인

세 단계를 한 스크립트로 뭉뚱그리지 않는다. 각 단계 뒤에 상태를 따로 확인한다.

### 7.3 smoke — 기존 것을 다시 돌리고, 두 가지만 새로 쓴다

`scripts/remote-smoke.mjs`는 이미 31개 검사를 갖고 있고 2026-08-29에 원격에서 전부
통과했다. **이미 덮고 있는 것**(다시 쓸 필요가 없다):

- 첨부 `create_attachment` → PUT → complete → download, 길이 일치, `private, no-store`
- 폐기된 기기가 네 endpoint 전부에서 `DEVICE_REVOKED`로 거부됨(첨부 다운로드 포함)
- 다른 계정의 접근 차단, operation 재전송 idempotency, CAS `409`, bootstrap 다중 페이지
- health, content-free 오류, 토큰 없는 요청 `401`, 응답에 비밀 미노출

0012가 `room`에 트리거 두 개를 걸므로, 이 스크립트를 그대로 재실행하는 것 자체가
방 생성부터 첨부까지의 회귀 검사가 된다.

**새로 쓰는 것은 두 가지뿐이다.**

| 검사 | 왜 빼면 안 되나 |
| --- | --- |
| origin 노출 matrix | 0011·0012가 강제하는 바로 그 규칙이다. 강제 migration을 넣고 강제를 확인하지 않을 수 없다 |
| 답장 수렴 | Task 9–13이 만든 핵심 동작이고 기존 smoke에 없다. 깨지면 사용자가 서로 다른 대화를 본다 |

**의도적으로 빼는 것과 근거.** `0011_room_origin_expand.sql`과 `0012_room_origin_enforce.sql`을
읽어 확인했다 — 둘 다 `room` 테이블만 건드리며(컬럼 추가, UPDATE, 트리거 2개)
`rate_limit`·`device`를 한 번도 언급하지 않는다.

- **첨부 원격 검사 신규 작성** — Worker/R2 경로는 기존 스크립트가 끝까지 덮는다.
  이번에 바뀐 것은 클라이언트 암호이고, 그것은 교차언어 벡터와 로컬 E2E가 덮는다.
- **device 폐기 신규 작성** — 기존 스크립트가 첨부 다운로드까지 포함해 이미 덮는다.
- **rate limit `429` 능동 시험** — migration이 건드리지 않고, 능동 시험은 합성 환경의
  rate 예산을 실제로 소진해 같은 실행의 나머지 검사를 흔든다.

로그에 내용이 남지 않게 한다.

### 7.4 유지보수 점검

유지보수 *로직*은 이미 로컬 `test/maintenance-cleanup.spec.ts` 3개 테스트가 덮는다
(`runMaintenance(env, now)`가 시각을 주입받는다). 원격이 추가로 증명하는 것은 둘뿐이다:
cron trigger가 배포본에 실제로 걸려 `scheduled()`가 불리는지, 그리고 진짜 R2의
`list()` 페이지네이션과 bulk `delete()`가 Miniflare 흉내와 같게 동작하는지.

둘째가 중요한 이유는 이 코드가 **데이터를 지우기** 때문이다. 틀리면 아직 참조 중인
첨부를 지운다. 그리고 이 저장소는 로컬 877개가 통과하는데도 원격에서만 깨진
`complete` route를 이미 겪었다.

**cron 정시를 기다리지 않는다.** `wrangler dev --remote --test-scheduled`로 `/__scheduled`를
직접 호출한다. 이 조합이 원격 binding에서 동작하지 않으면 그때만 하루 전 `created_at`을
심고 다음 정시 한 번을 기다린다. 참조된 R2 object가 지워지지 않는지 함께 확인한다.

결과는 `docs/COMPLETE_SYNC_SYNTHETIC_REMOTE_RESULT.md`에 자원 ID와 버전 해시와 함께
기록한다.

---

## 8. 검증 매트릭스

| 대상 | 검사 |
| --- | --- |
| 암호 계약 | `tools/fixtures/e2ee_contract_vectors.json`의 새 `attachment` 절을 Swift `E2EEContractVectorTests`와 Kotlin `E2EEContractVectorTest`가 **둘 다** 통과 |
| Swift 로직 | 해당 `Tests/` 실행파일 개별 실행 + 마지막에 `swift build` 1회 |
| Android | Gradle이 보고하는 JVM을 **먼저 확인**한다. 별도 요구가 없으면 JDK 17. 영향받는 variant만 빌드·테스트 |
| Worker·D1 | `npm test -- --run`, `npm run typecheck`. 전부 로컬 workerd/Miniflare. 원격 binding 금지 |
| UI | **미검증.** 설치하지 않으므로 확인해야 할 흐름을 목록으로 남긴다 |
| 마무리 | `git diff --check` + 좁은 diff 검토 |

---

## 9. 커밋

```text
Task 11 → feat: 원격 방 첨부파일 동기화를 연결한다
Task 12 → feat: 원격 방의 세계선과 versioned AI state를 완성한다
Task 13 → feat: foreground sync runtime과 단계별 kill switch를 추가한다
Task 14 → test: 완전 동기화 local E2E gate를 닫는다
────────── 정지 · 사용자 승인 ──────────
Task 15 → docs: 완전 동기화 합성 원격 gate를 기록한다
```

commit만 하고 push하지 않는다. 각 커밋은 요약 한 줄 + 빈 줄 + 본문이며, 본문은
다음 작업자가 이 대화를 전혀 보지 못한다고 가정하고 쓴다.

---

## 10. 남은 위험

1. **UI 미검증이 Task 11·13에 남는다.** 첨부 상태 4종(pending·ready·재시도·불가)과
   동기화 상태 표시는 설치 없이는 확인할 수 없다. Task 16에서 승인받아 한 번에
   처리한다.
2. **12MB 단일 호출 메모리가 아직 미지수다.** §3.7에서 재고, 결과가 나쁘면 상한
   조정이나 chunked 도입을 별도 결정으로 올린다. v1 범위에서 임의로 chunked를
   도입하지 않는다.
3. **Task 15는 사용자가 곁에 있어야 시작된다.** 로그인 없이는 첫 단계도 못 뗀다.
4. **Task 12가 Task 11에 의존한다.** 순서를 바꾸면 완결성 판정에 구멍이 남는다.
