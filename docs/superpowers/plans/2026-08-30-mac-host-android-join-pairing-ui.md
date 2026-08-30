# Mac Host Android Join Pairing UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mac 가가오독이 합류 QR을 표시하고 Android phone/tabletMentor가 앱 내부 카메라로 스캔해 합성 계정에 합류할 수 있는 UI를 만든다.

**Architecture:** 기존 pairing coordinator 위에 platform별 UI model을 두고 View는 model state/action만 소비한다. Mac은 Core Image로 QR을 메모리에서 렌더링하고, Android는 CameraX analyzer와 ML Kit QR decoder를 사용하되 protocol 검증은 기존 canonical payload decoder에 맡긴다.

**Tech Stack:** SwiftUI, CoreImage, Kotlin, Jetpack Compose, CameraX 1.4.2, ML Kit barcode-scanning 17.3.0, JUnit 4

**Spec:** `docs/superpowers/specs/2026-08-30-mac-host-android-join-pairing-ui-design.md`

## Global Constraints

- 실제 대화·outbox·replica를 읽거나 쓰지 않는다.
- pairing 성공 후에도 `enabled = false`를 유지한다.
- QR raw text·token·master key·claim secret을 URL·clipboard·파일·log·오류 문구에 넣지 않는다.
- 카메라 권한은 사용자가 Android의 스캔 동작을 누른 뒤에만 요청한다.
- APK·Mac 앱 설치, 앱 데이터 삭제, 원격 pairing, Cloudflare 변경, push를 하지 않는다.

---

### Task 1: macOS host UI model과 QR renderer

**Files:**
- Create: `Sources/KakaoSapiens/Services/SyncPairingHostUIModel.swift`
- Create: `Sources/KakaoSapiens/Views/SyncPairingQRCodeView.swift`
- Create: `Tests/KakaoSapiensSyncOutboxTests/SyncPairingHostUIModelTests.swift`
- Modify: `tools/test_swift_sync_coordinators.sh`

**Interfaces:**
- Consumes: `SyncPairingHostCoordinator.openSession`, `pollCandidates`, `approve`
- Produces: `@MainActor SyncPairingHostUIModel`, `SyncPairingQRCodeRenderer.image(from:)`

- [ ] **Step 1: Write failing model and renderer tests**

Test literal state transitions: initial `.idle`; opening invokes one session and yields QR text; polling with no claim yields waiting; polling with a claim yields the exact six digits; approval is unavailable before `.verifySAS`; renderer rejects empty text and produces a non-empty bitmap for `GDP1` fixture text.

```swift
runner.check(model.state == .idle, "host starts idle")
await model.openSession(accountID: accountID, baseURL: baseURL)
runner.check(model.qrText != nil, "session exposes QR text")
runner.check(SyncPairingQRCodeRenderer.image(from: "") == nil, "empty QR is refused")
```

- [ ] **Step 2: Run the Swift pairing test script and verify RED**

Run: `./tools/test_swift_sync_coordinators.sh`

Expected: compile failure because `SyncPairingHostUIModel` and `SyncPairingQRCodeRenderer` do not exist.

- [ ] **Step 3: Implement the minimal host model and renderer**

The model exposes `state`, `qrText`, `actions`, and async `openSession`, `poll`, `approve(confirmed:)`, `reset`. It maps coordinator errors to content-free UI states. The renderer uses `CIFilter.qrCodeGenerator()` with correction level `M`, scales with nearest-neighbor interpolation, and never persists the input.

```swift
@MainActor final class SyncPairingHostUIModel: ObservableObject {
    @Published private(set) var state: SyncPairingHostState = .idle
    @Published private(set) var qrText: String?
    var actions: SyncPairingActions { .forHost(state) }
    func openSession(accountID: String, baseURL: URL) async
    func poll() async
    func approve(confirmed: Bool) async
    func reset()
}
```

- [ ] **Step 4: Run focused Swift tests and build**

Run: `./tools/test_swift_sync_coordinators.sh`

Run: `swift build`

Expected: all coordinator/model tests and build pass.

- [ ] **Step 5: Commit Task 1**

Commit only Task 1 files with message `feat: macOS pairing host UI model과 QR renderer를 추가한다`.

### Task 2: macOS 설정 화면에 host flow 연결

**Files:**
- Modify: `Sources/KakaoSapiens/Views/KakaoSyncSettingsSection.swift`
- Modify: `Sources/KakaoSapiens/Services/SyncPairingHostUIModel.swift`
- Test: `Tests/KakaoSapiensSyncOutboxTests/SyncPairingHostUIModelTests.swift`

**Interfaces:**
- Consumes: saved `SyncConnectionConfiguration`, per-request Keychain token, `SyncPairingHostUIModel`
- Produces: 연결된 합성 Mac에서만 보이는 “새 기기 합류” card

- [ ] **Step 1: Write failing availability tests**

Test that absent/relink-required/enabled connections cannot open a host session and that a connected `enabled=false` account can. Assert opening the screen itself sends zero requests.

```swift
runner.check(!SyncPairingHostAvailability.canHost(connection: nil), "absent connection cannot host")
runner.check(SyncPairingHostAvailability.canHost(connection: disabledConnection), "disabled synthetic connection can host")
runner.check(transport.requests.isEmpty, "screen appearance sends nothing")
```

- [ ] **Step 2: Run the Swift pairing test script and verify RED**

Expected: availability policy symbol is missing or enabled connection is not rejected.

- [ ] **Step 3: Implement the card and state-driven buttons**

Show QR only in session/waiting states, the warning “주변에서 QR이 보이지 않게 하세요”, exact six SAS digits in verify state, and approve only after explicit confirmation. View disappearance cancels polling and clears the in-memory QR.

- [ ] **Step 4: Run Swift tests and build**

Run the coordinator script and `swift build`; both must pass.

- [ ] **Step 5: Commit Task 2**

Commit only macOS settings/model/test files with message `feat: macOS 설정에 새 기기 합류 화면을 연결한다`.

### Task 3: Android joiner UI model

**Files:**
- Create: `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncPairingJoinerUiModel.kt`
- Create: `android/app/src/test/java/com/sapiens/gagaodok/sync/SyncPairingJoinerUiModelTest.kt`

**Interfaces:**
- Consumes: `SyncPairingJoinerCoordinator.accept`, `submit`, `redeem`
- Produces: `StateFlow<SyncPairingJoinerUiState>`, state-derived `SyncPairingJoinerUiActions`

- [ ] **Step 1: Write failing state tests**

Test literals: idle permits scan; scan tap changes only to permission request and performs no transport; denial returns retryable error; malformed QR stores nothing; valid QR submits and exposes six digits; redeem before confirmation is refused; success becomes linked-sync-off with scanned account and config `enabled=false`; repeated tap while busy is ignored.

```kotlin
assertEquals(SyncPairingJoinerUiState.Idle, model.state.value)
model.requestScan()
assertEquals(SyncPairingJoinerUiState.RequestingCamera, model.state.value)
assertEquals(0, transport.calls)
model.cameraDenied()
assertEquals(SyncPairingJoinerUiState.CameraDenied, model.state.value)
```

- [ ] **Step 2: Run phone focused test and verify RED**

Run: `./gradlew :app:testPhoneDebugUnitTest --tests '*SyncPairingJoinerUiModelTest*'`

Expected: compile failure because the UI model does not exist.

- [ ] **Step 3: Implement the minimal model**

Keep camera permission/scanner launch as UI intents, run blocking coordinator calls on an injected executor boundary, expose no raw QR or secret in state/error, and reject starting when vault or connection is not absent.

```kotlin
class SyncPairingJoinerUiModel(
    private val coordinator: SyncPairingJoinerCoordinator,
    private val client: SyncPairingClient,
    private val availability: () -> Boolean,
) {
    val state: StateFlow<SyncPairingJoinerUiState>
    fun requestScan()
    fun cameraDenied()
    fun acceptScannedPayload(text: String, deviceId: String, spaceId: String, platform: String)
    fun confirmSasAndRedeem()
}
```

- [ ] **Step 4: Run phone and tablet focused tests**

Run the focused class on both `testPhoneDebugUnitTest` and `testTabletMentorDebugUnitTest`; both pass.

- [ ] **Step 5: Commit Task 3**

Commit model/test files with message `feat: Android pairing joiner UI model을 추가한다`.

### Task 4: Android in-app QR scanner와 설정 연결

**Files:**
- Modify: `android/gradle/libs.versions.toml`
- Modify: `android/app/build.gradle.kts`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Create: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/SyncPairingScanner.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/SyncSettingsSection.kt`
- Create: `android/app/src/test/java/com/sapiens/gagaodok/sync/SyncPairingScanGateTest.kt`

**Interfaces:**
- Consumes: Activity Result camera permission, CameraX `ImageAnalysis`, ML Kit QR scanner, joiner model
- Produces: app-internal preview that delivers one QR string and closes analysis

- [ ] **Step 1: Write failing first-result gate tests**

Test a pure `SyncPairingScanGate`: first non-empty QR is delivered once; duplicate frames and non-QR/empty values are ignored; `reset` enables a new scan. The expected delivered strings are hand-written literals.

```kotlin
val delivered = mutableListOf<String>()
val gate = SyncPairingScanGate(delivered::add)
gate.offer("R0RQMQ")
gate.offer("SECOND")
assertEquals(listOf("R0RQMQ"), delivered)
```

- [ ] **Step 2: Run focused test and verify RED**

Expected: compile failure because `SyncPairingScanGate` does not exist.

- [ ] **Step 3: Add dependencies, permission and scanner UI**

Add CameraX camera2/lifecycle/view and ML Kit barcode scanning through the version catalog. Add `android.permission.CAMERA`. The analyzer limits formats to `FORMAT_QR_CODE`, closes every `ImageProxy`, and never logs decoded text. Permission is launched only from the explicit scan action.

```toml
camerax = "1.4.2"
mlkitBarcode = "17.3.0"
androidx-camera-camera2 = { group = "androidx.camera", name = "camera-camera2", version.ref = "camerax" }
androidx-camera-lifecycle = { group = "androidx.camera", name = "camera-lifecycle", version.ref = "camerax" }
androidx-camera-view = { group = "androidx.camera", name = "camera-view", version.ref = "camerax" }
mlkit-barcode-scanning = { group = "com.google.mlkit", name = "barcode-scanning", version.ref = "mlkitBarcode" }
```

- [ ] **Step 4: Connect the settings card**

Show “기존 계정에 합류” only when the synthetic environment exists and local vault/connection are absent. Display scanner, six SAS digits, confirmation, waiting/retry, and linked-sync-off states from the model. Do not expose raw QR text.

- [ ] **Step 5: Verify affected Android variants**

Run phone and tablet full unit tests, then `compilePhoneDebugKotlin` and `compileTabletMentorDebugKotlin`. All pass with JDK 17.

- [ ] **Step 6: Commit Task 4**

Commit only Android scanner/settings/dependency/manifest/test files with message `feat: Android 앱 내부 pairing QR scanner를 추가한다`.

### Task 5: Integration gate documentation

**Files:**
- Modify: `docs/PHASE1_INTEGRATION_ACCEPTANCE_MATRIX.md`

**Interfaces:**
- Consumes: Tasks 1–4 commits and verification
- Produces: build-complete versus real-device-unverified gate

- [ ] **Step 1: Record exact completed evidence**

Mark Mac-host/Android-join UI as locally implemented and explicitly leave APK install, camera runtime, SAS real-device flow, remote pairing and actual sync unapproved.

- [ ] **Step 2: Run final checks**

Run `git diff --check`, inspect every staged path, and verify unrelated dirty/untracked files remain unstaged.

- [ ] **Step 3: Commit Task 5**

Commit only the matrix with message `docs: pairing UI의 실기기 gate를 기록한다`.
