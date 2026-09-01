# 완전 동기화 Task 11–15 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 원격 방의 첨부파일 동기화와 방 가족 완결성을 완성하고, sync runtime을 앱 lifecycle에 연결한 뒤, 로컬 전체 수용과 격리된 합성 Cloudflare 검증까지 닫는다.

**Architecture:** 첨부 키를 방과 무관한 계정 scope에서 유도해 정본 identity `(account_id, attachment_id)`와 일치시킨다. Worker·D1·R2 경로는 이미 완성돼 있으므로 클라이언트만 붙인다. 방 가족 완결성은 새 snapshot builder가 판정하고, 참조가 비면 기본값을 지어내지 않고 `unsupportedReason`으로 이어쓰기를 막는다. runtime은 foreground 계기에서만 돌고 기본값은 전부 꺼짐이다.

**Tech Stack:** Swift 5 / SwiftUI / CryptoKit (macOS), Kotlin / Jetpack Compose / JUnit4 (Android), TypeScript / Cloudflare Workers / D1 / R2 / Vitest / Miniflare (Worker)

**Spec:** `docs/superpowers/specs/2026-09-01-complete-sync-task11-15-design.md`

**상위 계획:** `docs/superpowers/plans/2026-08-31-complete-cross-device-sync.md` (Task 번호의 출처)

**기준 커밋:** `aaa70a0`

---

## Global Constraints

이 절의 값은 모든 Task에 암묵적으로 포함된다. 값은 설계 문서에서 그대로 옮겼다.

- **언어** — 사용자에게 보이는 글과 문서는 한국어. 식별자·label·명령·경로·커밋 요약은 영어. 코드 주석은 주변 코드 언어를 따른다.
- **암호 protocol** — `protocol_version = 1`, `algorithm = 1`, `key_generation = 1`. 봉투 고정 overhead **34 bytes**(`version 1 + alg 1 + key_generation 4 + nonce 12 + tag 16`).
- **첨부 상한** — `MAX_ATTACHMENT_SOURCE_BYTES = 12,582,912`, `MAX_ENCRYPTED_OBJECT_BYTES = 12,582,946`. `ciphertext_byte_size == source_byte_size + 34` (등식이며 부등식이 아니다).
- **HKDF label** (신규 3종, 오타 금지):
  - `gagaodok/e2ee/v1/attachment-root`
  - `gagaodok/e2ee/v1/attachment-field-aead`
  - `gagaodok/e2ee/v1/attachment-file-key-wrap`
- **기존 label 보존** — `gagaodok/e2ee/v1/attachment-wrap`(scope 하위 키)은 **삭제하지 않는다.** 공표된 시험값이 걸려 있다. v1 미사용이라는 주석만 단다.
- **space_id 허용값** — `MAC_SPACE`, `PHONE_SPACE`, `TABLET_SPACE`. 그 외는 거부.
- **UUID 인코딩** — LP 안에서 UUID는 raw 16바이트가 아니라 **정규 대문자 문자열의 ASCII 36바이트**다. 기존 `canonicalUUID` 동작과 같다.
- **노출 정책** — phone-origin 방은 다른 곳에서 숨김. Mac-origin은 phone에만. tablet-origin은 Mac과 phone에.
- **기본값** — 모든 연결 설정은 `enabled = false`. `syncEnabled = false`면 네트워크 요청이 한 건도 나가지 않는다.
- **금지** — 앱 설치, Cloudflare 배포(Task 8 전까지), `--remote` 명령(Task 8 전까지), 실제 대화·첨부·복구 문구 접근, app-data 삭제, push, merge, chunked AEAD 도입.
- **작업 중 파일 보존** — `package_for_sharing.sh`, `tools/costsim.py`의 기존 수정과 모든 untracked 파일은 stage·수정·삭제·reset하지 않는다.
- **합성 식별자** — 한눈에 가짜임이 보여야 한다. 계정 `A0000000-…`, 첨부 `70000000-…`, 방 `10000000-…`, 기기 `80000000-…`.
- **Android JDK** — 작업 시작 시 Gradle이 보고하는 JVM을 **먼저 확인**한다. 별도 요구가 없으면 JDK 17. 불일치는 우회하지 말고 보고한다.
- **Worker 검사** — `cloudflare/sync-worker/`에서 `npm test -- --run`과 `npm run typecheck`. 전부 로컬 workerd/Miniflare. 원격 binding 금지.
- **UI 보고** — 앱을 설치하지 않으므로 화면이 걸린 항목은 **미검증**이라고 적고 확인해야 할 흐름을 명시한다. 빌드 성공을 화면 확인으로 바꿔 쓰지 않는다.
- **커밋** — commit만 하고 push하지 않는다. 요약 한 줄 + 빈 줄 + 본문. 본문은 다음 작업자가 이 대화를 전혀 못 본다고 가정하고 쓴다.

---

## File Structure

### 새로 만드는 파일

| 경로 | 책임 |
| --- | --- |
| `Tests/KakaoSapiensE2EEContractTests/AttachmentContractVectorTests.swift` | 첨부 암호 계약 벡터를 Swift가 재현하는지 검증 |
| `android/app/src/test/java/com/sapiens/gagaodok/sync/AttachmentContractVectorTest.kt` | 같은 벡터를 Kotlin이 재현하는지 검증 |
| `tools/generate-attachment-vectors.swift` | 벡터 생성기(1회성, 결과물을 커밋) |
| `Sources/KakaoSapiens/Services/SyncAttachmentTransferCoordinator.swift` | 첨부 올리기·받기 순서와 검증 |
| `Tests/KakaoSapiensSyncOutboxTests/SyncAttachmentTransferCoordinatorTests.swift` | 위의 순서·검증 테스트 |
| `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncAttachmentTransferCoordinator.kt` | Swift와 동일 책임 |
| `android/app/src/test/java/com/sapiens/gagaodok/sync/SyncAttachmentTransferCoordinatorTest.kt` | 위의 테스트 |
| `Sources/KakaoSapiens/Services/SyncCanonicalRoomSnapshotBuilder.swift` | 방 가족 조립과 완결성 판정 |
| `Tests/KakaoSapiensSyncOutboxTests/SyncCanonicalRoomSnapshotBuilderTests.swift` | 완결/불완전 fixture 테스트 |
| `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncCanonicalRoomSnapshotBuilder.kt` | Swift와 동일 책임 |
| `android/app/src/test/java/com/sapiens/gagaodok/sync/SyncCanonicalRoomSnapshotBuilderTest.kt` | 위의 테스트 |
| `tools/run-swift-sync-tests.sh` | Swift `@main` 테스트 36개를 컴파일·실행·집계 |
| `cloudflare/sync-worker/test/complete-cross-device-sync-e2e.spec.ts` | 로컬 합성 전체 시나리오 |
| `tools/fixtures/complete-sync-room-v1.json` | 위 시나리오의 결정적 fixture |
| `docs/COMPLETE_SYNC_SYNTHETIC_REMOTE_RESULT.md` | Task 8 결과 기록 |

### 고치는 파일

| 경로 | 무엇을 |
| --- | --- |
| `Sources/KakaoSapiens/Services/SyncE2EE.swift` | 첨부 키 유도·AAD·봉투 wrapper 추가, 기존 `attachmentWrapKey`에 미사용 주석 |
| `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncE2EE.kt` | 위와 동일 |
| `tools/fixtures/e2ee_contract_vectors.json` | `attachment` 절 추가 |
| `Sources/KakaoSapiens/Services/SyncWorkerClient.swift` | 첨부 endpoint 3종 추가 |
| `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncWorkerClient.kt` | 위와 동일 |
| `Sources/KakaoSapiens/Services/SyncRemoteRoomTypes.swift` | `unsupportedReason` 추가 |
| `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncRemoteRoomTypes.kt` | 위와 동일 |
| `Sources/KakaoSapiens/Services/SyncRemoteRoomAssembler.swift` | builder 결과를 렌더링하도록 변경 |
| `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncRemoteRoomAssembler.kt` | 위와 동일 |
| `Sources/KakaoSapiens/Services/SyncRemoteReplyCoordinator.swift` | journal을 필수 인자로 |
| `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncRemoteReplyCoordinator.kt` | 위와 동일 |
| `Sources/KakaoSapiens/App/KakaoSapiensApp.swift` | runtime lifecycle 연결 |
| `android/app/src/main/java/com/sapiens/gagaodok/MainActivity.kt` | 위와 동일 |
| `Sources/KakaoSapiens/Views/RemoteChatRoomView.swift` | 첨부 상태·동기화 상태 UI |
| `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/RemoteChatRoomScreen.kt` | 위와 동일 |
| `cloudflare/sync-worker/scripts/remote-smoke-lib.mjs` | 합성 원격 smoke 확장 |
| `docs/PHASE1_INTEGRATION_ACCEPTANCE_MATRIX.md` | 실제 실행한 검사만 기록 |

### Task 지도

| Task | 상위 계획 번호 | 산출물 |
| --- | --- | --- |
| 1 | 11 | 첨부 암호 계약 + 교차언어 벡터 |
| 2 | 11 | Worker 클라이언트 첨부 endpoint |
| 3 | 11 | 첨부 전송 코디네이터 + 메모리 측정 |
| 4 | 11 | 첨부 UI 상태 (미검증) + Task 11 커밋 |
| 5 | 12 | 방 가족 완결성 |
| 6 | 13 | runtime lifecycle + journal 필수화 |
| 7 | 14 | 로컬 수용 + Swift 테스트 러너 |
| 8 | 15 | 합성 원격 gate (**승인 후에만**) |

---
## Task 1: 첨부 암호 계약과 교차언어 벡터

첨부 코디네이터보다 **먼저** 한다. Swift와 Kotlin이 같은 바이트를 만드는지 확인한 뒤에야
전송 코드를 쓴다. 순서를 뒤집으면 "각자 잘 도는데 서로 못 여는" 상태를 늦게 발견한다.

**Files:**
- Modify: `Sources/KakaoSapiens/Services/SyncE2EE.swift`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncE2EE.kt`
- Modify: `tools/fixtures/e2ee_contract_vectors.json`
- Create: `tools/generate-attachment-vectors.swift`
- Create: `Tests/KakaoSapiensE2EEContractTests/AttachmentContractVectorTests.swift`
- Create: `android/app/src/test/java/com/sapiens/gagaodok/sync/AttachmentContractVectorTest.kt`

**Interfaces:**
- Consumes: 기존 private helper `hkdfSHA256(ikm:label:)`, `derivedKey(label:scopeRoot:)`,
  `encodeLP(_:)`, `canonicalUUID(_:)`, `ascii(_:)`, `sealEnvelope(...)`, `openEnvelope(...)`.
  **새 원시 연산을 도입하지 않는다.**
- Produces: 아래 API를 Task 3이 그대로 쓴다.

```swift
// Swift
SyncE2EE.AttachmentKeys(attachmentRootKey: Data, attachmentFieldAEADKey: Data, attachmentWrapKey: Data)
// enum SyncE2EE가 internal이므로, public API가 노출할 타입은 파일 최상위에 둔다.
public enum SyncAttachmentKind: String { case attachment, avatar }
public enum SyncAttachmentField: String { case fileName = "file_name", mimeType = "mime_type" }

static func deriveAttachmentKeys(accountMasterKey: Data) throws -> AttachmentKeys
static func attachmentContentAAD(accountID: String, attachmentID: String, kind: SyncAttachmentKind, sourceByteSize: UInt64) throws -> Data
static func attachmentWrapAAD(accountID: String, attachmentID: String, kind: SyncAttachmentKind, ciphertextHash: Data) throws -> Data
static func attachmentFieldAAD(accountID: String, attachmentID: String, kind: SyncAttachmentKind, field: SyncAttachmentField) throws -> Data
static func sealAttachment(plaintext: Data, key: Data, nonce: Data, aad: Data) throws -> Data
static func openAttachment(envelope: Data, key: Data, aad: Data) throws -> Data
```

```kotlin
// Kotlin — 이름과 인자 순서를 Swift와 정확히 맞춘다
SyncE2EE.AttachmentKeys(attachmentRootKey: ByteArray, attachmentFieldAeadKey: ByteArray, attachmentWrapKey: ByteArray)
enum class AttachmentKind(val wire: String) { ATTACHMENT("attachment"), AVATAR("avatar") }
enum class AttachmentField(val wire: String) { FILE_NAME("file_name"), MIME_TYPE("mime_type") }

fun deriveAttachmentKeys(accountMasterKey: ByteArray): AttachmentKeys
fun attachmentContentAad(accountId: String, attachmentId: String, kind: AttachmentKind, sourceByteSize: Long): ByteArray
fun attachmentWrapAad(accountId: String, attachmentId: String, kind: AttachmentKind, ciphertextHash: ByteArray): ByteArray
fun attachmentFieldAad(accountId: String, attachmentId: String, kind: AttachmentKind, field: AttachmentField): ByteArray
fun sealAttachment(plaintext: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray
fun openAttachment(envelope: ByteArray, key: ByteArray, aad: ByteArray): ByteArray
```

**벡터에 쓰는 합성 값** (기존 벡터와 일부러 공유해 교차 확인이 가능하게 한다):

| 항목 | 값 |
| --- | --- |
| `account_master_key` | `tools/fixtures/e2ee_contract_vectors.json`의 `recovery.account_master_key_hex` 그대로 |
| `account_id` | `11111111-1111-4111-8111-111111111111` (기존 `field_aead.account_id`) |
| `attachment_id` | `70000000-0000-4000-8000-000000000001` |
| `kind` | `attachment` |
| `source_byte_size` | `96` |
| content nonce | `000102030405060708090a0b` |
| wrap nonce | `0c0d0e0f1011121314151617` (12바이트) |
| 본문 평문 | `0x00`부터 `0x5F`까지 96바이트 오름차순 |
| `file_key` | `0x40`이 32번 반복 |

- [ ] **Step 1: Swift에 첨부 키 유도와 AAD를 추가한다**

`Sources/KakaoSapiens/Services/SyncE2EE.swift`에 넣는다.

**먼저 파일 최상위에**(`enum SyncE2EE {` 블록 **밖**, `import` 아래) 두 enum을 둔다.
`enum SyncE2EE`는 internal이므로 그 안에 두면 Task 3의 `public struct SyncAttachmentPlan`이
이 타입을 노출할 수 없어 컴파일되지 않는다.

```swift
/// 첨부 종류. public API가 노출하므로 SyncE2EE 안이 아니라 파일 최상위에 둔다.
public enum SyncAttachmentKind: String {
    case attachment
    case avatar
}

public enum SyncAttachmentField: String {
    case fileName = "file_name"
    case mimeType = "mime_type"
}
```

**그다음** 아래를 `enum SyncE2EE` 안, `ScopeKeys` 정의 바로 아래에 넣는다.

```swift
    /// 첨부는 방에 속하지 않는다.
    ///
    /// 정본 identity가 `(account_id, attachment_id)`이고 `create_attachment`가
    /// `room_id`를 금지하므로, 방 scope로는 받는 기기가 열쇠를 재현할 수 없다.
    /// recovery·pairing이 쓰는 계정 단위 유도와 같은 모양이다.
    struct AttachmentKeys: Equatable {
        let attachmentRootKey: Data
        let attachmentFieldAEADKey: Data
        let attachmentWrapKey: Data
    }

    private enum AttachmentPurpose: String {
        case content = "attachment_content"
        case wrappedFileKey = "wrapped_file_key"
    }

    static func deriveAttachmentKeys(accountMasterKey: Data) throws -> AttachmentKeys {
        guard accountMasterKey.count == 32 else { throw ContractError.invalidAccountMasterKey }
        let root = try hkdfSHA256(ikm: accountMasterKey, label: "gagaodok/e2ee/v1/attachment-root")
        return AttachmentKeys(
            attachmentRootKey: root,
            attachmentFieldAEADKey: try derivedKey(label: "gagaodok/e2ee/v1/attachment-field-aead", scopeRoot: root),
            attachmentWrapKey: try derivedKey(label: "gagaodok/e2ee/v1/attachment-file-key-wrap", scopeRoot: root)
        )
    }

    private static func encodeAttachmentAAD(
        accountID: String, attachmentID: String, kind: SyncAttachmentKind,
        purpose: String, binding: Data?
    ) throws -> Data {
        try encodeLP([
            (1, Data(protocolVersion.bigEndianBytes)),
            (2, Data(keyGeneration.bigEndianBytes)),
            (3, canonicalUUID(accountID)),
            (4, canonicalUUID(attachmentID)),
            (5, try ascii(kind.rawValue)),
            (6, try ascii(purpose)),
            (7, binding),
            (8, Data([algorithm])),
        ])
    }

    /// 원본 크기를 묶으므로 잘린 파일은 인증을 통과하지 못한다.
    static func attachmentContentAAD(
        accountID: String, attachmentID: String,
        kind: SyncAttachmentKind, sourceByteSize: UInt64
    ) throws -> Data {
        try encodeAttachmentAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind,
            purpose: AttachmentPurpose.content.rawValue,
            binding: Data(sourceByteSize.bigEndianBytes)
        )
    }

    /// 암호문 해시를 묶으므로 이 열쇠는 그 object 하나에만 맞는다.
    /// 서버가 같은 attachment_id 아래 다른 object를 갈아끼워도 열리지 않는다.
    static func attachmentWrapAAD(
        accountID: String, attachmentID: String,
        kind: SyncAttachmentKind, ciphertextHash: Data
    ) throws -> Data {
        guard ciphertextHash.count == 32 else { throw ContractError.invalidIdentity }
        return try encodeAttachmentAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind,
            purpose: AttachmentPurpose.wrappedFileKey.rawValue,
            binding: ciphertextHash
        )
    }

    static func attachmentFieldAAD(
        accountID: String, attachmentID: String,
        kind: SyncAttachmentKind, field: SyncAttachmentField
    ) throws -> Data {
        try encodeAttachmentAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind,
            purpose: field.rawValue, binding: nil
        )
    }

    static func sealAttachment(plaintext: Data, key: Data, nonce: Data, aad: Data) throws -> Data {
        try sealEnvelope(plaintext: plaintext, key: key, nonce: nonce, aad: aad)
    }

    static func openAttachment(envelope: Data, key: Data, aad: Data) throws -> Data {
        try openEnvelope(envelope: envelope, key: key, aad: aad)
    }
```

같은 파일의 `ScopeKeys.attachmentWrapKey` 선언 줄 위에 주석을 단다. **지우지 않는다** —
`tools/fixtures/e2ee_contract_vectors.json`의 `key_derivation.attachment_wrap_key`에
공표된 시험값이 걸려 있다.

```swift
        /// v1 미사용. 첨부는 방이 아니라 계정 scope다 — `deriveAttachmentKeys`를 쓴다.
        /// 공표된 계약 벡터를 유지하기 위해 유도만 남겨 둔다.
        let attachmentWrapKey: Data
```

- [ ] **Step 2: 벡터 생성기를 쓴다**

`tools/generate-attachment-vectors.swift`를 만든다. 1회성 도구이고 결과 JSON을 커밋한다.

```swift
import Foundation
import CryptoKit

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
private func unhex(_ string: String) -> Data {
    var out = Data(); var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        out.append(UInt8(string[index..<next], radix: 16)!); index = next
    }
    return out
}

@main struct Generate {
    static func main() throws {
        let masterKeyHex = CommandLine.arguments[1]      // recovery.account_master_key_hex
        let masterKey = unhex(masterKeyHex)
        let accountID = "11111111-1111-4111-8111-111111111111"
        let attachmentID = "70000000-0000-4000-8000-000000000001"
        let kind = SyncAttachmentKind.attachment
        let plaintext = Data((0..<96).map { UInt8($0) })
        let fileKey = Data(repeating: 0x40, count: 32)
        let contentNonce = unhex("000102030405060708090a0b")
        let wrapNonce = unhex("0c0d0e0f1011121314151617")

        let keys = try SyncE2EE.deriveAttachmentKeys(accountMasterKey: masterKey)
        let contentAAD = try SyncE2EE.attachmentContentAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind,
            sourceByteSize: UInt64(plaintext.count))
        let content = try SyncE2EE.sealAttachment(
            plaintext: plaintext, key: fileKey, nonce: contentNonce, aad: contentAAD)
        let ciphertextHash = Data(SHA256.hash(data: content))
        let wrapAAD = try SyncE2EE.attachmentWrapAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind,
            ciphertextHash: ciphertextHash)
        let wrapped = try SyncE2EE.sealAttachment(
            plaintext: fileKey, key: keys.attachmentWrapKey, nonce: wrapNonce, aad: wrapAAD)
        let nameAAD = try SyncE2EE.attachmentFieldAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, field: .fileName)

        let vector: [String: Any] = [
            "account_id": accountID,
            "attachment_id": attachmentID,
            "kind": kind.rawValue,
            "source_byte_size": plaintext.count,
            "ciphertext_byte_size": content.count,
            "attachment_root_key_hex": hex(keys.attachmentRootKey),
            "attachment_field_aead_key_hex": hex(keys.attachmentFieldAEADKey),
            "attachment_wrap_key_hex": hex(keys.attachmentWrapKey),
            "content_aad_hex": hex(contentAAD),
            "content_nonce_hex": hex(contentNonce),
            "content_plaintext_hex": hex(plaintext),
            "content_envelope_hex": hex(content),
            "ciphertext_hash_hex": hex(ciphertextHash),
            "file_key_hex": hex(fileKey),
            "wrap_aad_hex": hex(wrapAAD),
            "wrap_nonce_hex": hex(wrapNonce),
            "wrapped_file_key_envelope_hex": hex(wrapped),
            "file_name_aad_hex": hex(nameAAD),
        ]
        let json = try JSONSerialization.data(withJSONObject: vector, options: [.sortedKeys])
        print(String(data: json, encoding: .utf8)!)
    }
}
```

실행:

```bash
MK=$(node -e "console.log(require('./tools/fixtures/e2ee_contract_vectors.json').recovery.account_master_key_hex)")
swiftc -parse-as-library Sources/KakaoSapiens/Services/SyncE2EE.swift tools/generate-attachment-vectors.swift -o /tmp/gen-attach
/tmp/gen-attach "$MK" > /tmp/attachment-vector.json
cat /tmp/attachment-vector.json
```

- [ ] **Step 3: 독립 구현으로 HKDF 사슬을 교차 확인한다**

Swift와 Kotlin이 **같은 버그를 공유**하는 경우를 막는다. node의 `crypto`로 첫 유도를
따로 계산해 `attachment_root_key_hex`와 대조한다.

```bash
node -e '
const c = require("crypto");
const MK = Buffer.from(process.argv[1], "hex");
function lp(fields) {
  const parts = [Buffer.from("GDK1"), Buffer.alloc(2)];
  parts[1].writeUInt16BE(fields.length, 0);
  for (const [id, val] of fields) {
    const head = Buffer.alloc(2); head.writeUInt16BE(id, 0);
    if (val === null) { const z = Buffer.alloc(5); parts.push(head, z); continue; }
    const len = Buffer.alloc(5); len.writeUInt8(1, 0); len.writeUInt32BE(val.length, 1);
    parts.push(head, len, val);
  }
  return Buffer.concat(parts);
}
const ver = Buffer.alloc(2); ver.writeUInt16BE(1, 0);
const info = lp([[1, ver], [2, Buffer.from("gagaodok/e2ee/v1/attachment-root")], [3, null]]);
const prk = c.createHmac("sha256", Buffer.from("gagaodok/e2ee/v1/hkdf-salt")).update(MK).digest();
const t1 = c.createHmac("sha256", prk).update(Buffer.concat([info, Buffer.from([1])])).digest();
console.log(t1.toString("hex"));
' "$MK"
```

기대: 위 출력이 Step 2의 `attachment_root_key_hex`와 **정확히 같다.**
다르면 멈춘다. LP 인코딩이나 label 문자열이 어긋난 것이다.

- [ ] **Step 4: 벡터를 fixture에 병합한다**

Step 2의 출력을 `tools/fixtures/e2ee_contract_vectors.json`의 최상위 `attachment` 키로
넣는다. `classification`은 `SYNTHETIC_ONLY` 그대로 두고 기존 절은 건드리지 않는다.

```bash
node -e '
const fs = require("fs");
const p = "tools/fixtures/e2ee_contract_vectors.json";
const doc = JSON.parse(fs.readFileSync(p, "utf8"));
doc.attachment = JSON.parse(fs.readFileSync("/tmp/attachment-vector.json", "utf8"));
fs.writeFileSync(p, JSON.stringify(doc));
'
```

- [ ] **Step 5: Swift 벡터 테스트를 쓰고 실패를 확인한다**

`Tests/KakaoSapiensE2EEContractTests/AttachmentContractVectorTests.swift`:

```swift
import Foundation
import CryptoKit

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}
private func unhex(_ string: String) -> Data {
    var out = Data(); var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        out.append(UInt8(string[index..<next], radix: 16)!); index = next
    }
    return out
}

@main private struct Runner {
    static func main() throws {
        let url = URL(fileURLWithPath: "tools/fixtures/e2ee_contract_vectors.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let vector = root["attachment"] as! [String: Any]
        let master = unhex((root["recovery"] as! [String: Any])["account_master_key_hex"] as! String)
        let accountID = vector["account_id"] as! String
        let attachmentID = vector["attachment_id"] as! String
        let kind = SyncAttachmentKind(rawValue: vector["kind"] as! String)!

        let keys = try SyncE2EE.deriveAttachmentKeys(accountMasterKey: master)
        try check(keys.attachmentRootKey == unhex(vector["attachment_root_key_hex"] as! String),
                  "attachment root key drifted")
        try check(keys.attachmentWrapKey == unhex(vector["attachment_wrap_key_hex"] as! String),
                  "attachment wrap key drifted")
        try check(keys.attachmentFieldAEADKey == unhex(vector["attachment_field_aead_key_hex"] as! String),
                  "attachment field key drifted")

        let contentAAD = try SyncE2EE.attachmentContentAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind,
            sourceByteSize: UInt64(vector["source_byte_size"] as! Int))
        try check(contentAAD == unhex(vector["content_aad_hex"] as! String), "content AAD drifted")

        let envelope = unhex(vector["content_envelope_hex"] as! String)
        let opened = try SyncE2EE.openAttachment(
            envelope: envelope, key: unhex(vector["file_key_hex"] as! String), aad: contentAAD)
        try check(opened == unhex(vector["content_plaintext_hex"] as! String), "content did not round-trip")
        try check(envelope.count == (vector["source_byte_size"] as! Int) + 34, "envelope overhead is not 34")

        let hash = Data(SHA256.hash(data: envelope))
        try check(hash == unhex(vector["ciphertext_hash_hex"] as! String), "ciphertext hash drifted")

        let wrapAAD = try SyncE2EE.attachmentWrapAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, ciphertextHash: hash)
        try check(wrapAAD == unhex(vector["wrap_aad_hex"] as! String), "wrap AAD drifted")
        let fileKey = try SyncE2EE.openAttachment(
            envelope: unhex(vector["wrapped_file_key_envelope_hex"] as! String),
            key: keys.attachmentWrapKey, aad: wrapAAD)
        try check(fileKey == unhex(vector["file_key_hex"] as! String), "file key did not unwrap")

        // 다른 object로 바꿔치기하면 열쇠가 안 맞아야 한다.
        var tampered = hash; tampered[0] ^= 0x01
        let tamperedAAD = try SyncE2EE.attachmentWrapAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, ciphertextHash: tampered)
        var swapRejected = false
        do {
            _ = try SyncE2EE.openAttachment(
                envelope: unhex(vector["wrapped_file_key_envelope_hex"] as! String),
                key: keys.attachmentWrapKey, aad: tamperedAAD)
        } catch { swapRejected = true }
        try check(swapRejected, "a swapped object still unwrapped the file key")

        let nameAAD = try SyncE2EE.attachmentFieldAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, field: .fileName)
        try check(nameAAD == unhex(vector["file_name_aad_hex"] as! String), "file_name AAD drifted")
        try check(nameAAD != (try SyncE2EE.attachmentFieldAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, field: .mimeType)),
            "file_name and mime_type share an AAD")

        print("12 attachment contract vector checks passed")
    }
}
```

- [ ] **Step 6: Swift 벡터 테스트를 실행한다**

```bash
swiftc -parse-as-library Sources/KakaoSapiens/Services/SyncE2EE.swift Tests/KakaoSapiensE2EEContractTests/AttachmentContractVectorTests.swift -o /tmp/attach-vectors && /tmp/attach-vectors
```

기대: `12 attachment contract vector checks passed`

- [ ] **Step 7: Kotlin에 같은 계약을 추가한다**

`android/app/src/main/java/com/sapiens/gagaodok/sync/SyncE2EE.kt`의 `ScopeKeys` 아래.
label 문자열과 field 순서가 Swift와 **한 글자도 달라선 안 된다.**

```kotlin
    /** 첨부는 방에 속하지 않는다. 정본 identity가 (account_id, attachment_id)다. */
    data class AttachmentKeys(
        val attachmentRootKey: ByteArray,
        val attachmentFieldAeadKey: ByteArray,
        val attachmentWrapKey: ByteArray,
    )

    enum class AttachmentKind(val wire: String) { ATTACHMENT("attachment"), AVATAR("avatar") }
    enum class AttachmentField(val wire: String) { FILE_NAME("file_name"), MIME_TYPE("mime_type") }

    fun deriveAttachmentKeys(accountMasterKey: ByteArray): AttachmentKeys {
        require(accountMasterKey.size == 32) { "invalid account master key" }
        val root = hkdfSha256(accountMasterKey, "gagaodok/e2ee/v1/attachment-root")
        return AttachmentKeys(
            attachmentRootKey = root,
            attachmentFieldAeadKey = derivedKey("gagaodok/e2ee/v1/attachment-field-aead", root),
            attachmentWrapKey = derivedKey("gagaodok/e2ee/v1/attachment-file-key-wrap", root),
        )
    }

    private fun attachmentAad(
        accountId: String, attachmentId: String, kind: AttachmentKind,
        purpose: String, binding: ByteArray?,
    ): ByteArray = encodeLP(
        listOf(
            1 to u16be(PROTOCOL_VERSION),
            2 to u32be(KEY_GENERATION),
            3 to canonicalUuid(accountId),
            4 to canonicalUuid(attachmentId),
            5 to ascii(kind.wire),
            6 to ascii(purpose),
            7 to binding,
            8 to byteArrayOf(ALGORITHM),
        ),
    )

    fun attachmentContentAad(
        accountId: String, attachmentId: String,
        kind: AttachmentKind, sourceByteSize: Long,
    ): ByteArray = attachmentAad(
        accountId, attachmentId, kind, "attachment_content", u64be(sourceByteSize),
    )

    fun attachmentWrapAad(
        accountId: String, attachmentId: String,
        kind: AttachmentKind, ciphertextHash: ByteArray,
    ): ByteArray {
        require(ciphertextHash.size == 32) { "invalid ciphertext hash" }
        return attachmentAad(accountId, attachmentId, kind, "wrapped_file_key", ciphertextHash)
    }

    fun attachmentFieldAad(
        accountId: String, attachmentId: String,
        kind: AttachmentKind, field: AttachmentField,
    ): ByteArray = attachmentAad(accountId, attachmentId, kind, field.wire, null)

    fun sealAttachment(plaintext: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray =
        sealEnvelope(plaintext, key, nonce, aad)

    fun openAttachment(envelope: ByteArray, key: ByteArray, aad: ByteArray): ByteArray =
        openEnvelope(envelope, key, aad)
```

`u16be`·`u32be`·`u64be`·`ascii`·`canonicalUuid`·`sealEnvelope`·`openEnvelope`가 이 파일에
이미 있는지 먼저 확인한다. 이름이 다르면 **새로 만들지 말고 기존 것을 쓴다.**
`u64be`만 없을 가능성이 높다. 없으면 기존 `u32be` 바로 아래에 같은 방식으로 추가한다.

Kotlin `ScopeKeys.attachmentWrapKey`에도 미사용 주석을 단다.

- [ ] **Step 8: Kotlin 벡터 테스트를 쓴다**

`android/app/src/test/java/com/sapiens/gagaodok/sync/AttachmentContractVectorTest.kt`.
Swift Step 5와 **같은 12가지**를 확인한다. fixture 경로는 기존 `E2EEContractVectorTest`가
쓰는 방식을 그대로 따른다(그 파일에서 `loadVector()`가 경로를 어떻게 잡는지 보고 맞춘다).

```kotlin
package com.sapiens.gagaodok.sync

import java.io.File
import java.security.MessageDigest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AttachmentContractVectorTest {
    private fun unhex(value: String) = ByteArray(value.length / 2) {
        value.substring(it * 2, it * 2 + 2).toInt(16).toByte()
    }

    private val root = Json.parseToJsonElement(
        File("../tools/fixtures/e2ee_contract_vectors.json").readText(),
    ).jsonObject
    private val vector = root["attachment"]!!.jsonObject
    private fun str(key: String) = vector[key]!!.jsonPrimitive.content
    private fun int(key: String) = vector[key]!!.jsonPrimitive.content.toInt()

    @Test fun `derives the account scoped attachment keys`() {
        val master = unhex(root["recovery"]!!.jsonObject["account_master_key_hex"]!!.jsonPrimitive.content)
        val keys = SyncE2EE.deriveAttachmentKeys(master)
        assertArrayEquals(unhex(str("attachment_root_key_hex")), keys.attachmentRootKey)
        assertArrayEquals(unhex(str("attachment_wrap_key_hex")), keys.attachmentWrapKey)
        assertArrayEquals(unhex(str("attachment_field_aead_key_hex")), keys.attachmentFieldAeadKey)
    }

    @Test fun `reproduces the content envelope and its 34 byte overhead`() {
        val aad = SyncE2EE.attachmentContentAad(
            str("account_id"), str("attachment_id"),
            SyncE2EE.AttachmentKind.ATTACHMENT, int("source_byte_size").toLong(),
        )
        assertArrayEquals(unhex(str("content_aad_hex")), aad)
        val envelope = unhex(str("content_envelope_hex"))
        assertEquals(int("source_byte_size") + 34, envelope.size)
        val opened = SyncE2EE.openAttachment(envelope, unhex(str("file_key_hex")), aad)
        assertArrayEquals(unhex(str("content_plaintext_hex")), opened)
    }

    @Test fun `unwraps the file key and rejects a swapped object`() {
        val master = unhex(root["recovery"]!!.jsonObject["account_master_key_hex"]!!.jsonPrimitive.content)
        val keys = SyncE2EE.deriveAttachmentKeys(master)
        val envelope = unhex(str("content_envelope_hex"))
        val hash = MessageDigest.getInstance("SHA-256").digest(envelope)
        assertArrayEquals(unhex(str("ciphertext_hash_hex")), hash)

        val aad = SyncE2EE.attachmentWrapAad(
            str("account_id"), str("attachment_id"), SyncE2EE.AttachmentKind.ATTACHMENT, hash,
        )
        assertArrayEquals(unhex(str("wrap_aad_hex")), aad)
        assertArrayEquals(
            unhex(str("file_key_hex")),
            SyncE2EE.openAttachment(unhex(str("wrapped_file_key_envelope_hex")), keys.attachmentWrapKey, aad),
        )

        val tampered = hash.copyOf(); tampered[0] = (tampered[0].toInt() xor 1).toByte()
        val tamperedAad = SyncE2EE.attachmentWrapAad(
            str("account_id"), str("attachment_id"), SyncE2EE.AttachmentKind.ATTACHMENT, tampered,
        )
        var rejected = false
        try {
            SyncE2EE.openAttachment(
                unhex(str("wrapped_file_key_envelope_hex")), keys.attachmentWrapKey, tamperedAad,
            )
        } catch (error: Exception) { rejected = true }
        assertTrue("a swapped object still unwrapped the file key", rejected)
    }

    @Test fun `separates file name and mime type AAD`() {
        val name = SyncE2EE.attachmentFieldAad(
            str("account_id"), str("attachment_id"),
            SyncE2EE.AttachmentKind.ATTACHMENT, SyncE2EE.AttachmentField.FILE_NAME,
        )
        val mime = SyncE2EE.attachmentFieldAad(
            str("account_id"), str("attachment_id"),
            SyncE2EE.AttachmentKind.ATTACHMENT, SyncE2EE.AttachmentField.MIME_TYPE,
        )
        assertArrayEquals(unhex(str("file_name_aad_hex")), name)
        assertFalse(name.contentEquals(mime))
    }
}
```

- [ ] **Step 9: Kotlin 벡터 테스트를 실행한다**

```bash
cd android && ./gradlew :app:testPhoneDebugUnitTest --tests '*AttachmentContractVectorTest*'
```

기대: 4개 테스트 모두 통과. **하나라도 실패하면 Kotlin 쪽 label·field 순서·UUID 인코딩을
의심한다. 벡터를 고쳐서 맞추지 않는다.** 벡터는 Swift가 만든 정답이다.

- [ ] **Step 10: 커밋하지 않는다**

Task 1은 Task 4에서 Task 11 커밋에 함께 담긴다. 여기서는 커밋하지 않는다.
`git diff --check`만 돌려 공백 오류를 확인한다.

---
## Task 2: Worker 클라이언트에 첨부 endpoint를 추가한다

Worker 쪽 경로는 이미 완성돼 있다(`src/routes/attachments.ts`). 클라이언트에만 없다.

**Files:**
- Modify: `Sources/KakaoSapiens/Services/SyncWorkerClient.swift`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncWorkerClient.kt`
- Modify: `Tests/KakaoSapiensSyncOutboxTests/SyncOutboxTests.swift` (전송 스텁 재사용 시)
- Create: `Tests/KakaoSapiensSyncOutboxTests/SyncAttachmentClientTests.swift`
- Modify: `android/app/src/test/java/com/sapiens/gagaodok/sync/SyncWorkerClientTest.kt`

**Interfaces:**
- Consumes: 기존 `SyncHTTPTransport`/`SyncHttpTransport`, `authorizedRequest`/`request`,
  `SyncHTTPResponse`(`statusCode`, `body: Data`).
- Produces:

```swift
// Swift — SyncWorkerClient
public func putAttachmentContent(attachmentID: String, body: Data) async throws -> SyncHTTPResponse
public func completeAttachment(attachmentID: String) async throws -> SyncHTTPResponse
public func getAttachmentContent(attachmentID: String) async throws -> SyncHTTPResponse
```

```kotlin
// Kotlin — SyncWorkerClient
fun putAttachmentContent(attachmentId: String, body: ByteArray): SyncHttpResponse
fun completeAttachment(attachmentId: String): SyncHttpResponse
fun getAttachmentContent(attachmentId: String): SyncHttpResponse
```

**정확한 endpoint** (`src/routes/attachments.ts`의 `matchAttachmentPath`에서 확인한 값):

| 동작 | method | 경로 | 성공 |
| --- | --- | --- | --- |
| 업로드 | `PUT` | `/v1/attachments/{attachment_id}/content` | 2xx |
| 완료 | `POST` | `/v1/attachments/{attachment_id}/complete` | **204, body 없음** |
| 다운로드 | `GET` | `/v1/attachments/{attachment_id}/content` | 200 + 바이트 |

`attachment_id`는 **정규 대문자 UUID**여야 한다. 아니면 Worker가 경로를 매칭하지 않는다.

> **주의 — 이미 한 번 물린 곳이다.** `docs/CLOUDFLARE_CONNECTION_GATE.md`에 기록돼 있듯,
> `complete` route가 실제 연결에서 오는 **body 없는 POST**를 거부해 첨부가 원격에서
> `ready`가 되지 못한 결함이 있었다. 로컬 suite 877개가 전부 통과하는 상태였는데도
> 그랬다. `completeAttachment`는 body를 붙이지 않고, `Content-Length: 0`이 나가는지
> 테스트로 고정한다.

- [ ] **Step 1: Swift 실패 테스트를 쓴다**

`Tests/KakaoSapiensSyncOutboxTests/SyncAttachmentClientTests.swift`:

```swift
import Foundation

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}

private actor Recorder {
    var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}

private struct StubTransport: SyncHTTPTransport {
    let recorder: Recorder
    let status: Int
    let body: Data
    func send(_ request: URLRequest) async throws -> SyncHTTPResponse {
        await recorder.record(request)
        return SyncHTTPResponse(statusCode: status, body: body)
    }
}

@main private struct Runner {
    static func main() async throws {
        let attachment = "70000000-0000-4000-8000-000000000001"
        let token = Data(repeating: 0x11, count: 32)

        let uploadRecorder = Recorder()
        let uploadClient = try SyncWorkerClient(
            baseURL: URL(string: "https://example.invalid")!, deviceToken: token,
            transport: StubTransport(recorder: uploadRecorder, status: 204, body: Data()))
        let payload = Data(repeating: 0x5A, count: 130)
        _ = try await uploadClient.putAttachmentContent(attachmentID: attachment, body: payload)
        let uploads = await uploadRecorder.requests
        try check(uploads.count == 1, "upload did not send exactly one request")
        try check(uploads[0].httpMethod == "PUT", "upload is not a PUT")
        try check(uploads[0].url?.path == "/v1/attachments/\(attachment)/content", "upload path is wrong")
        try check(uploads[0].httpBody == payload, "upload body was altered")

        let completeRecorder = Recorder()
        let completeClient = try SyncWorkerClient(
            baseURL: URL(string: "https://example.invalid")!, deviceToken: token,
            transport: StubTransport(recorder: completeRecorder, status: 204, body: Data()))
        _ = try await completeClient.completeAttachment(attachmentID: attachment)
        let completes = await completeRecorder.requests
        try check(completes[0].httpMethod == "POST", "complete is not a POST")
        try check(completes[0].url?.path == "/v1/attachments/\(attachment)/complete", "complete path is wrong")
        // 원격에서 한 번 물렸던 자리다. body를 붙이면 안 된다.
        try check(completes[0].httpBody == nil || completes[0].httpBody?.isEmpty == true,
                  "complete must send no body")

        let downloadRecorder = Recorder()
        let bytes = Data(repeating: 0x7F, count: 64)
        let downloadClient = try SyncWorkerClient(
            baseURL: URL(string: "https://example.invalid")!, deviceToken: token,
            transport: StubTransport(recorder: downloadRecorder, status: 200, body: bytes))
        let response = try await downloadClient.getAttachmentContent(attachmentID: attachment)
        try check(response.body == bytes, "download body was altered")
        let downloads = await downloadRecorder.requests
        try check(downloads[0].httpMethod == "GET", "download is not a GET")

        // 소문자 UUID는 Worker 경로에 매칭되지 않으므로 클라이언트가 먼저 막는다.
        var lowercaseRejected = false
        do { _ = try await downloadClient.getAttachmentContent(attachmentID: attachment.lowercased()) }
        catch { lowercaseRejected = true }
        try check(lowercaseRejected, "a non-canonical attachment id was accepted")

        print("10 attachment client checks passed")
    }
}
```

- [ ] **Step 2: 실패를 확인한다**

```bash
swiftc -parse-as-library Sources/KakaoSapiens/Services/SyncWorkerClient.swift Tests/KakaoSapiensSyncOutboxTests/SyncAttachmentClientTests.swift -o /tmp/attach-client && /tmp/attach-client
```

기대: 컴파일 실패. `value of type 'SyncWorkerClient' has no member 'putAttachmentContent'`.

- [ ] **Step 3: Swift 구현을 추가한다**

`SyncWorkerClient`의 `bootstrap` 아래, `private func get` 위에 넣는다.

```swift
    public func putAttachmentContent(attachmentID: String, body: Data) async throws -> SyncHTTPResponse {
        var request = try authorizedRequest(
            path: "/v1/attachments/\(try canonicalAttachmentID(attachmentID))/content", method: "PUT")
        request.httpBody = body
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return try await transport.send(request)
    }

    /// Body 없는 POST다.
    ///
    /// 예전에 여기에 body를 실었더니 원격 `complete`가 거부해 첨부가 `ready`가
    /// 되지 못했다. 로컬에서는 드러나지 않았다.
    public func completeAttachment(attachmentID: String) async throws -> SyncHTTPResponse {
        let request = try authorizedRequest(
            path: "/v1/attachments/\(try canonicalAttachmentID(attachmentID))/complete", method: "POST")
        return try await transport.send(request)
    }

    public func getAttachmentContent(attachmentID: String) async throws -> SyncHTTPResponse {
        let request = try authorizedRequest(
            path: "/v1/attachments/\(try canonicalAttachmentID(attachmentID))/content", method: "GET")
        return try await transport.send(request)
    }

    /// Worker의 경로 매칭이 정규 대문자 UUID만 받는다.
    private func canonicalAttachmentID(_ value: String) throws -> String {
        guard let uuid = UUID(uuidString: value), uuid.uuidString == value else {
            throw SyncWorkerClientError.invalidResponse
        }
        return value
    }
```

- [ ] **Step 4: 통과를 확인한다**

```bash
swiftc -parse-as-library Sources/KakaoSapiens/Services/SyncWorkerClient.swift Tests/KakaoSapiensSyncOutboxTests/SyncAttachmentClientTests.swift -o /tmp/attach-client && /tmp/attach-client
```

기대: `10 attachment client checks passed`

- [ ] **Step 5: Kotlin에 같은 것을 추가한다**

`android/app/src/main/java/com/sapiens/gagaodok/sync/SyncWorkerClient.kt`의 `bootstrap` 아래.

```kotlin
    fun putAttachmentContent(attachmentId: String, body: ByteArray): SyncHttpResponse {
        val request = request("/v1/attachments/${canonicalAttachmentId(attachmentId)}/content")
            .put(body.toRequestBody("application/octet-stream".toMediaType()))
            .build()
        return checked(transport.send(request))
    }

    /** Body 없는 POST다. body를 실으면 원격 complete가 거부한다. */
    fun completeAttachment(attachmentId: String): SyncHttpResponse {
        val request = request("/v1/attachments/${canonicalAttachmentId(attachmentId)}/complete")
            .post(ByteArray(0).toRequestBody(null))
            .build()
        return checked(transport.send(request))
    }

    fun getAttachmentContent(attachmentId: String): SyncHttpResponse =
        checked(transport.send(request("/v1/attachments/${canonicalAttachmentId(attachmentId)}/content").get().build()))

    private fun canonicalAttachmentId(value: String): String {
        require(value == java.util.UUID.fromString(value).toString().uppercase()) { "attachment id must be canonical" }
        return value
    }

    private fun checked(response: SyncHttpResponse): SyncHttpResponse {
        if (response.statusCode !in 200..299) throw SyncWorkerClientException(response.statusCode)
        return response
    }
```

`toRequestBody`·`toMediaType` import가 이 파일에 이미 있는지 확인하고, 없으면
`okhttp3.RequestBody.Companion.toRequestBody`와 `okhttp3.MediaType.Companion.toMediaType`을
추가한다. 기존 `get()` helper의 상태 코드 검사 방식과 겹치면 **기존 것을 재사용한다.**

- [ ] **Step 6: Kotlin 테스트를 추가한다**

`android/app/src/test/java/com/sapiens/gagaodok/sync/SyncWorkerClientTest.kt`에 추가한다.
기존 파일의 stub transport를 재사용한다.

```kotlin
    @Test fun `attachment routes use the exact worker paths and send no complete body`() {
        val sent = mutableListOf<okhttp3.Request>()
        val client = SyncWorkerClient(
            baseUrl = "https://example.invalid",
            deviceToken = ByteArray(32) { 0x11 },
            transport = { request -> sent += request; SyncHttpResponse(204, ByteArray(0)) },
        )
        val id = "70000000-0000-4000-8000-000000000001"

        client.putAttachmentContent(id, ByteArray(130) { 0x5A })
        assertEquals("PUT", sent[0].method)
        assertEquals("/v1/attachments/$id/content", sent[0].url.encodedPath)
        assertEquals(130L, sent[0].body!!.contentLength())

        client.completeAttachment(id)
        assertEquals("POST", sent[1].method)
        assertEquals("/v1/attachments/$id/complete", sent[1].url.encodedPath)
        assertEquals(0L, sent[1].body!!.contentLength())

        client.getAttachmentContent(id)
        assertEquals("GET", sent[2].method)
    }

    @Test fun `attachment routes reject a non canonical id`() {
        val client = SyncWorkerClient(
            baseUrl = "https://example.invalid",
            deviceToken = ByteArray(32) { 0x11 },
            transport = { SyncHttpResponse(204, ByteArray(0)) },
        )
        var rejected = false
        try { client.completeAttachment("70000000-0000-4000-8000-000000000001".lowercase()) }
        catch (error: IllegalArgumentException) { rejected = true }
        assertTrue(rejected)
    }
```

`SyncWorkerClient`의 실제 생성자 인자 이름은 파일을 열어 확인하고 맞춘다.

- [ ] **Step 7: Kotlin 테스트를 실행한다**

```bash
cd android && ./gradlew :app:testPhoneDebugUnitTest --tests '*SyncWorkerClientTest*'
```

기대: 전부 통과.

- [ ] **Step 8: 커밋하지 않는다**

Task 4에서 함께 커밋한다.

---
## Task 3: 첨부 전송 코디네이터와 메모리 측정

**Files:**
- Create: `Sources/KakaoSapiens/Services/SyncAttachmentTransferCoordinator.swift`
- Create: `Tests/KakaoSapiensSyncOutboxTests/SyncAttachmentTransferCoordinatorTests.swift`
- Create: `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncAttachmentTransferCoordinator.kt`
- Create: `android/app/src/test/java/com/sapiens/gagaodok/sync/SyncAttachmentTransferCoordinatorTest.kt`
- Create: `tools/measure-attachment-memory.swift`

**Interfaces:**
- Consumes: Task 1의 `SyncE2EE.deriveAttachmentKeys`, `attachmentContentAAD`,
  `attachmentWrapAAD`, `attachmentFieldAAD`, `sealAttachment`, `openAttachment`.
  Task 2의 `putAttachmentContent`, `completeAttachment`, `getAttachmentContent`.
- Produces: Task 4의 UI가 쓴다.

```swift
public struct SyncAttachmentPlan: Equatable {
    public let attachmentID: String          // 정규 대문자 UUID
    public let kind: SyncAttachmentKind
    public let sourceByteSize: UInt64
    public let ciphertextByteSize: UInt64    // 항상 sourceByteSize + 34
    public let ciphertextHashHex: String     // lowercase hex 64자
    public let ciphertext: Data
    public let wrappedFileKeyBase64: String
    public let fileNameBase64: String
    public let mimeTypeBase64: String
}

public enum SyncAttachmentError: Error, Equatable {
    case tooLarge(UInt64)
    case sizeMismatch
    case hashMismatch
    case notReady
    case decryptionFailed
    case identityNotCanonical
}

public struct SyncAttachmentTransferCoordinator {
    public static let maxSourceBytes: UInt64 = 12_582_912
    public static let envelopeOverheadBytes: UInt64 = 34

    public init(accountID: String, masterKey: Data, client: SyncWorkerClient, rootDirectory: URL)
    public func prepare(bytes: Data, attachmentID: String, kind: SyncAttachmentKind,
                        fileName: String, mimeType: String, randomBytes: (Int) -> Data) throws -> SyncAttachmentPlan
    public func upload(_ plan: SyncAttachmentPlan) async throws
    public func download(attachmentID: String, kind: SyncAttachmentKind,
                         sourceByteSize: UInt64, ciphertextByteSize: UInt64,
                         ciphertextHashHex: String, wrappedFileKeyBase64: String) async throws -> URL
    /// 복호화 결과가 sync/remote/attachments를 벗어나지 않음을 호출부가 확인할 수 있게 공개한다.
    public static func destinationPath(rootDirectory: URL, attachmentID: String) throws -> URL
}
```

```kotlin
data class SyncAttachmentPlan(
    val attachmentId: String, val kind: SyncE2EE.AttachmentKind,
    val sourceByteSize: Long, val ciphertextByteSize: Long,
    val ciphertextHashHex: String, val ciphertext: ByteArray,
    val wrappedFileKeyBase64: String, val fileNameBase64: String, val mimeTypeBase64: String,
)

class SyncAttachmentTransferCoordinator(
    private val accountId: String, private val masterKey: ByteArray,
    private val client: SyncWorkerClient, private val rootDirectory: java.io.File,
) {
    fun prepare(bytes: ByteArray, attachmentId: String, kind: SyncE2EE.AttachmentKind,
                fileName: String, mimeType: String, randomBytes: (Int) -> ByteArray): SyncAttachmentPlan
    fun upload(plan: SyncAttachmentPlan)
    fun download(attachmentId: String, kind: SyncE2EE.AttachmentKind, sourceByteSize: Long,
                 ciphertextByteSize: Long, ciphertextHashHex: String,
                 wrappedFileKeyBase64: String): java.io.File
}
```

`randomBytes`를 인자로 받는 이유는 테스트에서 nonce와 file key를 고정하기 위해서다.
실제 호출부는 CSPRNG를 넘긴다.

- [ ] **Step 1: Swift 실패 테스트를 쓴다**

`Tests/KakaoSapiensSyncOutboxTests/SyncAttachmentTransferCoordinatorTests.swift`:

```swift
import Foundation
import CryptoKit

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}

private actor Calls {
    var order: [String] = []
    func add(_ name: String) { order.append(name) }
}

private struct OrderedTransport: SyncHTTPTransport {
    let calls: Calls
    let completeStatus: Int
    /// GET이 돌려줄 바이트. 비워 두면 크기 검사에 먼저 걸려 해시 검사를 시험할 수 없다.
    var downloadBody: Data = Data()
    func send(_ request: URLRequest) async throws -> SyncHTTPResponse {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/complete") {
            await calls.add("complete")
            return SyncHTTPResponse(statusCode: completeStatus, body: Data())
        }
        if request.httpMethod == "GET" {
            await calls.add("get")
            return SyncHTTPResponse(statusCode: 200, body: downloadBody)
        }
        await calls.add("put")
        return SyncHTTPResponse(statusCode: 204, body: Data())
    }
}

@main private struct Runner {
    static func main() async throws {
        let account = "11111111-1111-4111-8111-111111111111"
        let attachment = "70000000-0000-4000-8000-000000000001"
        let master = Data(repeating: 0x22, count: 32)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attach-test-\(UUID().uuidString)", isDirectory: true)
        let source = Data((0..<96).map { UInt8($0) })
        let fixedRandom: (Int) -> Data = { count in Data(repeating: 0x40, count: count) }

        // 1. 봉투 크기가 정확히 원본 + 34여야 한다.
        let calls = Calls()
        let client = try SyncWorkerClient(
            baseURL: URL(string: "https://example.invalid")!,
            deviceToken: Data(repeating: 0x11, count: 32),
            transport: OrderedTransport(calls: calls, completeStatus: 204))
        let coordinator = SyncAttachmentTransferCoordinator(
            accountID: account, masterKey: master, client: client, rootDirectory: root)
        let plan = try coordinator.prepare(
            bytes: source, attachmentID: attachment, kind: .attachment,
            fileName: "note.pdf", mimeType: "application/pdf", randomBytes: fixedRandom)
        try check(plan.ciphertextByteSize == plan.sourceByteSize + 34, "overhead is not 34")
        try check(plan.ciphertext.count == Int(plan.ciphertextByteSize), "ciphertext size disagrees")
        try check(plan.ciphertextHashHex.count == 64
                  && plan.ciphertextHashHex.lowercased() == plan.ciphertextHashHex,
                  "hash is not lowercase hex 64")

        // 2. 업로드는 반드시 PUT 다음 complete 순서다.
        try await coordinator.upload(plan)
        let order = await calls.order
        try check(order == ["put", "complete"], "upload order is not put→complete, got \(order)")

        // 3. complete가 실패하면 ready가 아니므로 오류가 나야 한다.
        let failing = Calls()
        let failingClient = try SyncWorkerClient(
            baseURL: URL(string: "https://example.invalid")!,
            deviceToken: Data(repeating: 0x11, count: 32),
            transport: OrderedTransport(calls: failing, completeStatus: 500))
        let failingCoordinator = SyncAttachmentTransferCoordinator(
            accountID: account, masterKey: master, client: failingClient, rootDirectory: root)
        var completeFailed = false
        do { try await failingCoordinator.upload(plan) } catch { completeFailed = true }
        try check(completeFailed, "a failed complete was reported as success")

        // 4. 크기가 다르면 거부한다.
        var sizeRejected = false
        do {
            _ = try await coordinator.download(
                attachmentID: attachment, kind: .attachment, sourceByteSize: 96,
                ciphertextByteSize: 999, ciphertextHashHex: plan.ciphertextHashHex,
                wrappedFileKeyBase64: plan.wrappedFileKeyBase64)
        } catch { sizeRejected = true }
        try check(sizeRejected, "a size mismatch was accepted")

        // 5. 해시가 다르면 거부한다.
        //    크기는 맞는 실제 바이트를 돌려줘야 크기 검사를 통과해 해시 검사에 닿는다.
        //    빈 body를 쓰면 크기 검사에 먼저 걸려 이 시험이 무의미해진다.
        let hashClient = try SyncWorkerClient(
            baseURL: URL(string: "https://example.invalid")!,
            deviceToken: Data(repeating: 0x11, count: 32),
            transport: OrderedTransport(calls: Calls(), completeStatus: 204, downloadBody: plan.ciphertext))
        let hashCoordinator = SyncAttachmentTransferCoordinator(
            accountID: account, masterKey: master, client: hashClient, rootDirectory: root)
        var hashRejected = false
        do {
            _ = try await hashCoordinator.download(
                attachmentID: attachment, kind: .attachment, sourceByteSize: 96,
                ciphertextByteSize: plan.ciphertextByteSize,
                ciphertextHashHex: String(repeating: "0", count: 64),
                wrappedFileKeyBase64: plan.wrappedFileKeyBase64)
        } catch { hashRejected = true }
        try check(hashRejected, "a hash mismatch was accepted")

        // 5b. 올바른 해시와 올바른 바이트면 왕복한다. 위 거부가 우연이 아님을 확인한다.
        let roundTrip = try await hashCoordinator.download(
            attachmentID: attachment, kind: .attachment, sourceByteSize: 96,
            ciphertextByteSize: plan.ciphertextByteSize,
            ciphertextHashHex: plan.ciphertextHashHex,
            wrappedFileKeyBase64: plan.wrappedFileKeyBase64)
        try check(try Data(contentsOf: roundTrip) == source, "the round trip did not restore the source bytes")

        // 6. 12MB를 넘으면 조용히 자르지 않고 명시적으로 거부한다.
        var tooLargeRejected = false
        do {
            _ = try coordinator.prepare(
                bytes: Data(count: Int(SyncAttachmentTransferCoordinator.maxSourceBytes) + 1),
                attachmentID: attachment, kind: .attachment,
                fileName: "big.bin", mimeType: "application/octet-stream", randomBytes: fixedRandom)
        } catch { tooLargeRejected = true }
        try check(tooLargeRejected, "an oversized attachment was accepted")

        // 7. 복호화 결과는 sync/remote/attachments 아래에만 쓴다.
        //    카메라·PDF 원본 경로를 덮어쓰지 않는다.
        let expectedPrefix = root.appendingPathComponent("sync/remote/attachments", isDirectory: true).path
        let destination = try SyncAttachmentTransferCoordinator.destinationPath(
            rootDirectory: root, attachmentID: attachment)
        try check(destination.path.hasPrefix(expectedPrefix), "attachments escape sync/remote/attachments")

        print("11 attachment transfer checks passed")
    }
}
```

- [ ] **Step 2: 실패를 확인한다**

```bash
swiftc -parse-as-library \
  Sources/KakaoSapiens/Services/SyncE2EE.swift \
  Sources/KakaoSapiens/Services/SyncWorkerClient.swift \
  Sources/KakaoSapiens/Services/SyncAttachmentTransferCoordinator.swift \
  Tests/KakaoSapiensSyncOutboxTests/SyncAttachmentTransferCoordinatorTests.swift \
  -o /tmp/attach-transfer && /tmp/attach-transfer
```

기대: 컴파일 실패(파일 없음). 이 명령을 Step 4에서 그대로 다시 쓴다.

- [ ] **Step 3: Swift 구현을 쓴다**

`Sources/KakaoSapiens/Services/SyncAttachmentTransferCoordinator.swift`:

```swift
import CryptoKit
import Foundation

public struct SyncAttachmentPlan: Equatable {
    public let attachmentID: String
    public let kind: SyncAttachmentKind
    public let sourceByteSize: UInt64
    public let ciphertextByteSize: UInt64
    public let ciphertextHashHex: String
    public let ciphertext: Data
    public let wrappedFileKeyBase64: String
    public let fileNameBase64: String
    public let mimeTypeBase64: String
}

public enum SyncAttachmentError: Error, Equatable {
    case tooLarge(UInt64)
    case sizeMismatch
    case hashMismatch
    case notReady
    case decryptionFailed
    case identityNotCanonical
}

/// 첨부의 올리기·받기 순서와 검증만 갖는다.
///
/// 로컬 대화 저장소를 읽거나 쓰지 않으며, 카메라·PDF 원본 파일을 덮어쓰지 않는다.
/// 복호화 결과는 `sync/remote/attachments` 아래에만 쓴다.
public struct SyncAttachmentTransferCoordinator {
    public static let maxSourceBytes: UInt64 = 12_582_912
    public static let envelopeOverheadBytes: UInt64 = 34

    private let accountID: String
    private let masterKey: Data
    private let client: SyncWorkerClient
    private let rootDirectory: URL

    public init(accountID: String, masterKey: Data, client: SyncWorkerClient, rootDirectory: URL) {
        self.accountID = accountID
        self.masterKey = masterKey
        self.client = client
        self.rootDirectory = rootDirectory
    }

    public static func destinationPath(rootDirectory: URL, attachmentID: String) throws -> URL {
        guard let uuid = UUID(uuidString: attachmentID), uuid.uuidString == attachmentID else {
            throw SyncAttachmentError.identityNotCanonical
        }
        return rootDirectory
            .appendingPathComponent("sync/remote/attachments", isDirectory: true)
            .appendingPathComponent(attachmentID)
    }

    public func prepare(
        bytes: Data, attachmentID: String, kind: SyncAttachmentKind,
        fileName: String, mimeType: String, randomBytes: (Int) -> Data
    ) throws -> SyncAttachmentPlan {
        guard let uuid = UUID(uuidString: attachmentID), uuid.uuidString == attachmentID else {
            throw SyncAttachmentError.identityNotCanonical
        }
        let size = UInt64(bytes.count)
        // 상한을 넘으면 조용히 누락하지 않고 명시적으로 거부한다. 호출부가 사용자에게 알린다.
        guard size >= 1, size <= Self.maxSourceBytes else { throw SyncAttachmentError.tooLarge(size) }

        let keys = try SyncE2EE.deriveAttachmentKeys(accountMasterKey: masterKey)
        let fileKey = randomBytes(32)
        let contentAAD = try SyncE2EE.attachmentContentAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, sourceByteSize: size)
        let ciphertext = try SyncE2EE.sealAttachment(
            plaintext: bytes, key: fileKey, nonce: randomBytes(12), aad: contentAAD)
        let hash = Data(SHA256.hash(data: ciphertext))
        let wrapAAD = try SyncE2EE.attachmentWrapAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, ciphertextHash: hash)
        let wrapped = try SyncE2EE.sealAttachment(
            plaintext: fileKey, key: keys.attachmentWrapKey, nonce: randomBytes(12), aad: wrapAAD)
        let name = try SyncE2EE.sealAttachment(
            plaintext: Data(fileName.utf8), key: keys.attachmentFieldAEADKey, nonce: randomBytes(12),
            aad: try SyncE2EE.attachmentFieldAAD(
                accountID: accountID, attachmentID: attachmentID, kind: kind, field: .fileName))
        let mime = try SyncE2EE.sealAttachment(
            plaintext: Data(mimeType.utf8), key: keys.attachmentFieldAEADKey, nonce: randomBytes(12),
            aad: try SyncE2EE.attachmentFieldAAD(
                accountID: accountID, attachmentID: attachmentID, kind: kind, field: .mimeType))

        return SyncAttachmentPlan(
            attachmentID: attachmentID, kind: kind, sourceByteSize: size,
            ciphertextByteSize: UInt64(ciphertext.count),
            ciphertextHashHex: hash.map { String(format: "%02x", $0) }.joined(),
            ciphertext: ciphertext,
            wrappedFileKeyBase64: SyncE2EE.encodeBase64(wrapped),
            fileNameBase64: SyncE2EE.encodeBase64(name),
            mimeTypeBase64: SyncE2EE.encodeBase64(mime))
    }

    /// PUT 다음 complete. 이 순서를 바꾸면 다른 기기에 다운로드 불가능한 중간 상태가 노출된다.
    public func upload(_ plan: SyncAttachmentPlan) async throws {
        let put = try await client.putAttachmentContent(
            attachmentID: plan.attachmentID, body: plan.ciphertext)
        guard (200...299).contains(put.statusCode) else { throw SyncWorkerClientError.httpStatus(put.statusCode) }
        let complete = try await client.completeAttachment(attachmentID: plan.attachmentID)
        guard (200...299).contains(complete.statusCode) else {
            throw SyncWorkerClientError.httpStatus(complete.statusCode)
        }
    }

    public func download(
        attachmentID: String, kind: SyncAttachmentKind,
        sourceByteSize: UInt64, ciphertextByteSize: UInt64,
        ciphertextHashHex: String, wrappedFileKeyBase64: String
    ) async throws -> URL {
        let destination = try Self.destinationPath(rootDirectory: rootDirectory, attachmentID: attachmentID)
        let response = try await client.getAttachmentContent(attachmentID: attachmentID)
        guard (200...299).contains(response.statusCode) else {
            throw SyncWorkerClientError.httpStatus(response.statusCode)
        }
        let envelope = response.body
        guard UInt64(envelope.count) == ciphertextByteSize,
              ciphertextByteSize == sourceByteSize + Self.envelopeOverheadBytes
        else { throw SyncAttachmentError.sizeMismatch }
        let hash = Data(SHA256.hash(data: envelope))
        guard hash.map({ String(format: "%02x", $0) }).joined() == ciphertextHashHex.lowercased() else {
            throw SyncAttachmentError.hashMismatch
        }

        let keys = try SyncE2EE.deriveAttachmentKeys(accountMasterKey: masterKey)
        let wrapAAD = try SyncE2EE.attachmentWrapAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, ciphertextHash: hash)
        guard let wrappedEnvelope = try? SyncE2EE.decodeBase64(wrappedFileKeyBase64),
              let fileKey = try? SyncE2EE.openAttachment(
                envelope: wrappedEnvelope, key: keys.attachmentWrapKey, aad: wrapAAD)
        else { throw SyncAttachmentError.decryptionFailed }
        let contentAAD = try SyncE2EE.attachmentContentAAD(
            accountID: accountID, attachmentID: attachmentID, kind: kind, sourceByteSize: sourceByteSize)
        guard let plaintext = try? SyncE2EE.openAttachment(
            envelope: envelope, key: fileKey, aad: contentAAD),
            UInt64(plaintext.count) == sourceByteSize
        else { throw SyncAttachmentError.decryptionFailed }

        // 원자적 이동. 부분적으로 쓰인 파일이 완성본으로 보이지 않게 한다.
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".\(attachmentID).partial")
        try plaintext.write(to: staging, options: .atomic)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        return destination
    }
}
```

- [ ] **Step 4: 통과를 확인한다**

Step 2의 명령을 그대로 다시 실행한다.
기대: `11 attachment transfer checks passed`

- [ ] **Step 5: 12MB 최고 메모리를 실제로 잰다**

암호 규격 §9.2가 "아직 측정하지 않았다"고 남긴 자리다. 감으로 넘기지 않는다.

`tools/measure-attachment-memory.swift`:

```swift
import Foundation
import CryptoKit

@main struct Measure {
    static func main() throws {
        let size = 12_582_912
        let account = "11111111-1111-4111-8111-111111111111"
        let attachment = "70000000-0000-4000-8000-000000000001"
        let bytes = Data(count: size)
        let fileKey = Data(repeating: 0x40, count: 32)
        let aad = try SyncE2EE.attachmentContentAAD(
            accountID: account, attachmentID: attachment, kind: .attachment,
            sourceByteSize: UInt64(size))
        let sealed = try SyncE2EE.sealAttachment(
            plaintext: bytes, key: fileKey, nonce: Data(repeating: 0x01, count: 12), aad: aad)
        let opened = try SyncE2EE.openAttachment(envelope: sealed, key: fileKey, aad: aad)
        print("source=\(size) sealed=\(sealed.count) opened=\(opened.count)")
    }
}
```

```bash
swiftc -O -parse-as-library Sources/KakaoSapiens/Services/SyncE2EE.swift tools/measure-attachment-memory.swift -o /tmp/attach-mem
/usr/bin/time -l /tmp/attach-mem 2>&1 | rg "maximum resident set size|source="
```

`maximum resident set size` 값을 그대로 기록한다. Task 7에서 수용 매트릭스에 옮긴다.
**임의로 chunked AEAD를 도입하지 않는다.** 값이 나쁘면 별도 결정 사항으로 올린다.

- [ ] **Step 6: Kotlin 구현과 테스트를 쓴다**

Swift Step 3과 **같은 11가지**를 Kotlin으로 확인한다. 상수(`12_582_912`, `34`),
순서(PUT→complete), 저장 위치(`sync/remote/attachments`), 상한 초과 명시적 거부,
크기·해시 불일치 거부가 전부 같아야 한다.

```kotlin
package com.sapiens.gagaodok.sync

import java.io.File
import java.security.MessageDigest
import java.util.UUID

data class SyncAttachmentPlan(
    val attachmentId: String,
    val kind: SyncE2EE.AttachmentKind,
    val sourceByteSize: Long,
    val ciphertextByteSize: Long,
    val ciphertextHashHex: String,
    val ciphertext: ByteArray,
    val wrappedFileKeyBase64: String,
    val fileNameBase64: String,
    val mimeTypeBase64: String,
)

class SyncAttachmentException(val reason: String) : Exception(reason)

/** 올리기·받기 순서와 검증만 갖는다. ChatStore를 읽거나 쓰지 않는다. */
class SyncAttachmentTransferCoordinator(
    private val accountId: String,
    private val masterKey: ByteArray,
    private val client: SyncWorkerClient,
    private val rootDirectory: File,
) {
    companion object {
        const val MAX_SOURCE_BYTES = 12_582_912L
        const val ENVELOPE_OVERHEAD_BYTES = 34L

        fun destinationFile(rootDirectory: File, attachmentId: String): File {
            require(attachmentId == UUID.fromString(attachmentId).toString().uppercase())
            return File(File(rootDirectory, "sync/remote/attachments"), attachmentId)
        }
    }

    fun prepare(
        bytes: ByteArray, attachmentId: String, kind: SyncE2EE.AttachmentKind,
        fileName: String, mimeType: String, randomBytes: (Int) -> ByteArray,
    ): SyncAttachmentPlan {
        require(attachmentId == UUID.fromString(attachmentId).toString().uppercase())
        val size = bytes.size.toLong()
        if (size < 1 || size > MAX_SOURCE_BYTES) throw SyncAttachmentException("too_large")

        val keys = SyncE2EE.deriveAttachmentKeys(masterKey)
        val fileKey = randomBytes(32)
        val contentAad = SyncE2EE.attachmentContentAad(accountId, attachmentId, kind, size)
        val ciphertext = SyncE2EE.sealAttachment(bytes, fileKey, randomBytes(12), contentAad)
        val hash = MessageDigest.getInstance("SHA-256").digest(ciphertext)
        val wrapAad = SyncE2EE.attachmentWrapAad(accountId, attachmentId, kind, hash)
        val wrapped = SyncE2EE.sealAttachment(fileKey, keys.attachmentWrapKey, randomBytes(12), wrapAad)
        val name = SyncE2EE.sealAttachment(
            fileName.toByteArray(), keys.attachmentFieldAeadKey, randomBytes(12),
            SyncE2EE.attachmentFieldAad(accountId, attachmentId, kind, SyncE2EE.AttachmentField.FILE_NAME),
        )
        val mime = SyncE2EE.sealAttachment(
            mimeType.toByteArray(), keys.attachmentFieldAeadKey, randomBytes(12),
            SyncE2EE.attachmentFieldAad(accountId, attachmentId, kind, SyncE2EE.AttachmentField.MIME_TYPE),
        )
        return SyncAttachmentPlan(
            attachmentId, kind, size, ciphertext.size.toLong(),
            hash.joinToString("") { "%02x".format(it) }, ciphertext,
            SyncE2EE.encodeBase64(wrapped), SyncE2EE.encodeBase64(name), SyncE2EE.encodeBase64(mime),
        )
    }

    /** PUT 다음 complete. 순서를 바꾸면 다운로드 불가능한 중간 상태가 노출된다. */
    fun upload(plan: SyncAttachmentPlan) {
        client.putAttachmentContent(plan.attachmentId, plan.ciphertext)
        client.completeAttachment(plan.attachmentId)
    }

    fun download(
        attachmentId: String, kind: SyncE2EE.AttachmentKind, sourceByteSize: Long,
        ciphertextByteSize: Long, ciphertextHashHex: String, wrappedFileKeyBase64: String,
    ): File {
        val destination = destinationFile(rootDirectory, attachmentId)
        val envelope = client.getAttachmentContent(attachmentId).body
        if (envelope.size.toLong() != ciphertextByteSize ||
            ciphertextByteSize != sourceByteSize + ENVELOPE_OVERHEAD_BYTES
        ) throw SyncAttachmentException("size_mismatch")
        val hash = MessageDigest.getInstance("SHA-256").digest(envelope)
        if (hash.joinToString("") { "%02x".format(it) } != ciphertextHashHex.lowercase()) {
            throw SyncAttachmentException("hash_mismatch")
        }
        val keys = SyncE2EE.deriveAttachmentKeys(masterKey)
        val fileKey = SyncE2EE.openAttachment(
            SyncE2EE.decodeBase64(wrappedFileKeyBase64), keys.attachmentWrapKey,
            SyncE2EE.attachmentWrapAad(accountId, attachmentId, kind, hash),
        )
        val plaintext = SyncE2EE.openAttachment(
            envelope, fileKey,
            SyncE2EE.attachmentContentAad(accountId, attachmentId, kind, sourceByteSize),
        )
        if (plaintext.size.toLong() != sourceByteSize) throw SyncAttachmentException("decryption_failed")

        destination.parentFile?.mkdirs()
        val staging = File(destination.parentFile, ".$attachmentId.partial")
        staging.writeBytes(plaintext)
        if (!staging.renameTo(destination)) {
            destination.delete()
            if (!staging.renameTo(destination)) throw SyncAttachmentException("rename_failed")
        }
        return destination
    }
}
```

테스트는 Swift Step 1과 같은 11가지를 JUnit4로 옮긴다. transport stub은
`SyncWorkerClientTest`의 것을 재사용하되 호출 순서를 기록하도록 확장한다.

- [ ] **Step 7: 양 플랫폼 검사를 돌린다**

```bash
cd android && ./gradlew :app:testPhoneDebugUnitTest --tests '*SyncAttachmentTransferCoordinatorTest*'
```

- [ ] **Step 8: 커밋하지 않는다**

Task 4에서 함께 커밋한다.

---
## Task 4: 첨부 UI 상태와 Task 11 커밋

UI는 설치하지 않으므로 **미검증으로 보고한다.** 그래서 이 Task는 화면에서
판단 로직을 떼어내 **테스트 가능한 순수 상태 계산**으로 만들고, 그 계산만 검증한다.
그리기 자체는 미검증으로 남는다.

**Files:**
- Create: `Sources/KakaoSapiens/Services/SyncAttachmentDisplayState.swift`
- Create: `Tests/KakaoSapiensSyncOutboxTests/SyncAttachmentDisplayStateTests.swift`
- Create: `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncAttachmentDisplayState.kt`
- Create: `android/app/src/test/java/com/sapiens/gagaodok/sync/SyncAttachmentDisplayStateTest.kt`
- Modify: `Sources/KakaoSapiens/Views/RemoteChatRoomView.swift`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/RemoteChatRoomScreen.kt`

**Interfaces:**
- Consumes: Task 3의 `SyncAttachmentTransferCoordinator`, `SyncAttachmentError`.
- Produces:

```swift
public enum SyncAttachmentDisplayState: String, Equatable {
    case pending      // allocated 또는 uploaded — 아직 다른 기기가 받을 수 없다
    case ready        // 내려받아 열 수 있다
    case retryable    // 네트워크·5xx. 다시 시도하면 된다
    case unavailable  // 크기·해시·복호화 실패. 다시 시도해도 같다
}

public static func state(remoteState: String, lastError: SyncAttachmentError?) -> SyncAttachmentDisplayState
```

`remoteState`는 정본 스키마 §7.1의 6개 값이다: `allocated`, `uploaded`, `ready`,
`abandoned`, `tombstoned`, `garbage_collected`.

- [ ] **Step 1: 실패 테스트를 쓴다**

```swift
import Foundation
private struct Failure: Error { let message: String }
private func check(_ v: @autoclosure () -> Bool, _ m: String) throws { if !v() { throw Failure(message: m) } }

@main private struct Runner {
    static func main() throws {
        typealias S = SyncAttachmentDisplayState
        try check(S.state(remoteState: "allocated", lastError: nil) == .pending, "allocated is not pending")
        try check(S.state(remoteState: "uploaded", lastError: nil) == .pending, "uploaded is not pending")
        try check(S.state(remoteState: "ready", lastError: nil) == .ready, "ready is not ready")
        // 다시 시도해도 결과가 같은 실패는 재시도로 안내하지 않는다.
        try check(S.state(remoteState: "ready", lastError: .hashMismatch) == .unavailable, "hash mismatch is retryable")
        try check(S.state(remoteState: "ready", lastError: .sizeMismatch) == .unavailable, "size mismatch is retryable")
        try check(S.state(remoteState: "ready", lastError: .decryptionFailed) == .unavailable, "decryption failure is retryable")
        try check(S.state(remoteState: "ready", lastError: .notReady) == .retryable, "notReady is not retryable")
        // 되돌릴 수 없는 서버 상태는 전부 unavailable이다.
        for dead in ["abandoned", "tombstoned", "garbage_collected"] {
            try check(S.state(remoteState: dead, lastError: nil) == .unavailable, "\(dead) is not unavailable")
        }
        // 모르는 상태를 ready로 낙관하지 않는다.
        try check(S.state(remoteState: "something_new", lastError: nil) == .unavailable, "an unknown state defaulted to ready")
        print("11 attachment display state checks passed")
    }
}
```

- [ ] **Step 2: 실패를 확인한다**

```bash
swiftc -parse-as-library Sources/KakaoSapiens/Services/SyncE2EE.swift Sources/KakaoSapiens/Services/SyncWorkerClient.swift Sources/KakaoSapiens/Services/SyncAttachmentTransferCoordinator.swift Sources/KakaoSapiens/Services/SyncAttachmentDisplayState.swift Tests/KakaoSapiensSyncOutboxTests/SyncAttachmentDisplayStateTests.swift -o /tmp/attach-state && /tmp/attach-state
```

기대: 컴파일 실패.

- [ ] **Step 3: 구현을 쓴다**

```swift
import Foundation

/// 서버 상태와 마지막 오류만으로 화면 상태를 정한다.
///
/// 화면에서 떼어낸 이유는 이 판단이 검증 가능해야 하기 때문이다. 앱을 설치하지
/// 않는 동안에도 이 규칙만은 테스트로 고정된다.
public enum SyncAttachmentDisplayState: String, Equatable {
    case pending
    case ready
    case retryable
    case unavailable

    public static func state(
        remoteState: String, lastError: SyncAttachmentError?
    ) -> SyncAttachmentDisplayState {
        switch remoteState {
        case "allocated", "uploaded":
            return .pending
        case "ready":
            switch lastError {
            case nil:
                return .ready
            // 다시 시도해도 같은 결과가 나오는 실패다. 재시도를 권하지 않는다.
            case .hashMismatch, .sizeMismatch, .decryptionFailed, .tooLarge, .identityNotCanonical:
                return .unavailable
            case .notReady:
                return .retryable
            }
        default:
            // abandoned·tombstoned·garbage_collected, 그리고 아직 모르는 값.
            // 모르는 상태를 ready로 낙관하지 않는다.
            return .unavailable
        }
    }
}
```

- [ ] **Step 4: 통과를 확인한다**

Step 2 명령을 그대로 다시 실행한다. 기대: `11 attachment display state checks passed`

- [ ] **Step 5: Kotlin 동일 구현과 테스트**

```bash
cd android && ./gradlew :app:testPhoneDebugUnitTest --tests '*SyncAttachmentDisplayStateTest*'
```

- [ ] **Step 6: 두 화면에 상태를 배선한다 (미검증)**

`RemoteChatRoomView.swift`와 `RemoteChatRoomScreen.kt`에서 첨부 참조가 있는 bubble에
위 네 상태를 표시한다. 한국어 문구:

| 상태 | 문구 |
| --- | --- |
| `pending` | `첨부를 준비하고 있습니다.` |
| `ready` | 첨부를 연다 |
| `retryable` | `첨부를 받지 못했습니다. 다시 시도하세요.` |
| `unavailable` | `이 첨부는 열 수 없습니다.` |

**이 단계는 화면 확인 없이 끝난다.** Task 7의 보고에 다음을 그대로 적는다:

> 첨부 UI 4상태(pending·ready·retryable·unavailable)는 **미검증**이다.
> 확인해야 할 흐름: 원격 방을 열어 첨부가 달린 bubble이 pending에서 ready로
> 바뀌는지, 12MB 초과 파일이 조용히 누락되지 않고 안내가 뜨는지,
> 긴 방에서 스크롤할 때 상태 표시가 어긋나지 않는지.

- [ ] **Step 7: 양 플랫폼 빌드**

```bash
swift build
cd android && ./gradlew :app:compilePhoneDebugKotlin :app:compileTabletMentorDebugKotlin
```

- [ ] **Step 8: Task 11을 커밋한다**

```bash
git diff --check
git add Sources/KakaoSapiens/Services/SyncE2EE.swift \
        Sources/KakaoSapiens/Services/SyncWorkerClient.swift \
        Sources/KakaoSapiens/Services/SyncAttachmentTransferCoordinator.swift \
        Sources/KakaoSapiens/Services/SyncAttachmentDisplayState.swift \
        Sources/KakaoSapiens/Views/RemoteChatRoomView.swift \
        Tests/KakaoSapiensE2EEContractTests/AttachmentContractVectorTests.swift \
        Tests/KakaoSapiensSyncOutboxTests/SyncAttachmentClientTests.swift \
        Tests/KakaoSapiensSyncOutboxTests/SyncAttachmentTransferCoordinatorTests.swift \
        Tests/KakaoSapiensSyncOutboxTests/SyncAttachmentDisplayStateTests.swift \
        tools/fixtures/e2ee_contract_vectors.json \
        tools/generate-attachment-vectors.swift \
        tools/measure-attachment-memory.swift \
        android/app/src/main/java/com/sapiens/gagaodok/sync/SyncE2EE.kt \
        android/app/src/main/java/com/sapiens/gagaodok/sync/SyncWorkerClient.kt \
        android/app/src/main/java/com/sapiens/gagaodok/sync/SyncAttachmentTransferCoordinator.kt \
        android/app/src/main/java/com/sapiens/gagaodok/sync/SyncAttachmentDisplayState.kt \
        android/app/src/main/java/com/sapiens/gagaodok/ui/screens/RemoteChatRoomScreen.kt \
        android/app/src/test/java/com/sapiens/gagaodok/sync/AttachmentContractVectorTest.kt \
        android/app/src/test/java/com/sapiens/gagaodok/sync/SyncWorkerClientTest.kt \
        android/app/src/test/java/com/sapiens/gagaodok/sync/SyncAttachmentTransferCoordinatorTest.kt \
        android/app/src/test/java/com/sapiens/gagaodok/sync/SyncAttachmentDisplayStateTest.kt
```

`git status --short`로 **범위 밖 파일이 staged되지 않았는지 확인한다.**
`package_for_sharing.sh`, `tools/costsim.py`, untracked 파일이 섞이면 unstage한다.

```bash
git commit -m "$(cat <<'EOF'
feat: 원격 방 첨부파일 동기화를 연결한다

Derive attachment keys from the account master key instead of a room scope.
The canonical attachment identity is (account_id, attachment_id) and
create_attachment forbids room_id, so a room-scoped key could not be
reproduced by the receiving device; a sentinel room UUID would have broken
cross-device decryption silently.

Three new HKDF labels hang off attachment-root: attachment-field-aead for
file_name/mime_type and attachment-file-key-wrap for wrapped_file_key. The
content AAD binds source_byte_size so a truncated object fails to open, and
the wrapped-key AAD binds ciphertext_hash so the key fits exactly one object
— a server swapping the object under the same attachment_id no longer
decrypts. Every AAD input is plaintext metadata already present in the
projection, so any device of the account can reproduce it.

The scope-child attachment-wrap key is kept, unused, because published
contract vectors depend on it; both platforms now carry a comment saying so.

Worker, D1 and R2 are unchanged — wrapped_file_key stays opaque bytes.
Upload is strictly create_attachment → PUT → complete → bubble reference.
completeAttachment sends no body: a body there was what broke ready on the
remote synthetic environment while the local suite passed.

Attachment UI states are wired but UNVERIFIED — no app was installed.
Verify later: pending→ready transition in a remote room, the over-12MB
notice, and state alignment while scrolling a long room.
EOF
)"
```

---

## Task 5: 방 가족 완결성 (상위 Task 12)

**현재 결함:** `SyncRemoteRoomAssembler`가 grouping 단계에서 `room`·`turn`·`bubble`만
통과시킨다. `group_state`·`worldline`·`engine_profile`·`persona_snapshot`·`checkpoint`·
`attachment`는 분기에 닿기 전에 걸러져 **조용히 버려진다.** switch의
`default: return nil`은 도달하지 않는다. `SyncReplicaStore`는 이미 9종을 저장한다.

**Files:**
- Create: `Sources/KakaoSapiens/Services/SyncCanonicalRoomSnapshotBuilder.swift`
- Create: `Tests/KakaoSapiensSyncOutboxTests/SyncCanonicalRoomSnapshotBuilderTests.swift`
- Create: `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncCanonicalRoomSnapshotBuilder.kt`
- Create: `android/app/src/test/java/com/sapiens/gagaodok/sync/SyncCanonicalRoomSnapshotBuilderTest.kt`
- Modify: `Sources/KakaoSapiens/Services/SyncRemoteRoomTypes.swift`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncRemoteRoomTypes.kt`
- Modify: `Sources/KakaoSapiens/Services/SyncRemoteRoomAssembler.swift`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncRemoteRoomAssembler.kt`

**Interfaces:**
- Consumes: `SyncReplicaEntry`, Task 1의 첨부 계약(첨부 참조가 `ready`인지 판정할 때).
- Produces:

```swift
public enum SyncRoomFamilyGap: String, Equatable {
    case unknownEntity           = "unknown_entity"
    case missingWorldline        = "worldline_missing"
    case missingGroupState       = "group_state_missing"
    case missingEngineProfile    = "engine_profile_revision_missing"
    case missingPersonaSnapshot  = "persona_snapshot_missing"
    case missingCheckpoint       = "checkpoint_missing"
    case attachmentNotReady      = "attachment_not_ready"
}

public struct SyncRoomFamily {
    public let roomID: String
    public let gaps: [SyncRoomFamilyGap]   // 정렬됨. 비어 있으면 완결
}

public struct SyncCanonicalRoomSnapshotBuilder {
    public init(accountID: String, registeredSpaceID: String, masterKey: Data)
    public func build(_ entries: [SyncReplicaEntry], roomID: String) -> SyncRoomFamily
}
```

`SyncRemoteRoomSnapshot`에 필드를 추가한다. 옛 projection 호환은 기존
`continuationCapability`와 같은 `decodeIfPresent` 방식이다.

```swift
    /// 비어 있지 않으면 이어쓰기가 막힌다. 옛 projection에는 없다.
    public let unsupportedReason: String?
```

- [ ] **Step 1: 완결 fixture와 결손 fixture를 만든다**

fixture 하나마다 필수 참조를 **하나씩** 빼서 총 7개를 만든다. 합성 식별자만 쓴다.

```swift
// Tests/KakaoSapiensSyncOutboxTests/SyncCanonicalRoomSnapshotBuilderTests.swift 안에서
// 아래 헬퍼로 fixture를 만든다. entity_type마다 identity 키 집합이 다르다.
private func entry(_ type: String, _ identity: [String: Any], _ projection: [String: Any]) -> SyncReplicaEntry {
    SyncReplicaEntry(
        entityType: type,
        identityJSON: try! JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]),
        projectionJSON: try! JSONSerialization.data(withJSONObject: projection, options: [.sortedKeys]))
}
```

`SyncReplicaEntry`의 실제 생성자 인자 이름은 `Sources/KakaoSapiens/Services/SyncReplicaStore.swift`를
열어 확인하고 맞춘다.

- [ ] **Step 2: 실패 테스트를 쓴다**

```swift
@main private struct Runner {
    static func main() throws {
        let builder = SyncCanonicalRoomSnapshotBuilder(
            accountID: account, registeredSpaceID: "PHONE_SPACE", masterKey: master)

        // 1. 완결된 가족은 gap이 없다.
        try check(builder.build(completeFamily, roomID: room).gaps.isEmpty,
                  "a complete family reported a gap")

        // 2. 참조를 하나씩 빼면 그 gap만 나온다. 기본값으로 때우지 않는다.
        let cases: [(String, [SyncReplicaEntry], SyncRoomFamilyGap)] = [
            ("worldline", withoutWorldline, .missingWorldline),
            ("group_state", withoutGroupState, .missingGroupState),
            ("engine_profile", withoutEngineProfile, .missingEngineProfile),
            ("persona_snapshot", withoutPersonaSnapshot, .missingPersonaSnapshot),
            ("checkpoint", withoutCheckpoint, .missingCheckpoint),
        ]
        for (name, entries, expected) in cases {
            let gaps = builder.build(entries, roomID: room).gaps
            try check(gaps == [expected], "\(name): expected [\(expected)], got \(gaps)")
        }

        // 3. ready가 아닌 첨부는 완결이 아니다.
        try check(builder.build(withAllocatedAttachment, roomID: room).gaps == [.attachmentNotReady],
                  "a non-ready attachment counted as complete")

        // 4. 모르는 entity_type을 조용히 버리지 않는다.
        try check(builder.build(withUnknownEntity, roomID: room).gaps == [.unknownEntity],
                  "an unknown entity type was silently dropped")

        // 5. 손상된 가족은 그 가족만 막고 다른 방에 번지지 않는다.
        let assembler = SyncRemoteRoomAssembler(
            accountID: account, registeredSpaceID: "PHONE_SPACE", masterKey: master)
        let snapshots = assembler.assemble(brokenRoomPlusHealthyRoom)
        try check(snapshots.count == 2, "a broken family removed a healthy room")
        let broken = snapshots.first { $0.handle.roomID.uuidString == brokenRoom }!
        let healthy = snapshots.first { $0.handle.roomID.uuidString == healthyRoom }!
        try check(broken.unsupportedReason != nil, "the broken room stayed openable")
        try check(healthy.unsupportedReason == nil, "the healthy room was blocked")

        // 6. 이어쓰기는 unsupportedReason이 있으면 막힌다.
        try check(broken.continuationCapability != .chatbot || broken.unsupportedReason != nil,
                  "a room with a gap is still openable for continuation")

        print("12 room family completeness checks passed")
    }
}
```

- [ ] **Step 3: 실패를 확인한다**

```bash
swiftc -parse-as-library \
  Sources/KakaoSapiens/Services/SyncE2EE.swift \
  Sources/KakaoSapiens/Services/SyncReplicaStore.swift \
  Sources/KakaoSapiens/Services/SyncRemoteRoomTypes.swift \
  Sources/KakaoSapiens/Services/SyncCanonicalRoomSnapshotBuilder.swift \
  Sources/KakaoSapiens/Services/SyncRemoteRoomAssembler.swift \
  Tests/KakaoSapiensSyncOutboxTests/SyncCanonicalRoomSnapshotBuilderTests.swift \
  -o /tmp/room-family && /tmp/room-family
```

- [ ] **Step 4: builder를 구현한다**

핵심 규칙 세 가지를 코드 주석으로 남긴다.

```swift
/// 방 가족의 완결성만 판정한다. 렌더링은 assembler가 한다.
///
/// 규칙 셋:
///  1. 참조된 revision이 없으면 그 가족을 unsupported로 표시한다. 기본값을 지어내지 않는다.
///  2. 모르는 entity_type은 버리지 않고 unknownEntity로 올린다. 조용한 누락이
///     "완전한 대화"처럼 보이는 것이 가장 나쁜 실패다.
///  3. 한 가족의 결손이 다른 방으로 번지지 않는다.
public struct SyncCanonicalRoomSnapshotBuilder {
```

assembler의 grouping 조건을 고친다. 지금은 이렇게 걸러낸다:

```swift
for entry in entries where entry.entityType == "room" || entry.entityType == "turn" || entry.entityType == "bubble" {
```

9종 전부를 방으로 묶은 뒤 builder에 넘기도록 바꾼다. `identity`에 `room_id`가 없는
entity(`attachment`)는 bubble의 `attachment_ref`를 통해 가족에 연결한다.

- [ ] **Step 5: 통과를 확인한다**

Step 3 명령을 다시 실행한다. 기대: `12 room family completeness checks passed`

- [ ] **Step 6: Kotlin에 동일 구현과 동일 fixture를 옮긴다**

```bash
cd android && ./gradlew :app:testPhoneDebugUnitTest --tests '*SyncCanonicalRoomSnapshotBuilderTest*' --tests '*SyncRemoteRoomAssemblerTest*'
```

`SyncRemoteRoomAssemblerTest`가 함께 통과해야 한다. 깨지면 **기존 테스트를 고쳐
맞추지 말고** 왜 깨졌는지 먼저 밝힌다.

- [ ] **Step 7: 동기화하지 않는 것을 확인한다**

Gemini cache와 호감도(affection)가 replica·projection·snapshot 어디에도 들어가지
않는지 확인한다.

```bash
rg -n "affection|geminiCache|gemini_cache" Sources/KakaoSapiens/Services/Sync*.swift android/app/src/main/java/com/sapiens/gagaodok/sync/
```

기대: 결과 없음. 나오면 그 경로를 제거한다.

- [ ] **Step 8: 빌드하고 커밋한다**

```bash
swift build
cd android && ./gradlew :app:compilePhoneDebugKotlin :app:compileTabletMentorDebugKotlin
cd .. && git diff --check && git status --short
```

```bash
git commit -m "$(cat <<'EOF'
feat: 원격 방의 세계선과 versioned AI state를 완성한다

The remote room assemblers filtered to room, turn and bubble before the
entity switch, so group_state, worldline, engine_profile, persona_snapshot,
checkpoint and attachment rows were dropped before they could even be
reported as unsupported — the switch's default branch was unreachable. The
replica store had been keeping all nine kinds all along.

SyncCanonicalRoomSnapshotBuilder now assembles the whole family and reports
gaps. A missing referenced revision marks the family unsupported instead of
rendering it with invented defaults, an unknown entity type is raised rather
than dropped, and one broken family no longer blocks healthy rooms. Rooms
carrying unsupportedReason are not openable for continuation.

Gemini cache and affection state stay device-local and are not synchronized.
EOF
)"
```

---
## Task 6: runtime lifecycle 연결과 journal 필수화 (상위 Task 13)

`aa2cee4`가 만든 `SyncRuntimeCoordinator`는 **자기 파일과 테스트 외에 참조가 0건**이다.
스위치는 진짜 gate지만 아직 아무 데도 붙어 있지 않다.

**Files:**
- Modify: `Sources/KakaoSapiens/Services/SyncRuntimeCoordinator.swift`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncRuntimeCoordinator.kt`
- Modify: `Sources/KakaoSapiens/Services/SyncRemoteReplyCoordinator.swift`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncRemoteReplyCoordinator.kt`
- Modify: `Sources/KakaoSapiens/App/KakaoSapiensApp.swift`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/MainActivity.kt`
- Modify: `Tests/KakaoSapiensSyncOutboxTests/SyncRuntimeCoordinatorTests.swift`
- Modify: `android/app/src/test/java/com/sapiens/gagaodok/sync/SyncRuntimeCoordinatorTest.kt`

**Interfaces:**
- Consumes: 기존 `SyncRuntimeSwitches`, `SyncPullCoordinator`, `SyncOutbox`,
  `SyncRemoteReplyJournal`.
- Produces:

```swift
public enum SyncRuntimeTrigger: String { case launch, foreground, manual, afterSend }
public enum SyncRuntimeStatus: String, Equatable { case disabled, idle, running, pausedRevoked, offline }

extension SyncRuntimeCoordinator {
    public func run(_ trigger: SyncRuntimeTrigger) async
    public var status: SyncRuntimeStatus { get }
    public func pauseForRevokedToken()
}
```

- [ ] **Step 1: journal을 필수 인자로 바꾸는 실패 테스트를 쓴다**

지금 계약이 구조로 강제되지 않는다. `journal: SyncRemoteReplyJournal? = null`이고
호출부가 `journal?.prepare(...)`라서, journal 없이도 outbox에 들어가고 컴파일이 통과한다.
UI가 항상 넘기고 있어 실동작에는 문제가 없지만, lifecycle에서 새 호출부가 생기면
조용히 깨진다.

```kotlin
    @Test fun `a reply cannot reach the outbox without being journalled first`() {
        val journal = SyncRemoteReplyJournal(File(tempRoot, "remote-replies.bin"))
        val outbox = SyncOutbox(File(tempRoot, "outbox.bin"))
        val coordinator = SyncRemoteReplyCoordinator(
            accountId = account, deviceId = device, masterKey = master, journal = journal,
        )
        val replyId = coordinator.prepare(snapshot, "PHONE_SPACE", "안녕", "안녕하세요", AIModel.GEMINI_37_FLASH, outbox)

        // journal에 기록된 operation 집합이 outbox의 것과 정확히 같아야 한다.
        val journalled = journal.operations(replyId).map { it.operationId }.toSet()
        val queued = outbox.entries().map { it.operationId }.toSet()
        assertEquals(journalled, queued)
        assertTrue(journalled.isNotEmpty())
    }
```

`journal.operations(replyId)`와 `outbox.entries()`의 실제 이름은 두 파일을 열어
확인하고 맞춘다. 없으면 테스트 전용 접근자를 추가하지 말고 **기존 읽기 경로를 쓴다.**

- [ ] **Step 2: journal을 필수로 만든다**

Swift와 Kotlin 양쪽에서 기본값 `= nil` / `= null`을 없애고 `journal?.` 를 `journal.` 로
바꾼다. 호출부(원격 방 화면)는 이미 journal을 넘기고 있으므로 수정이 필요 없다.
컴파일 오류가 나는 호출부가 있으면 **기본값을 되살리지 말고** 그 호출부가 journal을
넘기도록 고친다.

```swift
    /// journal은 선택이 아니다.
    ///
    /// "기록 먼저, 발송 나중"이 durable 계약인데 기본값이 있으면 그 계약이 호출 규약이
    /// 아니라 관행이 된다. 새 호출부가 생기는 순간 조용히 깨진다.
    private let journal: SyncRemoteReplyJournal
```

- [ ] **Step 3: runtime 실패 테스트를 확장한다**

```swift
        // 1. syncEnabled=false면 네트워크 요청이 한 건도 나가지 않는다.
        //    설정 화면이나 원격 방 화면을 열었다는 이유만으로도 나가지 않는다.
        for trigger in [SyncRuntimeTrigger.launch, .foreground, .manual, .afterSend] {
            let counter = Counter()
            let off = SyncRuntimeCoordinator(
                switches: .init(syncEnabled: false, remoteReadEnabled: true, remoteReplyEnabled: true),
                pull: { await counter.increment() })
            await off.run(trigger)
            let count = await counter.value
            try check(count == 0, "trigger \(trigger.rawValue) made a request while sync was disabled")
            try check(off.status == .disabled, "status is not disabled")
        }

        // 2. 네 계기 전부에서 돈다.
        for trigger in [SyncRuntimeTrigger.launch, .foreground, .manual, .afterSend] {
            let counter = Counter()
            let on = SyncRuntimeCoordinator(
                switches: .init(syncEnabled: true, remoteReadEnabled: true, remoteReplyEnabled: true),
                pull: { await counter.increment() })
            await on.run(trigger)
            let count = await counter.value
            try check(count == 1, "trigger \(trigger.rawValue) did not run")
        }

        // 3. 단일 실행 잠금 — 겹쳐 부르면 한 번만 돈다.
        let slow = Counter()
        let single = SyncRuntimeCoordinator(
            switches: .init(syncEnabled: true, remoteReadEnabled: true, remoteReplyEnabled: true),
            pull: { try? await Task.sleep(nanoseconds: 50_000_000); await slow.increment() })
        async let first: Void = single.run(.foreground)
        async let second: Void = single.run(.foreground)
        _ = await (first, second)
        let slowCount = await slow.value
        try check(slowCount == 1, "single-flight lock did not hold, ran \(slowCount) times")

        // 4. 스위치를 끄는 것은 지우는 것이 아니다.
        //    remoteRead를 꺼도 replica·로컬 대화가 남는지 호출부에서 확인한다.
        let readOff = SyncRuntimeCoordinator(
            switches: .init(syncEnabled: true, remoteReadEnabled: false, remoteReplyEnabled: true),
            pull: {})
        try check(!readOff.canReadRemote && readOff.canReplyRemote,
                  "disabling remote read also disabled reply")

        // 5. token 폐기는 멈추되 outbox·journal을 남긴다.
        let revoked = SyncRuntimeCoordinator(
            switches: .init(syncEnabled: true, remoteReadEnabled: true, remoteReplyEnabled: true),
            pull: {})
        revoked.pauseForRevokedToken()
        let afterRevoke = Counter()
        await revoked.run(.foreground)
        try check(await afterRevoke.value == 0, "a revoked runtime still ran")
        try check(revoked.status == .pausedRevoked, "status is not pausedRevoked")
```

- [ ] **Step 4: runtime을 구현한다**

`run(_:)`, `status`, `pauseForRevokedToken()`을 추가한다. 기존 `foreground()`는
`run(.foreground)`로 위임해 남긴다(호출부 호환). 제한된 backoff를 쓰되
**APNs·FCM·background polling을 추가하지 않는다.**

- [ ] **Step 5: lifecycle에 붙인다 (UI 미검증)**

macOS — `Sources/KakaoSapiens/App/KakaoSapiensApp.swift`의 `AppDelegate`:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        // … 기존 코드 …
        // 기본값이 꺼짐이므로 이 호출은 스위치가 켜지기 전까지 아무 요청도 만들지 않는다.
        Task { await SyncRuntimeHost.shared.run(.launch) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await SyncRuntimeHost.shared.run(.foreground) }
    }
```

Android — `MainActivity.onCreate` 안에서 lifecycle observer를 단다:

```kotlin
        lifecycle.addObserver(
            LifecycleEventObserver { _, event ->
                if (event == Lifecycle.Event.ON_RESUME) SyncRuntimeHost.run(SyncRuntimeTrigger.FOREGROUND)
            },
        )
```

`SyncRuntimeHost`는 앱이 이미 쓰는 싱글턴 패턴(`ChatRoomManager.shared`,
`WindowManager.shared`)을 따른다. **새 의존성을 추가하지 않는다.**

- [ ] **Step 6: 상태 UI를 배선한다 (미검증)**

`syncEnabled = false`인 동안 "동기화 중"이라고 **절대 말하지 않는다.**

| status | 문구 |
| --- | --- |
| `disabled` | `동기화가 꺼져 있습니다.` |
| `idle` | `마지막으로 확인함` + 시각 |
| `running` | `확인하는 중` |
| `pausedRevoked` | `이 기기의 연결이 해제되었습니다.` |
| `offline` | `연결할 수 없습니다.` |

- [ ] **Step 7: 기본값이 꺼짐인지 다시 확인한다**

```bash
rg -n "enabled\s*[:=]\s*true" Sources/KakaoSapiens/Services/SyncPairingCoordinator.swift Sources/KakaoSapiens/Services/SyncOnboardingCoordinator.swift android/app/src/main/java/com/sapiens/gagaodok/sync/SyncPairingCoordinator.kt android/app/src/main/java/com/sapiens/gagaodok/sync/SyncOnboardingCoordinator.kt
```

기대: 결과 없음. 하나라도 나오면 멈추고 보고한다.

- [ ] **Step 8: 검사하고 커밋한다**

```bash
swiftc -parse-as-library Sources/KakaoSapiens/Services/SyncRuntimeCoordinator.swift Tests/KakaoSapiensSyncOutboxTests/SyncRuntimeCoordinatorTests.swift -o /tmp/runtime && /tmp/runtime
swift build
cd android && ./gradlew :app:testPhoneDebugUnitTest --tests '*SyncRuntimeCoordinatorTest*' --tests '*SyncRemoteReplyCoordinatorTest*' :app:compilePhoneDebugKotlin :app:compileTabletMentorDebugKotlin
cd .. && git diff --check && git status --short
```

```bash
git commit -m "$(cat <<'EOF'
feat: foreground sync runtime과 단계별 kill switch를 추가한다

SyncRuntimeCoordinator existed since aa2cee4 but nothing referenced it
outside its own file and tests. It now runs from four triggers only —
launch, foreground, manual refresh and after a successful send — behind a
single-flight lock with bounded backoff. No APNs, FCM or background polling
was added.

All connection configurations still default to enabled = false, and with
syncEnabled false no trigger makes a request: opening a settings or remote
room view is not itself a reason to talk to the Worker. Turning a switch off
preserves the replica, local conversations, outbox and journal. A revoked
token pauses the runtime and keeps both durable stores.

SyncRemoteReplyCoordinator's journal argument is no longer optional. The
durable contract is journal-before-outbox; with a default value that
contract was a convention rather than a calling requirement, and the next
call site would have broken it silently.

Status UI never claims live synchronization while syncEnabled is false.
The status and attachment views are UNVERIFIED — no app was installed.
EOF
)"
```

---

## Task 7: 로컬 전체 수용 (상위 Task 14)

**Files:**
- Create: `tools/run-swift-sync-tests.sh`
- Create: `cloudflare/sync-worker/test/complete-cross-device-sync-e2e.spec.ts`
- Create: `tools/fixtures/complete-sync-room-v1.json`
- Modify: `docs/PHASE1_INTEGRATION_ACCEPTANCE_MATRIX.md`

**Interfaces:**
- Consumes: Task 1–6 전부.
- Produces: 수용 매트릭스의 기록. Task 8의 전제.

- [ ] **Step 1: Swift 테스트 러너를 만든다**

`Package.swift`에 test target이 없고 `Tests/` 아래 36개 파일이 각각 `@main`
실행파일이다. 손으로 하나씩 돌리면 "전부 통과"를 정직하게 셀 수 없다.

`tools/run-swift-sync-tests.sh`:

```bash
#!/bin/bash
# Swift @main 테스트를 하나씩 컴파일·실행하고 결과를 집계한다.
# Package.swift에 test target이 없어 `swift test`를 쓸 수 없다.
set -uo pipefail
cd "$(dirname "$0")/.."

SOURCES=$(find Sources/KakaoSapiens/Services -name 'Sync*.swift' | tr '\n' ' ')
passed=0; failed=0; failures=()

for test in $(find Tests -name '*.swift' | sort); do
  name=$(basename "$test" .swift)
  binary="/tmp/swift-test-$name"
  if ! swiftc -parse-as-library $SOURCES "$test" -o "$binary" 2>"/tmp/$name.build.log"; then
    failed=$((failed+1)); failures+=("$name (build)"); continue
  fi
  if "$binary" >"/tmp/$name.run.log" 2>&1; then
    passed=$((passed+1))
  else
    failed=$((failed+1)); failures+=("$name (run)")
  fi
done

echo "passed=$passed failed=$failed total=$((passed+failed))"
for f in "${failures[@]:-}"; do [ -n "$f" ] && echo "FAILED: $f"; done
[ "$failed" -eq 0 ]
```

```bash
chmod +x tools/run-swift-sync-tests.sh
./tools/run-swift-sync-tests.sh
```

**주의:** 일부 테스트는 `Services/Sync*.swift` 외의 타입을 필요로 해 빌드에 실패할 수
있다. 그런 경우 그 테스트를 조용히 건너뛰지 말고, 스크립트가 `FAILED: <이름> (build)`로
보고하게 둔 뒤 **실제로 몇 개가 빌드조차 안 되는지 수치로 기록한다.** 숫자를 지어내지
않는다.

- [ ] **Step 2: 결정적 시나리오 fixture를 만든다**

`tools/fixtures/complete-sync-room-v1.json`. 합성 식별자만 쓴다. 실제 대화·token·
복구 문구·production endpoint를 넣지 않는다.

시나리오:

1. MAC이 방을 만든다 → PHONE이 읽는다
2. PHONE이 오프라인 상태로 답장하고 재시작한다 → 큐가 빠진다 → MAC이 읽는다
3. TABLET-origin 방을 MAC과 PHONE이 읽고 답장한다
4. PHONE-origin 방은 다른 곳에서 보이지 않는다
5. 첨부가 `ready`에 도달한다
6. 페이지 중복과 raw body 재전송이 무해하다

- [ ] **Step 3: 실패 주입을 넣는다**

`cloudflare/sync-worker/test/complete-cross-device-sync-e2e.spec.ts`에 7가지를 넣는다.

| 주입 | 기대 |
| --- | --- |
| 같은 순번 동시 답장 | CAS로 하나만 성공, 다른 하나는 충돌 |
| D1 batch rollback | 부분 기록이 남지 않음 |
| R2 실패 | 첨부가 `ready`가 되지 않고 bubble 참조가 나가지 않음 |
| 폐기된 device | 요청 거부, outbox·journal 보존 |
| 누락된 AI revision | 그 방만 unsupported, 다른 방 정상 |
| tombstone | 참조 identity 보존 |
| 잘못된 origin | 거부 |

- [ ] **Step 4: 전체 검사 매트릭스를 한 번 돌린다**

**Android는 Gradle이 보고하는 JVM을 먼저 확인한다.**

```bash
cd android && ./gradlew --version | rg -i "JVM"
```

JDK 17이 아니고 이 checkout이 다른 버전을 명시적으로 요구하지 않으면, 우회하지 말고
**불일치를 보고한다.**

```bash
cd cloudflare/sync-worker && npm test -- --run && npm run typecheck
cd ../.. && ./tools/run-swift-sync-tests.sh && swift build
cd android && ./gradlew :app:testPhoneDebugUnitTest :app:compilePhoneDebugKotlin :app:compileTabletMentorDebugKotlin
```

**전부 로컬 workerd/Miniflare다. `--remote`를 쓰지 않는다.**

- [ ] **Step 5: 비노출 점검을 한다**

추적되는 작업 파일만 훑는다. **일치한 비밀 값 자체를 출력하지 않는다.**

```bash
git diff --name-only main | xargs rg -l "BEGIN PRIVATE KEY|recovery_phrase|Bearer [A-Za-z0-9]" 2>/dev/null || echo "없음"
rg -c "A0000000-0000-4000-8000|70000000-0000-4000-8000" tools/fixtures/complete-sync-room-v1.json
```

두 번째 명령은 합성 접두사가 실제로 쓰였는지 확인하는 것이다.

- [ ] **Step 6: 수용 매트릭스에 기록한다**

`docs/PHASE1_INTEGRATION_ACCEPTANCE_MATRIX.md`에 **실제로 실행한 명령과 결과만** 적는다.

포함할 것:
- Worker 테스트 개수와 typecheck 결과
- Swift 러너의 `passed`/`failed`/`total` 실제 수치, 빌드 실패한 파일 이름
- Android 테스트 개수, **Gradle이 보고한 JVM 버전**
- Task 3 Step 5의 12MB `maximum resident set size` 실측값
- **미검증 목록** — 첨부 UI 4상태, 동기화 상태 UI. 각각 무엇을 확인해야 하는지

실행하지 않은 항목은 미실행이라고 적는다. 비용·시간·성능 수치를 지어내지 않는다.

- [ ] **Step 7: 커밋한다**

```bash
git diff --check && git status --short
git commit -m "$(cat <<'EOF'
test: 완전 동기화 local E2E gate를 닫는다

A deterministic synthetic scenario now covers the origin matrix, offline
reply and restart, attachment reaching ready, duplicate pages and raw-body
replay, plus seven failure injections: same-order concurrent reply, D1 batch
rollback, R2 failure, revoked device, missing AI revision, tombstone and
malformed origin. The fixture carries no real conversation, token, recovery
phrase or production endpoint.

tools/run-swift-sync-tests.sh was added because Package.swift has no test
target — the Tests tree is 36 standalone @main executables, and counting a
suite by hand is how invented numbers get into a report. It compiles and
runs each one and prints real pass/fail counts.

The acceptance matrix records only commands actually run, the measured
12MB peak RSS, the JVM Gradle reported, and an explicit UNVERIFIED list for
the attachment and sync-status views, which need an installed app.
EOF
)"
```

---
## Task 8: 합성 원격 gate (상위 Task 15)

> **정지 지점.** Task 7을 끝낸 뒤 **여기서 멈추고 사용자 승인을 다시 받는다.**
> 승인 없이 이 Task의 어떤 명령도 실행하지 않는다.

**Files:**
- Modify: `cloudflare/sync-worker/scripts/remote-smoke-lib.mjs`
- Create: `docs/COMPLETE_SYNC_SYNTHETIC_REMOTE_RESULT.md`

**전제 (이미 존재한다 — 새로 만들지 않는다):**

`docs/CLOUDFLARE_CONNECTION_GATE.md`에 따르면 2026-08-29에 합성 전용 D1·private R2·
Worker가 만들어졌고 migration 0001–0010이 원격 적용됐다. 원격 설정은 gitignore된
`cloudflare/sync-worker/wrangler.synthetic.jsonc`에 있다.

**절대 하지 않는 것:**
- production namespace 생성이나 기존 production 자원 수정·삭제
- `wrangler.jsonc`(로컬 안전장치 — zero UUID, `do-not-create` bucket, placeholder
  secret)를 원격 값으로 덮어쓰기
- 실제 대화·첨부·복구 문구 접근
- Task 16·17·18의 어떤 부분도 함께 실행

- [ ] **Step 1: 승인을 받고 멈춘다**

승인은 다음 셋을 **이름으로 지목**해야 한다.

1. 합성 Worker 배포
2. 원격 D1 migration `0011_room_origin_expand.sql`과 `0012_room_origin_enforce.sql`
3. 합성 smoke 실행

**로그인은 사용자가 직접 한다.** 비밀번호·2FA를 대신 입력하지 않는다.
사용자가 로그인을 마쳤다고 확인해 주기 전까지 다음 단계로 가지 않는다.

- [ ] **Step 2: 확장 migration을 적용하고 확인한다**

```bash
cd cloudflare/sync-worker
npx wrangler d1 migrations apply --config wrangler.synthetic.jsonc --remote
npx wrangler d1 execute --config wrangler.synthetic.jsonc --remote \
  --command "SELECT name FROM d1_migrations ORDER BY id"
```

기대: 원장에 `0011_room_origin_expand.sql`이 있고 `0012`는 아직 없다.
**한 스크립트로 세 단계를 뭉뚱그리지 않는다.** 여기서 멈추고 원장을 눈으로 확인한다.

- [ ] **Step 3: 호환 Worker를 배포하고 확인한다**

```bash
npx wrangler deploy --config wrangler.synthetic.jsonc
curl -sS "$SYNTHETIC_BASE_URL/v1/health"
```

기대: health가 응답하고 내용이 없는(content-free) 형태다.
배포된 버전 해시를 기록한다.

- [ ] **Step 4: 강제 migration을 적용하고 확인한다**

```bash
npx wrangler d1 migrations apply --config wrangler.synthetic.jsonc --remote
npx wrangler d1 execute --config wrangler.synthetic.jsonc --remote \
  --command "SELECT name FROM d1_migrations ORDER BY id"
```

기대: 원장에 `0012_room_origin_enforce.sql`이 추가됐다.
순서를 지킨다 — 0011 → 배포 → 0012. 배포 전에 0012를 넣으면 옛 Worker가 거부당한다.

- [ ] **Step 5: 합성 smoke를 확장하고 실행한다**

**먼저 기존 스크립트를 그대로 다시 돌린다.** `scripts/remote-smoke.mjs`는 이미 31개
검사를 갖고 있고 2026-08-29에 원격에서 전부 통과했다. 여기에 이미 들어 있는 것:

- 첨부 `create_attachment` → PUT → complete → download, 길이 일치, `private, no-store`
- 폐기된 기기가 **네 endpoint 전부**에서 `DEVICE_REVOKED`로 거부됨(첨부 다운로드 포함)
- 다른 계정이 같은 첨부를 못 받음(404), changes/bootstrap도 빈 결과
- operation 재전송 idempotency, CAS 충돌 `409`, bootstrap 다중 페이지와 고정 watermark
- health, content-free 오류, 토큰 없는 요청 `401`, 응답에 비밀 미노출

이 재실행은 **새로 쓸 코드가 없고**, 0012가 `room`에 트리거 두 개를 걸었으므로
방 생성부터 첨부까지 이어지는 기존 경로 전체가 그대로 회귀 검사가 된다.

```bash
node scripts/remote-smoke.mjs
```

**그다음, 새로 쓰는 검사는 두 가지뿐이다.** `remote-smoke-lib.mjs`의 기존 합성 상수
(`ACCOUNT_A`, `DEVICE_MAC`, `DEVICE_PHONE`, `DEVICE_TABLET`, `ROOM_SHARED`, `ATTACHMENT`)와
헬퍼(`ciphertext()`, `syntheticToken()`, `call()`)를 그대로 쓴다. 새 합성 계정을 만들지 않는다.

| 검사 | 기대 | 왜 새로 써야 하나 |
| --- | --- | --- |
| origin 노출 matrix | phone-origin은 다른 곳에서 숨김, mac-origin은 phone만, tablet-origin은 둘 다 | **0011·0012가 강제하는 바로 그 규칙**이다. 강제 migration을 넣고 강제를 확인하지 않는 것은 말이 안 된다 |
| 답장 수렴 | 두 기기가 같은 방에 쓰고 양쪽 projection이 일치 | Task 9–13이 새로 만든 핵심 동작이고 기존 smoke에 없다. 깨지면 사용자가 서로 다른 대화를 본다 |

**의도적으로 쓰지 않는 검사와 근거:**

| 뺀 것 | 근거 |
| --- | --- |
| 첨부 원격 검사 신규 작성 | Worker/R2 경로는 기존 스크립트가 이미 끝까지 덮는다. 이번에 바뀐 것은 **클라이언트 암호**이고 그것은 교차언어 벡터와 Task 7 로컬 E2E가 덮는다 |
| device 폐기 신규 작성 | 기존 스크립트가 첨부 다운로드까지 포함해 이미 덮는다. migration이 `device`를 건드리지 않는다 |
| rate limit `429` 능동 시험 | migration이 `rate_limit`을 건드리지 않는다. 게다가 능동 시험은 합성 환경의 rate 예산을 실제로 소진해 같은 실행의 나머지 검사를 흔든다 |

근거는 추측이 아니라 확인한 것이다: `0011_room_origin_expand.sql`과
`0012_room_origin_enforce.sql`은 `room` 테이블만 건드리며(컬럼 추가, UPDATE, 트리거 2개)
`rate_limit`·`device`를 한 번도 언급하지 않는다.

로그에 내용이 남지 않게 한다. 암호문 덤프·token 값·복구 단어·R2 키·SQL 오류·
stack trace를 출력하지 않는다.

- [ ] **Step 6: 유지보수 점검을 한다 (기다리지 않는다)**

**무엇을 확인하는 것인지 먼저 분명히 한다.** 유지보수 *로직*은 이미 로컬에서
`test/maintenance-cleanup.spec.ts` 3개 테스트로 덮여 있다 — 참조된 object는 남기고
고아만 지우는 것, 오래된 allocation을 abandoned로 바꾸는 것, pairing 행 정리.
`runMaintenance(env, now)`가 시각을 주입받으므로 로컬에서 시계를 임의로 옮길 수 있다.

원격이 추가로 증명하는 것은 딱 두 가지다.

1. 배포된 Worker에 cron trigger가 실제로 걸려 있고 `scheduled()`가 불린다
2. **진짜 R2의 `list()` 페이지네이션과 bulk `delete()`가 Miniflare 흉내와 같게 동작한다**

둘째가 중요하다. 이 코드는 **데이터를 지운다.** 틀리면 아직 참조 중인 첨부를 지운다.
그리고 이 저장소는 이미 한 번, 로컬 877개가 전부 통과하는데도 원격에서만 깨진
`complete` route를 겪었다.

**cron 정시를 기다리지 않는다.** `wrangler dev`의 `--remote`(실제 binding에 연결)와
`--test-scheduled`(`/__scheduled` 방문으로 예약 이벤트 호출)를 함께 쓴다.

```bash
npx wrangler dev --config wrangler.synthetic.jsonc --remote --test-scheduled
# 다른 터미널에서
curl -sS "http://localhost:8787/__scheduled"
```

`--remote`의 도움말은 "production resources"라고 하지만, `--config`로 합성 설정을
가리키므로 binding은 합성 D1과 합성 R2다. **production 설정 파일을 넘기지 않는다.**

> 이 조합을 실제로 실행해 확인하지는 않았다(계획 작성 시점에 원격 승인이 없었다).
> 첫 시도에서 `/__scheduled`가 원격 binding으로 동작하지 않으면, 그때만 아래
> 대체 경로로 내려간다: `GRACE_MS`가 24시간이고 cron이 `17 * * * *`이므로,
> 하루 이전 `created_at`을 심어두고 **다음 정시 한 번**을 기다린다(최대 1시간, 대기는
> 유휴 시간이지 작업 시간이 아니다).

```bash
npx wrangler d1 execute --config wrangler.synthetic.jsonc --remote --command \
  "INSERT INTO attachment (account_id, attachment_id, r2_object_key, origin_space_id, kind, state, source_byte_size, ciphertext_byte_size, ciphertext_hash, key_generation, created_at) VALUES ('A0000000-0000-4000-8000-000000000001','70000000-0000-4000-8000-0000000000AA','obj/70000000-0000-4000-8000-0000000000AA','PHONE_SPACE','attachment','allocated',96,130,'0000000000000000000000000000000000000000000000000000000000000000',1,'2026-08-30T00:00:00Z')"
```

`INSERT`의 실제 컬럼 목록은 `migrations/0006_attachment.sql`을 열어 대조한 뒤 맞춘다.
위 목록이 스키마와 다르면 스키마를 따른다.

`/__scheduled` 호출 뒤(또는 대체 경로를 썼다면 다음 정시 뒤):

```bash
npx wrangler d1 execute --config wrangler.synthetic.jsonc --remote --command \
  "SELECT state FROM attachment WHERE attachment_id = '70000000-0000-4000-8000-0000000000AA'"
```

기대: `abandoned`.

그리고 **참조된 R2 object가 지워지지 않았는지** 확인한다. 참조가 있는 첨부의 state가
그대로인지 함께 조회한다.

- [ ] **Step 7: 결과를 기록하고 커밋한다**

`docs/COMPLETE_SYNC_SYNTHETIC_REMOTE_RESULT.md`에 적을 것:

- 각 단계에서 실제로 실행한 명령
- migration 원장의 상태(0011 적용 후, 0012 적용 후)
- 배포된 Worker 버전 해시
- 합성 자원 ID (D1 database id, R2 bucket 이름 — **production이 아님을 명시**)
- smoke 검사 개수와 결과
- 유지보수 점검의 실제 판정 시각과 결과
- 실제 대화·첨부·복구 문구 접근 **0건** 확인
- 남은 한계와 다음 gate(Task 16)가 요구하는 승인

```bash
git add cloudflare/sync-worker/scripts/remote-smoke-lib.mjs docs/COMPLETE_SYNC_SYNTHETIC_REMOTE_RESULT.md
git diff --check && git status --short
git commit -m "$(cat <<'EOF'
docs: 완전 동기화 합성 원격 gate를 기록한다

Applied 0011 expand, deployed the compatibility Worker, then applied 0012
enforce against the synthetic-only D1 created on 2026-08-29 — three separate
steps with the migration ledger inspected after each, never one opaque
script. The user performed the Cloudflare login themselves.

Remote smoke now covers the origin exposure matrix, reply convergence,
attachment ready with byte-identical download, device revocation and rate
limits, using the existing synthetic accounts and content-free logs.

The maintenance check did not wait a day: GRACE_MS is 24h and the cron runs
hourly at :17, so a synthetic allocation backdated one day was judged on the
next tick. Referenced R2 objects were confirmed untouched.

No production namespace was created, no existing Cloudflare resource was
modified or deleted, and real conversations, attachments and recovery
phrases remain at zero. Tasks 16-18 are untouched and need their own
approval.
EOF
)"
```

- [ ] **Step 8: 여기서 끝난다**

Task 16(실제 방 rollout·앱 설치), Task 17(production 자원), Task 18(최종 서명 릴리스)은
**이번 범위가 아니다.** 사용자에게 다음을 보고하고 멈춘다.

- `HEAD`와 5개 커밋 해시
- 실제로 실행한 검사와 수치
- 미검증 UI 목록과 각각 확인해야 할 흐름
- 경계 확인: `real-data` 0건, `remote` 합성만, `install` 없음, `push` 없음
- 다음 gate: Task 16은 앱 설치와 실제 방 접근 승인이 필요하다

---

## Self-Review 결과

**1. Spec 대응 확인**

| 설계 문서 절 | 대응 Task |
| --- | --- |
| §3.3 키 유도 | Task 1 Step 1·3·7 |
| §3.4 AAD | Task 1 Step 1·5·8 |
| §3.5 봉투 34바이트 | Task 1 Step 5, Task 3 Step 1 |
| §3.6 순서 | Task 2(계약), Task 3 Step 1·3 |
| §3.7 메모리 측정 | Task 3 Step 5, Task 7 Step 6 |
| §4 방 가족 완결성 | Task 5 전체 |
| §5.2 lifecycle 접점 | Task 6 Step 5 |
| §5.3 journal 필수화 | Task 6 Step 1·2 |
| §5.4 불변식 | Task 6 Step 3·7 |
| §6 로컬 수용 | Task 7 전체 |
| §7 합성 원격 gate | Task 8 전체 |
| §8 검증 매트릭스 | 각 Task 마지막 Step + Task 7 Step 4 |
| §9 커밋 | Task 4·5·6·7·8의 커밋 Step |
| §10 남은 위험 | Task 4 Step 6, Task 7 Step 6에 미검증 목록으로 반영 |

빠진 절 없음.

**2. 이름 일관성**

- Swift `attachmentFieldAEADKey` ↔ Kotlin `attachmentFieldAeadKey` — 언어별 관례 차이이며
  의도한 것이다. 벡터 JSON 키는 `attachment_field_aead_key_hex` 하나로 통일했다.
- `SyncAttachmentError`(Swift)와 `SyncAttachmentException`(Kotlin) — 플랫폼 관례 차이.
  판정 결과는 `SyncAttachmentDisplayState`로 양쪽 동일하다.
- `SyncAttachmentTransferCoordinator.maxSourceBytes`(Swift) ↔ `MAX_SOURCE_BYTES`(Kotlin) —
  값은 둘 다 `12_582_912`.

**3. 실행자가 반드시 먼저 확인할 것**

계획이 이름을 추측한 곳이 네 군데다. 해당 파일을 열어 실제 이름에 맞춘다.
**없다고 새로 만들지 말고 기존 것을 쓴다.**

| 위치 | 확인할 것 |
| --- | --- |
| Task 1 Step 7 | Kotlin `SyncE2EE.kt`에 `u16be`·`u32be`·`u64be`·`ascii`·`canonicalUuid`가 있는지. `u64be`만 없을 가능성이 높다 |
| Task 2 Step 6 | `SyncWorkerClient`(Kotlin) 생성자 인자 이름 |
| Task 5 Step 1 | `SyncReplicaEntry` 생성자 인자 이름 |
| Task 6 Step 1 | `SyncRemoteReplyJournal`의 읽기 메서드와 `SyncOutbox`의 열거 메서드 이름 |

---

## 최종 검토에서 고친 것 (2026-09-01)

계획을 다 쓴 뒤 처음부터 다시 읽으며 고쳤다. 실행자가 그대로 따라 하면 막혔을 것들이다.

**1. Swift 가시성 오류 — 컴파일되지 않았을 코드**

`enum SyncE2EE`는 internal인데 `public struct SyncAttachmentPlan`이 `SyncE2EE.AttachmentKind`를
노출하도록 써놨다. Swift가 "public property cannot use internal type"으로 거부한다.
`SyncAttachmentKind`·`SyncAttachmentField`를 파일 최상위 public enum으로 옮겼다.
`AttachmentKeys`는 public 시그니처에 안 나오므로 중첩인 채로 둔다.

**2. 해시 검사 테스트가 엉뚱한 이유로 통과했다**

전송 스텁이 빈 응답을 주게 짜여 있어, 해시가 달라서가 아니라 **크기가 0이라서** 거부됐다.
해시 검사는 실행조차 되지 않았다. 스텁이 올바른 바이트를 돌려주게 고치고,
"올바른 해시면 왕복한다"는 반대 검사도 넣었다. 거부가 우연이 아님을 확인하려는 것이다.

**3. 테스트 통과 개수 표기 5곳이 실제 검사 수와 달랐다**

9→12, 8→10, 7→11, 11→12, 9→11. 실행자가 "12개 통과"를 기대하는데 계획에 9라고 적혀
있으면 정상을 실패로 오인한다.

**4. Task 8의 24시간 대기를 없앴다**

`wrangler dev`에 `--remote`와 `--test-scheduled`가 각각 있다. 함께 쓰면 cron 정시를
기다리지 않고 `/__scheduled`를 직접 부른다. 대기 최대 1시간 → 초 단위.
(이 조합을 실제로 실행해 확인하지는 않았다. 안 되면 대체 경로로 내려간다.)

**5. Task 8의 smoke를 5개 검사군 → 2개로 줄였다**

근거를 확인하고 줄였다. `scripts/remote-smoke.mjs`가 이미 31개 검사를 갖고 있고
첨부 전 구간·기기 폐기·계정 격리를 덮는다. 그리고 `0011`·`0012`는 `room` 테이블만
건드린다 — `rate_limit`·`device`를 한 번도 언급하지 않는다.

**남긴 것과 이유:**

- **origin 노출 matrix** — 0011·0012가 강제하는 바로 그 규칙이다. 강제를 넣고 강제를
  확인하지 않는 것은 앞뒤가 안 맞는다.
- **답장 수렴** — Task 9–13이 만든 핵심 동작이고 기존 smoke에 없다. 깨지면 사용자가
  기기마다 다른 대화를 본다.
- **유지보수 점검** — 이 코드는 데이터를 지운다. 진짜 R2의 `list()` 페이지네이션과
  bulk `delete()`가 Miniflare 흉내와 다르면 참조 중인 첨부를 지운다. 대기가 없어졌으니
  뺄 이유도 없다.

**뺀 것과 이유:** 첨부 원격 검사 신규 작성(기존 스크립트가 덮음), device 폐기 신규
작성(기존 스크립트가 덮음), rate limit `429` 능동 시험(migration이 건드리지 않고,
능동 시험이 합성 환경의 rate 예산을 소진해 같은 실행의 나머지를 흔든다).

**6. 플랫폼별 이름 차이 (의도한 것)**

| Swift | Kotlin | 이유 |
| --- | --- | --- |
| `SyncAttachmentKind` (최상위) | `SyncE2EE.AttachmentKind` (중첩) | Swift만 가시성 제약이 있다. Kotlin은 중첩이어도 public이다 |
| `attachmentFieldAEADKey` | `attachmentFieldAeadKey` | 각 언어의 약어 표기 관례 |
| `SyncAttachmentError` | `SyncAttachmentException` | 각 언어의 오류 표현 관례 |

**벡터 JSON의 키 이름은 한 벌뿐이다** — `attachment_field_aead_key_hex` 등. 양 플랫폼이
같은 파일을 읽으므로 여기서 갈라지면 안 된다.
