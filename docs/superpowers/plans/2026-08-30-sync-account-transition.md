# Sync Account Transition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow an already-linked macOS or Android app to leave or join a sync account without touching local conversations, losing the old account on failure, or enabling sync automatically.

**Architecture:** Each platform gets an account-transition coordinator over active, staging, and short-lived rollback secret slots plus active/staging/rollback shadow files. A non-secret journal makes crash recovery deterministic. Existing pairing coordinators produce candidate credentials; only a verified bootstrap can enter commit.

**Tech Stack:** Swift/Foundation/Security/SwiftUI, Kotlin/JVM/Android Keystore/Compose, existing sync coordinators and focused unit-test harnesses.

**Spec:** `docs/2026-08-30-sync-account-transition-design.md`

## Global Constraints

- Never read, move, upload, or delete local conversations, attachments, app settings, Gemini context, or caches.
- Never replace active credentials before candidate authentication and shadow bootstrap succeed.
- Reject transition and unlink while sync is enabled or the outbox is non-empty.
- Every successful transition and unlink leaves sync disabled.
- Secrets stay only in platform secure storage; journals contain no token, master key, recovery phrase, ciphertext, or conversation content.
- Normal state has one active secret set. Staging and rollback slots must be removed after success, cancellation, or recovery.
- No Cloudflare mutation, real-data access, app installation, app-data deletion, push, or merge.
- Preserve all unrelated dirty and untracked files.

---

### Task 1: Swift secure slots and non-secret transition journal

**Files:**
- Modify: `Sources/KakaoSapiens/Services/SyncSecretStore.swift`
- Create: `Sources/KakaoSapiens/Services/SyncAccountTransitionStore.swift`
- Create: `Tests/KakaoSapiensTests/SyncAccountTransitionStoreTests.swift`
- Modify: `tools/test_swift_sync_coordinators.sh`

**Interfaces:**
- Produces: `SyncSecretSlot { active, staging, rollback }`
- Produces: `SyncSecretVaulting.load(slot:)`, `save(_:slot:)`, `remove(slot:)`
- Produces: `SyncAccountTransitionJournal.load()`, `save(_:)`, `remove()`
- Produces: `SyncTransitionFiles.stage(...)`, `promote()`, `restore()`, `discardTransient()`

- [ ] **Step 1: Add failing secure-slot tests**

```swift
func testSlotsNeverAliasAndTransientSlotsCanBeRemoved() throws {
    let vault = InMemorySyncSecretVault()
    try vault.save(oldBundle, slot: .active)
    try vault.save(newBundle, slot: .staging)
    XCTAssertEqual(try vault.load(slot: .active), oldBundle)
    XCTAssertEqual(try vault.load(slot: .staging), newBundle)
    try vault.remove(slot: .staging)
    XCTAssertNil(try vault.load(slot: .staging))
    XCTAssertEqual(try vault.load(slot: .active), oldBundle)
}
```

- [ ] **Step 2: Add failing journal validation tests**

```swift
func testJournalRejectsSecretMaterialAndUnknownStage() throws {
    XCTAssertThrowsError(try journal.decode(Data("{\"stage\":\"committing\",\"token\":\"secret\"}".utf8)))
    XCTAssertThrowsError(try journal.decode(Data("{\"stage\":\"future\"}".utf8)))
}
```

- [ ] **Step 3: Run the focused Swift store tests and confirm RED**

Run: `tools/test_swift_sync_coordinators.sh SyncAccountTransitionStoreTests`

Expected: compile failure because the slot and transition-store types do not exist.

- [ ] **Step 4: Implement slot-aware vault and journal**

```swift
public enum SyncSecretSlot: String, CaseIterable { case active, staging, rollback }

public protocol SyncSecretVaulting {
    func load(slot: SyncSecretSlot) throws -> SyncSecretBundle?
    func save(_ bundle: SyncSecretBundle, slot: SyncSecretSlot) throws
    func remove(slot: SyncSecretSlot) throws
}

public enum SyncTransitionStage: String, Codable {
    case staged, committing
}
```

Keep the existing active Keychain account names for migration compatibility. Add `-staging` and `-rollback` only to transient accounts. Journal decoding must use a closed Codable shape with version `1`, stage, old/new account IDs, and timestamp.

- [ ] **Step 5: Implement file-set staging and restore**

Use sibling files ending in `.staging` and `.rollback`. Before replacing an active file, copy it to rollback and sync the file descriptor; promote with same-directory atomic replacement. `discardTransient()` removes only those suffixes and the journal, never conversation paths.

- [ ] **Step 6: Run focused tests and static checks**

Run: `tools/test_swift_sync_coordinators.sh SyncAccountTransitionStoreTests`

Expected: all transition-store tests pass.

- [ ] **Step 7: Commit Task 1**

```bash
git add Sources/KakaoSapiens/Services/SyncSecretStore.swift Sources/KakaoSapiens/Services/SyncAccountTransitionStore.swift Tests/KakaoSapiensTests/SyncAccountTransitionStoreTests.swift tools/test_swift_sync_coordinators.sh
git commit -m "feat: Swift sync 전환 저장 경계를 추가한다"
```

---

### Task 2: Swift transition coordinator and crash recovery

**Files:**
- Create: `Sources/KakaoSapiens/Services/SyncAccountTransitionCoordinator.swift`
- Create: `Tests/KakaoSapiensTests/SyncAccountTransitionCoordinatorTests.swift`
- Modify: `tools/test_swift_sync_coordinators.sh`

**Interfaces:**
- Consumes: Task 1 vault, journal, and transition files
- Produces: `SyncTransitionCandidate` containing the verified disabled connection,
  candidate secret bundle, staged replica URL, and staged cursor URL
- Produces: `SyncCommitBoundary: CaseIterable` test seam covering each durable write
- Produces: `SyncAccountTransitionState`, `SyncAccountTransitionError`
- Produces: `prepare(candidate:)`, `markBootstrapVerified()`, `commit()`, `cancel()`, `recoverIfNeeded()`
- Produces: `unlink()` with outbox and enabled preconditions

- [ ] **Step 1: Write failing precondition tests**

```swift
func testRejectsTransitionWhenSyncEnabledOrOutboxPending() throws {
    XCTAssertThrowsError(try enabledHarness.coordinator.prepare(candidate: candidate)) {
        XCTAssertEqual($0 as? SyncAccountTransitionError, .syncEnabled)
    }
    XCTAssertThrowsError(try pendingHarness.coordinator.prepare(candidate: candidate)) {
        XCTAssertEqual($0 as? SyncAccountTransitionError, .outboxPending)
    }
}
```

- [ ] **Step 2: Write failing failure-atomicity and crash-boundary tests**

```swift
func testEveryInjectedCommitFailureLeavesOneCompleteAccount() throws {
    for boundary in SyncCommitBoundary.allCases {
        let h = Harness(failAt: boundary)
        XCTAssertThrowsError(try h.coordinator.commit())
        try h.coordinator.recoverIfNeeded()
        h.assertExactlyOneCompleteBindingAndNoTransientSecrets()
        XCTAssertEqual(h.localConversationDigest, h.originalConversationDigest)
    }
}
```

- [ ] **Step 3: Run the focused coordinator tests and confirm RED**

Run: `tools/test_swift_sync_coordinators.sh SyncAccountTransitionCoordinatorTests`

Expected: compile failure because the coordinator is absent.

- [ ] **Step 4: Implement the state machine and deterministic recovery**

```swift
public enum SyncAccountTransitionState: Equatable {
    case idle, preparing, verifying, bootstrapping, readyToCommit, committing
    case completed, cancelled, recoverableError, manualRecoveryRequired
}

public enum SyncAccountTransitionError: Error, Equatable {
    case syncEnabled, outboxPending, candidateUnverified, storageFailed, manualRecoveryRequired
}

public struct SyncTransitionCandidate {
    public let connection: SyncConnectionConfiguration
    public let secrets: SyncSecretBundle
    public let replicaURL: URL
    public let cursorURL: URL
}
```

`commit()` must copy active secret to rollback, verify it, persist `committing`, promote the candidate, verify `enabled == false`, and then remove transient state. `recoverIfNeeded()` must finish a complete new set or restore a complete old set; it must never guess missing key material.

- [ ] **Step 5: Add unlink tests and implementation**

Verify unlink removes only sync secret/connection/replica/cursor/outbox files, leaves the supplied conversation sentinel byte-for-byte unchanged, and never calls transport. Implement unlink only after both preconditions pass.

- [ ] **Step 6: Run Swift sync tests and build once**

Run: `tools/test_swift_sync_coordinators.sh SyncAccountTransitionStoreTests SyncAccountTransitionCoordinatorTests`

Run: `swift build`

Expected: tests and build pass.

- [ ] **Step 7: Commit Task 2**

```bash
git add Sources/KakaoSapiens/Services/SyncAccountTransitionCoordinator.swift Tests/KakaoSapiensTests/SyncAccountTransitionCoordinatorTests.swift tools/test_swift_sync_coordinators.sh
git commit -m "feat: Swift sync 계정 전환을 원자화한다"
```

---

### Task 3: Android secure slots and transition journal

**Files:**
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncSecretStore.kt`
- Create: `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncAccountTransitionStore.kt`
- Create: `android/app/src/test/java/com/sapiens/gagaodok/sync/SyncAccountTransitionStoreTest.kt`

**Interfaces:**
- Produces: Kotlin equivalents of `SyncSecretSlot`, `SyncSecretVault`, `SyncAccountTransitionJournal`, and `SyncTransitionFiles`

- [ ] **Step 1: Add failing slot isolation and corrupt-journal tests**

```kotlin
@Test fun `active staging and rollback secrets never alias`() {
    vault.save(oldBundle, SyncSecretSlot.ACTIVE)
    vault.save(newBundle, SyncSecretSlot.STAGING)
    assertEquals(oldBundle, vault.load(SyncSecretSlot.ACTIVE))
    assertEquals(newBundle, vault.load(SyncSecretSlot.STAGING))
}

@Test fun `journal rejects unknown keys and stages`() {
    assertFails { journal.decode("{\"stage\":\"future\",\"token\":\"secret\"}".toByteArray()) }
}
```

- [ ] **Step 2: Run phone focused test and confirm RED**

Run: `cd android && ./gradlew :app:testPhoneDebugUnitTest --tests '*SyncAccountTransitionStoreTest*'`

Expected: compile failure because the transition-store types are absent.

- [ ] **Step 3: Implement slot-aware encrypted blobs**

```kotlin
enum class SyncSecretSlot(val key: String) { ACTIVE("v1"), STAGING("v1.staging"), ROLLBACK("v1.rollback") }

interface SyncSecretVault {
    fun load(slot: SyncSecretSlot): SyncSecretLoadResult
    fun save(secrets: SyncSecretBundle, slot: SyncSecretSlot): Boolean
    fun remove(slot: SyncSecretSlot): Boolean
}
```

Reuse the existing non-exportable Keystore wrapping key. Separate preference keys provide slot isolation; no plaintext secret file is introduced.

- [ ] **Step 4: Implement journal and file-set promotion**

Use strict `kotlinx.serialization` with `ignoreUnknownKeys=false`, version `1`, and the same stages as Swift. Use private app files and same-directory fsync plus rename for staging/rollback files.

- [ ] **Step 5: Run both Android variants**

Run: `cd android && ./gradlew :app:testPhoneDebugUnitTest :app:testTabletMentorDebugUnitTest --tests '*SyncAccountTransitionStoreTest*'`

Expected: both variants pass.

- [ ] **Step 6: Commit Task 3**

```bash
git add android/app/src/main/java/com/sapiens/gagaodok/sync/SyncSecretStore.kt android/app/src/main/java/com/sapiens/gagaodok/sync/SyncAccountTransitionStore.kt android/app/src/test/java/com/sapiens/gagaodok/sync/SyncAccountTransitionStoreTest.kt
git commit -m "feat: Android sync 전환 저장 경계를 추가한다"
```

---

### Task 4: Android transition coordinator and crash recovery

**Files:**
- Create: `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncAccountTransitionCoordinator.kt`
- Create: `android/app/src/test/java/com/sapiens/gagaodok/sync/SyncAccountTransitionCoordinatorTest.kt`

**Interfaces:**
- Consumes: Task 3 stores and existing pairing/bootstrap coordinators
- Produces: `SyncTransitionCandidate` with disabled connection, secrets, staged
  replica file, and staged cursor file
- Produces: `SyncCommitBoundary.entries` test seam covering each durable write
- Produces: `SyncAccountTransitionState`, `SyncAccountTransitionError`, `prepare`, `markBootstrapVerified`, `commit`, `cancel`, `recoverIfNeeded`, `unlink`

- [ ] **Step 1: Add failing parity tests**

```kotlin
@Test fun `every commit boundary recovers one complete disabled account`() {
    SyncCommitBoundary.entries.forEach { boundary ->
        val h = harness(failAt = boundary)
        assertFails { h.coordinator.commit() }
        h.coordinator.recoverIfNeeded()
        h.assertExactlyOneCompleteBinding(enabled = false)
        assertContentEquals(h.originalConversationBytes, h.conversationFile.readBytes())
    }
}
```

- [ ] **Step 2: Run phone focused test and confirm RED**

Run: `cd android && ./gradlew :app:testPhoneDebugUnitTest --tests '*SyncAccountTransitionCoordinatorTest*'`

Expected: compile failure because the coordinator is absent.

- [ ] **Step 3: Implement the same state and error semantics as Swift**

```kotlin
enum class SyncAccountTransitionState { IDLE, PREPARING, VERIFYING, BOOTSTRAPPING, READY_TO_COMMIT, COMMITTING, COMPLETED, CANCELLED, RECOVERABLE_ERROR, MANUAL_RECOVERY_REQUIRED }
enum class SyncAccountTransitionError { SYNC_ENABLED, OUTBOX_PENDING, CANDIDATE_UNVERIFIED, STORAGE_FAILED, MANUAL_RECOVERY_REQUIRED }
data class SyncTransitionCandidate(
    val connection: SyncConnectionConfiguration,
    val secrets: SyncSecretBundle,
    val replicaFile: File,
    val cursorFile: File,
)
```

Do not call network code from unlink or recovery. Candidate bootstrap is injected and must finish before `markBootstrapVerified()` allows commit.

- [ ] **Step 4: Add non-exposure assertions**

Assert every state/error string and captured log excludes token, master key, recovery phrase, ciphertext, and full account ID.

- [ ] **Step 5: Run both variants**

Run: `cd android && ./gradlew :app:testPhoneDebugUnitTest :app:testTabletMentorDebugUnitTest --tests '*SyncAccountTransition*'`

Expected: all transition tests pass.

- [ ] **Step 6: Commit Task 4**

```bash
git add android/app/src/main/java/com/sapiens/gagaodok/sync/SyncAccountTransitionCoordinator.kt android/app/src/test/java/com/sapiens/gagaodok/sync/SyncAccountTransitionCoordinatorTest.kt
git commit -m "feat: Android sync 계정 전환을 원자화한다"
```

---

### Task 5: Connect safe actions to macOS and Android settings UI

**Files:**
- Modify: `Sources/KakaoSapiens/Views/KakaoSyncSettingsSection.swift`
- Create: `Sources/KakaoSapiens/Services/SyncAccountTransitionModel.swift`
- Create: `Tests/KakaoSapiensTests/SyncAccountTransitionModelTests.swift`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/SyncSettingsSection.kt`
- Create: `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncAccountTransitionModel.kt`
- Create: `android/app/src/test/java/com/sapiens/gagaodok/sync/SyncAccountTransitionModelTest.kt`

**Interfaces:**
- Consumes: Tasks 2 and 4 coordinators and the existing pairing QR/SAS flows
- Produces: UI actions `다른 계정에 이 기기 합류`, `이 기기 연결 해제`, `닫기`, and safe status copy

- [ ] **Step 1: Add failing UI-model action tests**

```swift
func testLinkedDisabledAccountOffersJoinAndUnlinkButPendingOutboxOffersNeither() {
    XCTAssertEqual(ready.actions, [.joinAnotherAccount, .unlinkThisDevice])
    XCTAssertEqual(pending.actions, [])
}
```

```kotlin
@Test fun `linked disabled account exposes transition actions only when safe`() {
    assertEquals(setOf(JOIN_ANOTHER_ACCOUNT, UNLINK_THIS_DEVICE), ready.actions)
    assertTrue(pending.actions.isEmpty())
}
```

- [ ] **Step 2: Confirm both model tests RED**

Run: `tools/test_swift_sync_coordinators.sh SyncAccountTransitionModelTests`

Run: `cd android && ./gradlew :app:testPhoneDebugUnitTest --tests '*SyncAccountTransitionModelTest*'`

Expected: missing model/action failures.

- [ ] **Step 3: Implement model-owned actions and confirmation copy**

Views must render only `model.actions`. The unlink confirmation must state that local conversations remain and remote accounts/other devices are untouched. The join confirmation must state that the old connection remains until success and the new connection starts disabled.

- [ ] **Step 4: Reuse the existing Android in-app scanner and pairing model**

Remove the `PAIRING_TEST`-only restriction from the join entry point only when the transition model reports it safe. Keep permission request behind the explicit scan action. Do not change package IDs, signatures, or install anything.

- [ ] **Step 5: Add whole-state invariance tests**

For cancel and every reported error, compare active secret fingerprint, connection bytes, replica bytes, cursor bytes, outbox bytes, and a synthetic conversation sentinel before/after. Compare digests only; never print content.

- [ ] **Step 6: Run focused tests and affected builds**

Run: `tools/test_swift_sync_coordinators.sh SyncAccountTransitionStoreTests SyncAccountTransitionCoordinatorTests SyncAccountTransitionModelTests`

Run: `swift build`

Run: `cd android && ./gradlew :app:testPhoneDebugUnitTest :app:testTabletMentorDebugUnitTest :app:compilePhoneDebugKotlin :app:compileTabletMentorDebugKotlin --tests '*SyncAccountTransition*'`

Expected: all tests and both platform builds pass.

- [ ] **Step 7: Commit Task 5**

```bash
git add Sources/KakaoSapiens/Views/KakaoSyncSettingsSection.swift Sources/KakaoSapiens/Services/SyncAccountTransitionModel.swift Tests/KakaoSapiensTests/SyncAccountTransitionModelTests.swift android/app/src/main/java/com/sapiens/gagaodok/ui/screens/SyncSettingsSection.kt android/app/src/main/java/com/sapiens/gagaodok/sync/SyncAccountTransitionModel.kt android/app/src/test/java/com/sapiens/gagaodok/sync/SyncAccountTransitionModelTest.kt
git commit -m "feat: 정식 앱에 안전한 sync 계정 전환 UI를 연결한다"
```

---

### Task 6: Integration gate and canonical status

**Files:**
- Modify: `docs/PHASE1_INTEGRATION_ACCEPTANCE_MATRIX.md`
- Modify: `docs/ANDROID_SYNTHETIC_ONBOARDING_DEVICE_RESULT.md`

**Interfaces:**
- Consumes: exact commits and verification evidence from Tasks 1-5
- Produces: durable gate showing unit/build completion separately from unperformed installation and real-data work

- [ ] **Step 1: Run final secret and boundary scan**

Run: `git diff --check`

Run a narrow source/test scan for literal token, master-key, recovery phrase, ciphertext, and synthetic account values. Report counts and paths only; do not print matching secret-like content.

- [ ] **Step 2: Review changed paths and commit ownership**

Confirm no files outside `Sources/KakaoSapiens/`, `Tests/KakaoSapiensTests/`, `android/`, `tools/test_swift_sync_coordinators.sh`, and the two listed docs changed in these tasks.

- [ ] **Step 3: Record the gate accurately**

Mark coordinator/store/UI unit and build evidence complete. Keep real-device installation, actual account switching, actual conversation access, sync activation, and production Cloudflare changes explicitly unapproved and incomplete.

- [ ] **Step 4: Commit Task 6**

```bash
git add docs/PHASE1_INTEGRATION_ACCEPTANCE_MATRIX.md docs/ANDROID_SYNTHETIC_ONBOARDING_DEVICE_RESULT.md
git commit -m "docs: 안전한 sync 계정 전환 gate를 기록한다"
```

## Execution stop condition

Stop and report before any install, app-data mutation, real conversation read/upload, sync activation, Cloudflare resource change, push, or merge. A later real-device test must receive separate explicit authorization and use synthetic accounts with same-signature update installation only.
